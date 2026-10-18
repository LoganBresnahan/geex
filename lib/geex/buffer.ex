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

  **Holding** ([ADR-0034](`e:doc/adr/0034-panes-tree-edits-hold.md`)). A change on disk doesn't
  change the buffer. The watcher reports it (`disk_changed/2`) and the buffer is marked
  **behind** until a fast-forward (`Geex.Reconcile.fast_forward/1`) takes it in. Agent writes
  it hasn't taken in yet are **held**, and the fast-forward credits them by the spool's chain
  rule. `save/1` refuses to write over a disk that changed (`{:error, :behind}`);
  `Geex.Reconcile.save/2` merges first.

  **Crash policy.** A buffer is a `:temporary` child (`Geex.BufferSupervisor`): if it
  crashes it stays down. It is deliberately *not* restarted — a restart would reload
  the file from disk with a fresh empty history, silently discarding unsaved in-memory
  edits and reverting to stale bytes. Recovery is an explicit re-open (which loads from
  disk on purpose). On death its `Geex.Registry` entry clears, so re-opening the path
  starts a fresh buffer.
  """

  use GenServer, restart: :temporary

  alias Geex.{EditorState, History, Ledger, Reconcile, Revert}
  alias Geex.Ledger.{Restore, Spool}
  alias Geex.Edit.{Footprint, Merge}

  require Logger

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
  `{:ok, path}`, `{:error, :no_path}` (buffer has no backing file), `{:error, :behind}` (the
  file on disk is no longer the `synced` text, so writing would discard someone else's change:
  fast-forward first, ADR-0034), or `{:error, posix}`. Not an edit — `save/1` does not touch
  the undo history.
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
  The watcher read `disk_text` from this buffer's file (ADR-0034 §1). The buffer doesn't change:
  it is marked **behind** when the disk differs from its `synced` text, and the mark clears when
  they match again. Subscribers get `{:geex_buffer_behind, buffer, behind}` when the mark
  changes, where `behind` is `nil` or `%{sha256, at}`. Returns `:behind` or `:in_sync`.
  """
  @spec disk_changed(GenServer.server(), String.t()) :: :behind | :in_sync
  def disk_changed(server, disk_text) when is_binary(disk_text),
    do: GenServer.call(server, {:disk_changed, disk_text})

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

  Options, both applied in the same call so nothing can interleave:

    * `:baseline` — the disk text the buffer is now in sync with (reconcile passes the
      bytes it read). `synced` becomes it and `dirty` is recomputed, so a merge that keeps
      your unsaved edits stays dirty. Without it the buffer is simply marked dirty. With a
      baseline, `commands` may be empty (disk changed to what the buffer already holds).
    * `:notice` — a one-line message for the human, broadcast to subscribers as
      `{:geex_buffer_notice, buffer, text}` after the change notification.
    * `:expect_seq` — apply only if the buffer's change clock (`snapshot.seq`) still equals
      this; otherwise return `{:error, :stale}` and change nothing. For a caller that
      computed `commands` from a snapshot (reconcile), so an edit that landed in between
      can't make them apply at the wrong place.
  """
  def dispatch_group(server, commands, opts \\ []) when is_list(commands) do
    if commands == [] and not Keyword.has_key?(opts, :baseline),
      do: raise(ArgumentError, "dispatch_group/3 needs commands, or a :baseline")

    GenServer.call(server, {:dispatch_group, commands, opts})
  end

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

  @doc """
  The cheap status: `%{path, dirty, behind}`, without the text or history `snapshot/1` builds.
  For lists drawn on every repaint (the buffer picker, the edits pane, ADR-0034).
  """
  @spec status(GenServer.server()) :: %{
          path: String.t() | nil,
          dirty: boolean(),
          behind: map() | nil
        }
  def status(server), do: GenServer.call(server, :status)

  @doc "Current buffer text."
  @spec get_text(GenServer.server()) :: String.t()
  def get_text(server), do: GenServer.call(server, :get_text)

  @doc "The recorded command history, oldest first (each carrying its `meta`)."
  @spec history(GenServer.server()) :: [struct()]
  def history(server), do: GenServer.call(server, :history)

  @doc """
  Attribute an out-of-band write to the agent that made it (ADR-0032). `attestation` is a
  validated `Geex.Attest` map (`before`, `sha256`, `harness`, `session`, optional `turn` /
  `tool_use`).

  It upgrades the buffer's **newest reconcile group**, every command of it, once, from
  `:external` to `{:agent, %{harness, session, turn, tool_use}}`, only when **both**
  `before` and `sha256` equal the group's `before_sha256` and `sha256`. `before` may instead
  equal `before_sha256_lf`, the baseline with each `\\r\\n` turned into `\\n`: Claude Code reports a
  CRLF file's prior text that way. `sha256` is always exact. Replay is unaffected: `meta` never
  feeds a command's `run/2`.

  Otherwise the write hasn't been taken in yet (the buffer holds, ADR-0034), so the attestation
  is **held** (at most 256 per buffer) and the next fast-forward credits it by the spool's
  chain rule. The payload doesn't count `:held` as taken, so it also spools the attestation,
  and a crash before the fast-forward still credits the write on reopen.

  Returns `:attested`, `:held`, or `:ignored` (no `before`, from an older payload's message;
  or the matching group is already attested).
  """
  @spec attest(GenServer.server(), map()) :: :attested | :held | :ignored
  def attest(server, attestation) when is_map(attestation),
    do: GenServer.call(server, {:attest, attestation})

  @doc """
  Take back the change that last wrote `line` (0-based): one agent's (or outside) change,
  without touching anything written after it ([ADR-0033](`e:doc/adr/0033-durable-ledger.md`)
  §7). `scope` is `:hunk` (the hunk under the line) or `:call` (the whole tool call). Planned
  and applied in one call (`Geex.Revert.plan/3`), recorded as a new group of `:human` commands
  with `meta.reverts`, so it is an ordinary, undoable edit. Returns `{:ok, snapshot, info}` or
  `{:error, reason}` (see `Geex.Revert`), changing nothing on error.
  """
  @spec revert(GenServer.server(), non_neg_integer(), Revert.scope()) ::
          {:ok, map(), Revert.info()} | {:error, Revert.reason()}
  def revert(server, line, scope) when scope in [:hunk, :call],
    do: GenServer.call(server, {:revert, line, scope})

  # Held attestations per buffer (ADR-0034), as many as the payload keeps in a spool.
  @held_max 256

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path)

    case load_text(opts, path) do
      {:ok, text} ->
        {history, ledger, notice, opening} = open_history(opts, path, text)

        state = %{
          path: path,
          # The document, the one undo history and what is kept in step with it (blame, the
          # synced baseline, dirty, the change clock): a pure value whose transitions the
          # durable ledger replays (`Geex.History`, ADR-0033).
          history: history,
          # The durable ledger (ADR-0033): every transition is appended to it. `nil` for a
          # buffer that isn't logged (no path, explicit `:text`, or the ledger is off).
          ledger: ledger,
          # The pending fsync timer: at most one a second while entries are unsynced.
          ledger_timer: nil,
          # A message about how the buffer was opened (unsaved edits restored, a change made
          # while geex was closed, another geex holding the ledger). Every subscriber gets it
          # until the first change.
          opened_notice: notice,
          # Change-stream subscribers (ADR-0022): %{monitor_ref => pid}. Empty by
          # default — the buffer notifies no one unless something subscribes.
          subscribers: %{},
          # Attestations (ADR-0032) for writes not taken in yet, newest first (ADR-0034). The
          # next fast-forward credits its group from them by the chain rule, then clears them.
          held: [],
          # `nil`, or `%{sha256, at}`: the disk differs from `synced` (ADR-0034 §1).
          behind: nil
        }

        # What opening itself records (a verification after a crash, a gap) is not a first
        # change: keep the notice.
        state = Enum.reduce(opening, state, &record(&2, &1))
        {:ok, %{state | opened_notice: notice}}

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
    case History.dispatch(state.history, command) do
      {:ok, history} ->
        # The edit's byte footprint against the *pre-edit* doc lets a byte-oriented overlay
        # (highlighting) shift optimistically across the edit (ADR-0022).
        footprint = Footprint.of(EditorState.doc(state.history.editor), command)
        new_state = record(%{state | history: history}, {:cmd, command})
        notify_change(new_state, footprint)
        {:reply, {:ok, build_snapshot(new_state)}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:dispatch_group, commands, opts}, _from, state) do
    case Keyword.fetch(opts, :expect_seq) do
      {:ok, seq} when seq != state.history.seq -> {:reply, {:error, :stale}, state}
      _ -> apply_group(commands, opts, state)
    end
  end

  def handle_call(:undo, _from, state), do: history_op(state, :undo, History.undo(state.history))
  def handle_call(:redo, _from, state), do: history_op(state, :redo, History.redo(state.history))

  def handle_call({:revert, line, scope}, _from, state) do
    with {:ok, commands, info} <- Revert.plan(state.history, line, scope),
         {:ok, history} <- History.group(state.history, commands, nil) do
      footprint = Footprint.between(History.text(state.history), History.text(history))
      entry = group_entry(:group, history, length(commands), nil)
      new_state = record(%{state | history: history}, entry)
      notify_change(new_state, footprint)
      {:reply, {:ok, build_snapshot(new_state), info}, new_state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:attest, %{before: nil}}, _from, state), do: {:reply, :ignored, state}

  def handle_call({:attest, attestation}, _from, state) do
    case History.newest_group(state.history) do
      %{group: group} = stamp when not is_nil(group) ->
        cond do
          not matches?(attestation, stamp) ->
            {:reply, :held, hold(state, attestation)}

          History.unattested?(state.history, group) ->
            actor = agent_actor(attestation)

            new_state =
              record(
                %{state | history: History.attest(state.history, group, actor)},
                {:attest, group, actor}
              )

            notify_attested(new_state, group, actor)
            {:reply, :attested, new_state}

          # Already attested: a repeat says nothing new, and parking it could let it match a
          # later, unrelated write of the same transition.
          true ->
            {:reply, :ignored, state}
        end

      _no_group ->
        {:reply, :held, hold(state, attestation)}
    end
  end

  def handle_call({:disk_changed, disk_text}, _from, state) do
    behind =
      cond do
        disk_text == state.history.synced -> nil
        state.behind && state.behind.sha256 == Restore.sha256(disk_text) -> state.behind
        true -> %{sha256: Restore.sha256(disk_text), at: DateTime.utc_now()}
      end

    state = set_behind(state, behind)
    {:reply, if(behind, do: :behind, else: :in_sync), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    if state.opened_notice, do: send(pid, {:geex_buffer_notice, self(), state.opened_notice})
    {:reply, {:ok, length(state.history.commands)}, put_in(state.subscribers[ref], pid)}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, build_snapshot(state), state}

  def handle_call(:status, _from, state),
    do: {:reply, %{path: state.path, dirty: state.history.dirty, behind: state.behind}, state}

  def handle_call(:get_text, _from, state), do: {:reply, History.text(state.history), state}

  def handle_call(:history, _from, state),
    do: {:reply, History.commands_oldest_first(state.history), state}

  def handle_call(:mark_synced, _from, state) do
    state = %{state | history: History.sync(state.history)} |> record_sync()
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:rename, new_path}, _from, state) do
    # Register the new key first; only on success unregister the old one, so a
    # collision leaves us reachable under the original path (no orphaning).
    case Registry.register(Geex.Registry, new_path, nil) do
      {:ok, _owner} ->
        if is_binary(state.path), do: Registry.unregister(Geex.Registry, state.path)
        ledger = state.ledger && Ledger.rename(state.ledger, new_path, state.history)
        {:reply, :ok, %{state | path: new_path, ledger: ledger}}

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
    with :ok <- not_behind(state),
         :ok <- File.write(state.path, History.text(state.history)) do
      # disk now equals the written text — that is the new in-sync baseline.
      state = %{state | history: History.sync(state.history)} |> record_sync()
      state = set_behind(state, nil)
      # A save is a natural durability point: don't wait for the timer.
      {:reply, {:ok, state.path}, %{state | ledger: state.ledger && Ledger.sync(state.ledger)}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # The file is still what the buffer last synced (or gone, or unreadable: nothing to lose).
  # Read at the write, so a change the watcher hasn't reported yet is caught too (ADR-0034 §3).
  defp not_behind(state) do
    case File.read(state.path) do
      {:ok, disk} when disk != state.history.synced -> {:error, :behind}
      _ -> :ok
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

  def handle_info(:ledger_fsync, state),
    do: {:noreply, %{state | ledger: Ledger.sync(state.ledger), ledger_timer: nil}}

  # The buffer traps exits when it keeps a ledger (so a shutdown runs terminate/2 and writes
  # the close entry). An exit from anything else it is linked to is not its concern.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # A clean close (a supervisor shutdown, `close_file`, quitting): the ledger's `close` entry,
  # an fsync, and the lock released.
  @impl true
  def terminate(_reason, %{ledger: %Ledger{} = ledger} = state) do
    Ledger.close(ledger, state.history)
    :ok
  end

  def terminate(_reason, _state), do: :ok

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
  defp apply_group(commands, opts, state) do
    baseline = Keyword.get(opts, :baseline)
    {commands, credited?} = credit_held(commands, baseline, state)

    case History.group(state.history, commands, baseline) do
      {:ok, history} ->
        state = if credited?, do: drop_held(state), else: state
        state = if baseline, do: caught_up(state, baseline), else: state
        # One notification for the group: the byte footprint is the diff of the whole
        # transition (the same exact splice undo/redo uses), not a per-command footprint.
        footprint = Footprint.between(History.text(state.history), History.text(history))
        entry = group_entry(:group, history, length(commands), Keyword.get(opts, :baseline))
        new_state = record(%{state | history: history}, entry)
        notify_change(new_state, footprint)
        if notice = opts[:notice], do: notify_notice(new_state, notice)
        {:reply, {:ok, build_snapshot(new_state)}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # --- attestation (ADR-0032) ---

  # `after` must equal the disk bytes exactly; `before` may also equal the baseline with
  # each "\r\n" turned into "\n" (`before_sha256_lf`, nil for a baseline without one), the form
  # Claude Code reports a CRLF file's prior text in.
  defp matches?(%{before: before, sha256: sha256}, stamp) when is_binary(before) do
    sha256 == stamp.sha256 and before in [stamp.before_sha256, stamp.before_sha256_lf]
  end

  defp matches?(_attestation, _stamp), do: false

  defp agent_actor(attestation), do: {:agent, Geex.Attest.who(attestation)}

  # A reconcile group about to be recorded (a fast-forward, ADR-0034) is credited from the held
  # attestations and the file's spool by the chain rule (ADR-0033 F): one write, or a chain all
  # from one session, taking `synced` exactly to the disk. Its commands are then recorded
  # already attested. The spool's lines come first: the payload appends each one after this
  # buffer answered `held`, so both lists are in time order and a write in both links once.
  defp credit_held([%{meta: %{reconcile: %{}}} | _] = commands, disk_text, state)
       when is_binary(disk_text) do
    entries = spool_entries(state) ++ Enum.reverse(state.held)

    case Spool.chain(entries, state.history.synced, disk_text) do
      {:ok, actor, tool_uses} -> {Enum.map(commands, &credit(&1, actor, tool_uses)), true}
      :none -> {commands, false}
    end
  end

  defp credit_held(commands, _disk_text, _state), do: {commands, false}

  defp hold(state, attestation),
    do: %{state | held: Enum.take([attestation | state.held], @held_max)}

  # Once a fast-forward has used them, the held attestations and the spool describe states the
  # file has moved past (the rule a reopen follows).
  defp drop_held(state) do
    if state.ledger, do: Spool.discard(Ledger.file(state.ledger.dir, state.ledger.path))
    %{state | held: []}
  end

  defp spool_entries(%{ledger: %Ledger{dir: dir, path: path}}),
    do: Spool.read(Ledger.file(dir, path))

  defp spool_entries(_state), do: []

  # The buffer took in `disk_text`: no longer behind, unless the disk has moved on again since.
  defp caught_up(%{behind: %{sha256: sha}} = state, disk_text) do
    if sha == Restore.sha256(disk_text), do: set_behind(state, nil), else: state
  end

  defp caught_up(state, _disk_text), do: state

  defp set_behind(%{behind: same} = state, same), do: state

  defp set_behind(state, behind) do
    for {_ref, pid} <- state.subscribers, do: send(pid, {:geex_buffer_behind, self(), behind})
    %{state | behind: behind}
  end

  defp notify_attested(state, group, actor) do
    for {_ref, pid} <- state.subscribers,
        do: send(pid, {:geex_buffer_attested, self(), group, actor})

    :ok
  end

  defp notify_notice(state, text) do
    for {_ref, pid} <- state.subscribers, do: send(pid, {:geex_buffer_notice, self(), text})
    :ok
  end

  defp notify_change(state, footprint) do
    msg = {:geex_buffer_change, self(), state.history.seq, footprint}
    for {_ref, pid} <- state.subscribers, do: send(pid, msg)
    :ok
  end

  # An undo/redo result: swap in the new history and emit its byte footprint, the diff of the
  # pre- and post-transition text (ADR-0031). One undo/redo reverts exactly one contiguous
  # command, so the minimal splice is exact and the overlay shifts like a forward edit rather
  # than resetting (no re-highlight flash). Returns the affected command so the view can place
  # the cursor.
  defp history_op(state, entry, {:ok, history, command}) do
    new_state = record(%{state | history: history}, entry)

    notify_change(
      new_state,
      Footprint.between(History.text(state.history), History.text(history))
    )

    {:reply, {:ok, build_snapshot(new_state), command}, new_state}
  end

  defp history_op(state, _entry, {:error, _reason} = error), do: {:reply, error, state}

  # --- the durable ledger (ADR-0033) ---

  # The history to start from, the ledger, a message for the human, and a gap entry to record.
  # A path-backed buffer loaded from disk restores its ledger; the disk is then checked
  # against the replayed synced text (the same content-hash join as attestation).
  defp open_history(opts, path, disk_text) do
    case ledger_dir(opts, path) do
      nil ->
        {History.new(disk_text), nil, nil, []}

      dir ->
        # Trap exits so a shutdown runs terminate/2 and the ledger closes cleanly.
        Process.flag(:trap_exit, true)

        {ledger, held} =
          case Ledger.claim(Ledger.new(dir, path)) do
            {:ok, ledger} ->
              {ledger, nil}

            {:error, reason, ledger} ->
              Logger.warning("geex ledger: not recording #{path}: #{inspect(reason)}")
              {ledger, "another geex is recording this file's history; edits here aren't logged"}
          end

        file = Ledger.file(dir, path)
        spool = Spool.read(file)
        # Whatever the spool didn't explain describes a state the file has moved past.
        if ledger.locked, do: Spool.discard(file)

        case Ledger.load(ledger) do
          :none ->
            {History.new(disk_text), ledger, held, []}

          {:ok, restored} ->
            {history, notice, gap} = rejoin(restored, disk_text, spool)
            Logger.info("geex ledger: restored #{path} (#{restored.entries} entries)")
            {history, ledger, held || notice, verification(restored) ++ List.wrap(gap)}
        end
    end
  end

  # The last session crashed (no `close`): verify the restored state now, rather than at the
  # next clean close.
  defp verification(%{clean: true}), do: []

  defp verification(%{history: h}) do
    [
      {:close,
       %{text_sha256: Restore.sha256(History.text(h)), synced_sha256: Restore.sha256(h.synced)}}
    ]
  end

  # Disk matches the replayed synced text: restore as is (unsaved edits come back, dirty).
  # Otherwise the file changed while geex was closed: record the difference as one gap group,
  # merged by the step (b) rule (disk wins overlaps). It is `:external` unless the spool shows
  # one session's edits taking the file exactly from its last known content to the disk.
  defp rejoin(%{history: h}, disk_text, _spool) when h.synced == disk_text do
    notice = if h.dirty, do: "restored unsaved changes from your last session"
    {h, notice, nil}
  end

  defp rejoin(%{history: h}, disk_text, spool) do
    text = History.text(h)

    {target, conflicts} =
      if text == h.synced, do: {disk_text, 0}, else: Merge.merge(h.synced, text, disk_text)

    commands = Reconcile.external_commands(text, target, h.synced, disk_text)

    {commands, credited} =
      case Spool.chain(spool, h.synced, disk_text) do
        {:ok, {:agent, who} = actor, tool_uses} ->
          {Enum.map(commands, &credit(&1, actor, tool_uses)),
           "; credited to #{who.harness}/#{String.slice(who.session, 0, 8)} " <>
             "(#{length(tool_uses)} edit#{if length(tool_uses) == 1, do: "", else: "s"})"}

        :none ->
          {commands, "; recorded as an outside change"}
      end

    case History.group(h, commands, disk_text) do
      {:ok, rejoined} ->
        notice =
          "the file changed while geex was closed" <>
            credited <>
            if(conflicts > 0, do: " (#{conflicts} unsaved hunk(s) took disk)", else: "")

        {rejoined, notice, group_entry(:gap, rejoined, length(commands), disk_text)}

      {:error, reason} ->
        Logger.warning(
          "geex ledger: could not rejoin the disk (#{inspect(reason)}); starting fresh"
        )

        {History.new(disk_text), nil, nil}
    end
  end

  defp credit(%{meta: meta} = command, actor, tool_uses) do
    %{
      command
      | meta: %{meta | actor: actor, reconcile: Map.put(meta.reconcile, :chain, tool_uses)}
    }
  end

  defp ledger_dir(opts, path) do
    cond do
      not is_binary(path) or Keyword.has_key?(opts, :text) ->
        nil

      dir = Keyword.get(opts, :ledger_dir) ->
        dir

      Application.get_env(:geex, :ledger, false) ->
        Application.get_env(:geex, :ledger_dir) || Ledger.default_dir()

      true ->
        nil
    end
  end

  # A group's ledger entry: the `count` commands just recorded (as stamped, with their group
  # id) and how `synced` moved: not at all, to the resulting text, or to a different disk text.
  defp group_entry(kind, history, count, baseline) do
    commands = history.commands |> Enum.take(count) |> Enum.reverse()

    mode =
      cond do
        is_nil(baseline) -> :none
        baseline == History.text(history) -> :result
        true -> baseline
      end

    {kind, commands, mode}
  end

  defp record_sync(state),
    do: record(state, {:sync, Ledger.Restore.sha256(state.history.synced)})

  # Append one transition, then make sure an fsync follows within a second. The first change
  # retires the opened notice; a ledger that just turned off says so once.
  defp record(%{ledger: nil} = state, _entry), do: %{state | opened_notice: nil}

  defp record(state, entry) do
    was_off = Ledger.off?(state.ledger)
    ledger = Ledger.append(state.ledger, entry, state.history)

    if Ledger.off?(ledger) and not was_off,
      do: notify_notice(state, "the history ledger stopped recording (see the log)")

    timer =
      if ledger.unsynced and is_nil(state.ledger_timer),
        do: Process.send_after(self(), :ledger_fsync, 1_000),
        else: state.ledger_timer

    %{state | ledger: ledger, ledger_timer: timer, opened_notice: nil}
  end

  defp build_snapshot(%{history: h} = state) do
    commands = History.commands_oldest_first(h)

    %{
      path: state.path,
      text: History.text(h),
      lines: EditorState.lines(h.editor),
      version: length(commands),
      # The monotonic change clock (ADR-0031): the reactor reads this (not `version`) so its
      # overlay ordering survives an undo, which lowers `version` but advances `seq`.
      seq: h.seq,
      dirty: h.dirty,
      synced: h.synced,
      # `nil`, or `%{sha256, at}`: the file on disk has changed since `synced` (ADR-0034).
      behind: state.behind,
      history: commands,
      # One writer per line (`Geex.Blame`): who last wrote it, for the gutter and status line.
      blame: h.blame
    }
  end
end
