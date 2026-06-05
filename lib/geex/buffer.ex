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
  LF files.

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
  Mark the buffer as **in sync with its backing file** — clears `dirty` *without*
  writing. Used by reconcile (ADR-0017) after adopting an out-of-band disk change:
  the `EditorState` already equals disk byte-for-byte, so the buffer is clean (a save
  would re-write identical bytes), even though the adopting `replace` ran through
  `dispatch/2` (which marks every command dirty). Returns the updated snapshot.
  """
  @spec mark_synced(GenServer.server()) :: map()
  def mark_synced(server), do: GenServer.call(server, :mark_synced)

  @doc """
  Apply a provenance-stamped `command` to this buffer. Returns `{:ok, snapshot}`
  (text + history as data) or `{:error, reason}`, leaving state unchanged on error.
  """
  @spec dispatch(GenServer.server(), struct()) :: {:ok, map()} | {:error, term()}
  def dispatch(server, command) when is_struct(command),
    do: GenServer.call(server, {:dispatch, command})

  @doc "Read-only snapshot: text, lines, version, dirty, path, and command history."
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
          dirty: false
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
        {:reply, {:ok, build_snapshot(new_state)}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, build_snapshot(state), state}

  def handle_call(:get_text, _from, state), do: {:reply, EditorState.text(state.editor), state}

  def handle_call(:history, _from, state),
    do: {:reply, Enum.reverse(state.history), state}

  def handle_call(:mark_synced, _from, state) do
    state = %{state | dirty: false}
    {:reply, build_snapshot(state), state}
  end

  def handle_call(:save, _from, %{path: nil} = state), do: {:reply, {:error, :no_path}, state}

  def handle_call(:save, _from, state) do
    case File.write(state.path, EditorState.text(state.editor)) do
      :ok -> {:reply, {:ok, state.path}, %{state | dirty: false}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp build_snapshot(state) do
    history = Enum.reverse(state.history)

    %{
      path: state.path,
      text: EditorState.text(state.editor),
      lines: EditorState.lines(state.editor),
      version: length(history),
      dirty: state.dirty,
      history: history
    }
  end
end
