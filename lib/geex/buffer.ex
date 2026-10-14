defmodule Geex.Buffer do
  @moduledoc """
  One process per open file. **Owns the `Geex.EditorState` and the one undo
  history** for that buffer (ADR-0014), plus its path / dirty flag.

  Every edit reaches the buffer as a provenance-stamped `%Command{}` through
  `dispatch/2` (the public path is `Geex.Dispatch.run/1`, which resolves the active
  buffer and calls this). The buffer performs the impure half of dispatch
  atomically inside its own process: **gather** its `EditorState`, **apply** the
  command via the pure `Geex.Dispatch.apply_command/2`, **scatter** the new state back, and
  **record** the command in history. A failing command leaves the state and history
  untouched.

  **Undo/redo** (`undo/1` / `redo/1`, [ADR-0031](`e:doc/adr/0031-undo-redo-history-operations.md`))
  are *history operations*, not recorded edits: `undo/1` drops the newest command onto a redo
  stack and replays `base + the remainder` to reconstruct the document (the §15c replay backbone);
  `redo/1` re-applies it; a fresh `dispatch/2` clears the redo stack. They emit a normal byte-
  footprint change (the minimal splice between the pre- and post-revert text — exact, since each
  step reverts one contiguous command) on a **monotonic `seq`**, so a byte-oriented overlay shifts
  across the revert just like a forward edit (no re-highlight flash); and they return the affected
  `%Command{}` so the *view* can place the cursor (the cursor stays view-local, ADR-0014).

  `snapshot/1` / `get_text/1` / `history/1` are the **read-only** query surface
  (§15b): they return buffer text + the provenance-tagged command history *as data*,
  so headless callers (an LLM, a test) inspect state without a renderer. They never
  write — the `dispatch/2` chokepoint stands (ADR-0003). The cursor is **not** here;
  it is view-local (`Geex.View`) and surfaces via `Geex.Session.snapshot/0`.

  **File I/O.** A buffer started with a `:path` loads that file's contents (a missing
  path is a fresh empty buffer — the file is created on first `save/1`; an *unreadable*
  existing file fails the start cleanly with `{:error, {:load_error, posix}}`). An
  explicit `:text` overrides (in-memory/test buffers). `save/1` writes the current text
  back to the path, clears `dirty`, and returns `{:ok, path}`. Loading and saving are
  *not* recorded edit commands — they are I/O lifecycle, like navigation (ADR-0003) —
  so `save/1` never enters the undo history; only content edits (insert/delete/replace)
  do. `Doc` round-trips through `\\n` split/join, so `load → save` is byte-stable for
  LF files. The buffer also tracks a **`synced` baseline** — the disk content it is in
  sync with (set on load, `save/1`, and `mark_synced/1`) — which reconcile (ADR-0017)
  compares disk against, so unsaved edits diverging from an *unchanged* file are never
  mistaken for an external change.

  **Crash policy.** A buffer is a `:temporary` child (`Geex.BufferSupervisor`): if it
  crashes it stays down. It is deliberately *not* restarted — a restart would reload
  the file from disk with a fresh empty history, silently discarding unsaved in-memory
  edits and reverting to stale bytes. Recovery is an explicit re-open (which loads from
  disk on purpose). On death its `Geex.Registry` entry clears, so re-opening the path
  starts a fresh buffer.
  """

  use GenServer, restart: :temporary

  alias Geex.EditorState
  alias Geex.Edit.Footprint

  @doc """
  Start a buffer. Options: `:path` (file path; its contents are loaded if the file
  exists, else a fresh empty buffer), `:text` (explicit initial contents, overrides
  loading — for in-memory/test buffers), and `:name` (a process name, typically a
  `{:via, Registry, …}` tuple so the buffer is addressable by path — see
  `Geex.BufferSupervisor`).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name_opt(name))
  end

  defp name_opt(nil), do: []
  defp name_opt(name), do: [name: name]

  @doc """
  Write the buffer's current text to its `:path` and clear `dirty`. Returns
  `{:ok, path}`, `{:error, :no_path}` (buffer has no backing file), or
  `{:error, posix}`. Not an edit — `save/1` does not touch the undo history.
  """
  @spec save(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def save(server), do: GenServer.call(server, :save)

  @doc """
  Mark the buffer as **in sync with its backing file** — clears `dirty` and sets the
  `synced` baseline to the current text, *without* writing. Used by reconcile (ADR-0017)
  after adopting an out-of-band disk change: the `EditorState` already equals disk
  byte-for-byte, so the buffer is clean and that text is the new baseline (a save would
  re-write identical bytes), even though the adopting `replace` ran through `dispatch/2`
  (which marks every command dirty). Returns the updated snapshot.
  """
  @spec mark_synced(GenServer.server()) :: map()
  def mark_synced(server), do: GenServer.call(server, :mark_synced)

  @doc """
  Re-key this buffer to `new_path` (the buffer side of `Geex.Session.rename_file/2`).

  The buffer **re-registers itself** in `Geex.Registry` from its old path to `new_path`
  and updates its internal `:path`, so `whereis(new_path)` finds it and a later `save/1`
  writes to the new file — while its `EditorState` and undo history are preserved (it is
  the same process; the active-buffer pid is unchanged). Registration is owned by the
  registered process, which is why this lives here rather than in the supervisor. Returns
  `:ok`, or `{:error, :destination_registered}` if a buffer is already registered under
  `new_path` (the old registration is left intact in that case).
  """
  @spec rename(GenServer.server(), String.t()) :: :ok | {:error, :destination_registered}
  def rename(server, new_path) when is_binary(new_path),
    do: GenServer.call(server, {:rename, new_path})

  @doc """
  Release this buffer's `Geex.Registry` path registration **synchronously**, ahead of
  termination (`Geex.Session.close_file/1` / `delete_file/1` evict via this then a
  supervisor terminate). The Registry otherwise clears a dead process's entry only when
  it later handles the monitor `:DOWN`, so a re-open / re-create of the path immediately
  after an evict could momentarily resolve to the dying pid; unregistering here closes
  that window. A no-op for a pathless (never-registered) buffer. Returns `:ok`.
  """
  @spec unregister(GenServer.server()) :: :ok
  def unregister(server), do: GenServer.call(server, :unregister)

  @doc """
  Apply a provenance-stamped `command` to this buffer. Returns `{:ok, snapshot}`
  (text + history as data) or `{:error, reason}`, leaving state unchanged on error.
  """
  @spec dispatch(GenServer.server(), struct()) :: {:ok, map()} | {:error, term()}
  def dispatch(server, command) when is_struct(command),
    do: GenServer.call(server, {:dispatch, command})

  @doc """
  Apply `commands` in order as **one atomic group**: all of them land, or none do.
  Each is recorded as its own history entry (so undo walks back one at a time), the
  redo stack is cleared, and subscribers get **one** change notification covering the
  whole group. Reconcile uses this to record one out-of-band write as one command per
  changed hunk (ADR-0032). Returns `{:ok, snapshot}` or the first command's error.
  """
  def dispatch_group(server, [_ | _] = commands),
    do: GenServer.call(server, {:dispatch_group, commands})

  @doc """
  Undo the most recent edit (ADR-0031). Drops the newest command from history onto the redo
  stack and replays `base + the remainder` to reconstruct the document — the §15c replay
  backbone (ADR-0014), so the reverted state is exactly what produced it. Returns
  `{:ok, snapshot, command}` (the snapshot of the reverted buffer + the **undone** command, so
  the view can place its cursor where the edit was), or `{:error, :nothing_to_undo}` when there
  is nothing to undo. Not itself a recorded edit; emits a byte-footprint change so overlays shift.
  """
  @spec undo(GenServer.server()) :: {:ok, map(), struct()} | {:error, :nothing_to_undo}
  def undo(server), do: GenServer.call(server, :undo)

  @doc """
  Redo the most recently undone edit (ADR-0031) — re-applies it to the current state and moves
  it from the redo stack back onto history. Returns `{:ok, snapshot, command}` (the **redone**
  command, for cursor placement) or `{:error, :nothing_to_redo}`. The redo stack is cleared by
  any fresh `dispatch/2`, so redo is only available on an unbroken run of undos.
  """
  @spec redo(GenServer.server()) :: {:ok, map(), struct()} | {:error, :nothing_to_redo}
  def redo(server), do: GenServer.call(server, :redo)

  @doc """
  Subscribe `pid` to this buffer's change stream. After every successful
  `dispatch/2` the buffer sends each subscriber `{:geex_buffer_change, buffer_pid,
  version, footprint}` — the post-dispatch emit that makes the command pipeline the
  editor's "after change" hook ([ADR-0022](`e:doc/adr/0022-capability-reactor.md`)).
  `footprint` is the edit's byte footprint `%{at, removed, added}` (or `:unknown`), so
  a byte-oriented consumer can shift its overlay across the edit. The
  capability reactor (highlighting, later LSP) is the consumer; the buffer knows
  only "subscribers", not what they do, and never blocks on them (it `send`s).

  Subscribers are monitored and dropped on death, so a crashed reactor leaves no
  residue. Returns `{:ok, version}` — the current version — so a subscriber can do
  an initial pass over already-loaded content before any edit arrives.
  """
  @spec subscribe(GenServer.server(), pid()) :: {:ok, non_neg_integer()}
  def subscribe(server, pid) when is_pid(pid), do: GenServer.call(server, {:subscribe, pid})

  @doc """
  Stop sending change notifications to `pid` — drops its subscription and the
  buffer's monitor of it. Fire-and-forget; safe to call for a pid that is not
  subscribed (a no-op). Used by `Geex.Loop` when it re-attaches to another buffer.
  """
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(server, pid) when is_pid(pid), do: GenServer.cast(server, {:unsubscribe, pid})

  @doc """
  Read-only snapshot: text, lines, version (`length(history)`), the monotonic change `seq`
  (ADR-0031), dirty, path, the `synced` disk baseline (what reconcile compares against), and
  command history.
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Current buffer text."
  @spec get_text(GenServer.server()) :: String.t()
  def get_text(server), do: GenServer.call(server, :get_text)

  @doc "The recorded command history, oldest first (each carrying its `meta`)."
  @spec history(GenServer.server()) :: [struct()]
  def history(server), do: GenServer.call(server, :history)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path)

    case load_text(opts, path) do
      {:ok, text} ->
        editor = EditorState.new(text)

        state = %{
          path: path,
          editor: editor,
          # The loaded baseline `EditorState` — undo replays `base + remaining history` to
          # reconstruct the document after dropping the newest command (the §15c replay
          # backbone, ADR-0014). Never changes; load is the only thing that sets it.
          base: editor,
          # newest-first internally (O(1) prepend); exposed oldest-first via snapshot.
          history: [],
          # Undone commands, newest-first — the redo future. A new edit clears it (the
          # redone branch is discarded once you edit past the undo point). ADR-0031.
          redo: [],
          # A **monotonic** change clock — incremented on every dispatch/undo/redo. Distinct
          # from `version` (= `length(history)`, which goes *backwards* on undo): the reactor
          # orders optimistic overlays by `seq`, so its "newer = higher" assumption survives an
          # undo and the overlay byte-shifts (no re-highlight flash) instead of resetting. ADR-0031.
          seq: 0,
          # Change-stream subscribers (ADR-0022): %{monitor_ref => pid}. Empty by
          # default — the buffer notifies no one unless something subscribes.
          subscribers: %{},
          dirty: false,
          # The disk content the buffer is **in sync with** — its baseline. Reconcile
          # (ADR-0017) compares disk against *this*, not the live (possibly dirty) text, so an
          # event whose disk still equals the baseline is no external change (no spurious revert
          # of unsaved edits), and the baseline travels with a rename's re-key. Set to the
          # loaded content here; updated by `save/1` (to the written bytes) and `mark_synced/1`.
          synced: text
        }

        {:ok, state}

      # A genuinely unreadable existing file (`:eacces`, a TOCTOU `:enoent`/`:eisdir`)
      # fails the start cleanly — non-bang `File.read/1` keeps the I/O error out of a
      # raised `File.Error`+stacktrace, so `open_file` surfaces a tidy posix reason
      # rather than dumping internals into the model's tool result.
      {:error, posix} ->
        {:stop, {:load_error, posix}}
    end
  end

  # `:text` overrides loading. A missing path is a fresh empty buffer (created on first
  # save). An existing regular file is read; anything else (no path, a directory) is empty.
  defp load_text(opts, path) do
    cond do
      Keyword.has_key?(opts, :text) -> {:ok, Keyword.get(opts, :text)}
      is_binary(path) and File.regular?(path) -> File.read(path)
      true -> {:ok, ""}
    end
  end

  @impl true
  def handle_call({:dispatch, command}, _from, state) do
    case Geex.Dispatch.apply_command(command, state.editor) do
      {:ok, editor} ->
        # Compute the edit's byte footprint against the *pre-edit* doc, before we
        # swap in the new editor — it lets a byte-oriented overlay (highlighting)
        # shift optimistically across the edit (ADR-0022).
        footprint = Footprint.of(EditorState.doc(state.editor), command)
        # A fresh edit invalidates the redo future (you can't redo past a new divergence).
        new_state = %{
          state
          | editor: editor,
            history: [command | state.history],
            redo: [],
            dirty: true,
            seq: state.seq + 1
        }

        notify_change(new_state, footprint)
        {:reply, {:ok, build_snapshot(new_state)}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:dispatch_group, commands}, _from, state) do
    applied =
      Enum.reduce_while(commands, {:ok, state.editor}, fn command, {:ok, editor} ->
        case Geex.Dispatch.apply_command(command, editor) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case applied do
      {:ok, editor} ->
        # One notification for the group: the byte footprint is the diff of the whole
        # transition (the same exact splice undo/redo uses), not a per-command footprint.
        footprint =
          Footprint.between(EditorState.text(state.editor), EditorState.text(editor))

        new_state = %{
          state
          | editor: editor,
            history: Enum.reverse(commands) ++ state.history,
            redo: [],
            dirty: true,
            seq: state.seq + 1
        }

        notify_change(new_state, footprint)
        {:reply, {:ok, build_snapshot(new_state)}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:undo, _from, %{history: []} = state),
    do: {:reply, {:error, :nothing_to_undo}, state}

  def handle_call(:undo, _from, %{history: [command | rest]} = state) do
    # Reconstruct the pre-`command` document by replaying base + the remaining (older)
    # commands. These all applied successfully once, so replay cannot fail here; guard it
    # anyway so a (theoretically impossible) failure leaves state and history untouched.
    case Geex.Dispatch.replay(state.base, Enum.reverse(rest)) do
      {:ok, editor} ->
        new_state = revert(state, editor, rest, [command | state.redo])
        notify_change(new_state, revert_footprint(state.editor, editor))
        {:reply, {:ok, build_snapshot(new_state), command}, new_state}

      {:error, _reason} ->
        {:reply, {:error, :nothing_to_undo}, state}
    end
  end

  def handle_call(:redo, _from, %{redo: []} = state),
    do: {:reply, {:error, :nothing_to_redo}, state}

  def handle_call(:redo, _from, %{redo: [command | rest_redo]} = state) do
    # Re-apply the undone command to the current editor (which, after the matching undo,
    # equals the state it was first applied to — so this succeeds), moving it back onto history.
    case Geex.Dispatch.apply_command(command, state.editor) do
      {:ok, editor} ->
        new_state = revert(state, editor, [command | state.history], rest_redo)
        notify_change(new_state, revert_footprint(state.editor, editor))
        {:reply, {:ok, build_snapshot(new_state), command}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, {:ok, length(state.history)}, put_in(state.subscribers[ref], pid)}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, build_snapshot(state), state}

  def handle_call(:get_text, _from, state), do: {:reply, EditorState.text(state.editor), state}

  def handle_call(:history, _from, state),
    do: {:reply, Enum.reverse(state.history), state}

  def handle_call(:mark_synced, _from, state) do
    state = %{state | dirty: false, synced: EditorState.text(state.editor)}
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:rename, new_path}, _from, state) do
    # Register the new key first; only on success unregister the old one, so a
    # collision leaves us reachable under the original path (no orphaning).
    case Registry.register(Geex.Registry, new_path, nil) do
      {:ok, _owner} ->
        if is_binary(state.path), do: Registry.unregister(Geex.Registry, state.path)
        {:reply, :ok, %{state | path: new_path}}

      {:error, {:already_registered, _pid}} ->
        {:reply, {:error, :destination_registered}, state}
    end
  end

  def handle_call(:unregister, _from, state) do
    if is_binary(state.path), do: Registry.unregister(Geex.Registry, state.path)
    {:reply, :ok, state}
  end

  def handle_call(:save, _from, %{path: nil} = state), do: {:reply, {:error, :no_path}, state}

  def handle_call(:save, _from, state) do
    text = EditorState.text(state.editor)

    case File.write(state.path, text) do
      # disk now equals the written text — that is the new in-sync baseline.
      :ok -> {:reply, {:ok, state.path}, %{state | dirty: false, synced: text}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: drop_subscriber(state.subscribers, pid)}}
  end

  # A monitored subscriber died — drop it. Keeps the subscriber set free of stale
  # pids (a crashed reactor leaves no residue). Guarded to *subscriber* refs only,
  # so a future monitor added to the buffer can't be silently swallowed here.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{subscribers: subscribers} = state)
      when is_map_key(subscribers, ref) do
    {:noreply, %{state | subscribers: Map.delete(subscribers, ref)}}
  end

  # Remove every subscription held by `pid` and demonitor it — the explicit
  # counterpart to a subscriber's `:DOWN` cleanup (used on `unsubscribe/2`).
  defp drop_subscriber(subscribers, pid) do
    Enum.reduce(subscribers, subscribers, fn
      {ref, ^pid}, acc ->
        Process.demonitor(ref, [:flush])
        Map.delete(acc, ref)

      {_ref, _other}, acc ->
        acc
    end)
  end

  # Post-dispatch emit (ADR-0022): tell each subscriber the buffer changed, tagged with the
  # monotonic **`seq`** (NOT `length(history)` — that goes backwards on undo, breaking the
  # reactor's "newer = higher" ordering) **and the edit's byte footprint** (`%{at, removed,
  # added}`, or `:unknown`) so a byte-oriented overlay can shift optimistically across the
  # edit. A plain `send` — the buffer never blocks on a reactor.
  defp notify_change(state, footprint) do
    msg = {:geex_buffer_change, self(), state.seq, footprint}
    for {_ref, pid} <- state.subscribers, do: send(pid, msg)
    :ok
  end

  # The byte footprint of an undo/redo, computed by diffing the pre- and post-transition text
  # (ADR-0031). A single undo/redo reverts exactly one contiguous command, so the minimal splice
  # is exact — the overlay shifts like a forward edit rather than resetting (no re-highlight flash).
  defp revert_footprint(before_editor, after_editor),
    do: Footprint.between(EditorState.text(before_editor), EditorState.text(after_editor))

  # Apply an undo/redo transition: swap in the reconstructed `editor`, set `history` and the
  # `redo` stack, bump the monotonic `seq` (an undo/redo *is* a forward step on the change clock,
  # even though it lowers `version`), and recompute `dirty` against the `synced` disk baseline —
  # so undoing back to the saved content clears the dirty flag (a forward `dispatch/2` is
  # unconditionally dirty; an undo/redo can land *on* the baseline, which is genuinely clean).
  defp revert(state, editor, history, redo) do
    %{
      state
      | editor: editor,
        history: history,
        redo: redo,
        dirty: EditorState.text(editor) != state.synced,
        seq: state.seq + 1
    }
  end

  defp build_snapshot(state) do
    history = Enum.reverse(state.history)

    %{
      path: state.path,
      text: EditorState.text(state.editor),
      lines: EditorState.lines(state.editor),
      version: length(history),
      # The monotonic change clock (ADR-0031): the reactor reads this (not `version`) so its
      # overlay ordering survives an undo, which lowers `version` but advances `seq`.
      seq: state.seq,
      dirty: state.dirty,
      synced: state.synced,
      history: history
    }
  end
end
