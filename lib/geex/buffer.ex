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
  Subscribe `pid` to this buffer's change stream. After every successful
  `dispatch/2` the buffer sends each subscriber `{:geex_buffer_change, buffer_pid,
  version}` — the post-dispatch emit that makes the command pipeline the editor's
  "after change" hook ([ADR-0022](`e:doc/adr/0022-capability-reactor.md`)). The
  capability reactor (highlighting, later LSP) is the consumer; the buffer knows
  only "subscribers", not what they do, and never blocks on them (it `send`s).

  Subscribers are monitored and dropped on death, so a crashed reactor leaves no
  residue. Returns `{:ok, version}` — the current version — so a subscriber can do
  an initial pass over already-loaded content before any edit arrives.
  """
  @spec subscribe(GenServer.server(), pid()) :: {:ok, non_neg_integer()}
  def subscribe(server, pid) when is_pid(pid), do: GenServer.call(server, {:subscribe, pid})

  @doc """
  Read-only snapshot: text, lines, version, dirty, path, the `synced` disk baseline (what
  reconcile compares against), and command history.
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
        state = %{
          path: path,
          editor: EditorState.new(text),
          # newest-first internally (O(1) prepend); exposed oldest-first via snapshot.
          history: [],
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
        new_state = %{state | editor: editor, history: [command | state.history], dirty: true}
        notify_change(new_state)
        {:reply, {:ok, build_snapshot(new_state)}, new_state}

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

  # A monitored subscriber died — drop it. Keeps the subscriber set free of stale
  # pids (a crashed reactor leaves no residue).
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  # Post-dispatch emit (ADR-0022): tell each subscriber the buffer changed, tagged
  # with the new version. A plain `send` — the buffer never blocks on a reactor.
  defp notify_change(state) do
    version = length(state.history)
    for {_ref, pid} <- state.subscribers, do: send(pid, {:geex_buffer_change, self(), version})
    :ok
  end

  defp build_snapshot(state) do
    history = Enum.reverse(state.history)

    %{
      path: state.path,
      text: EditorState.text(state.editor),
      lines: EditorState.lines(state.editor),
      version: length(history),
      dirty: state.dirty,
      synced: state.synced,
      history: history
    }
  end
end
