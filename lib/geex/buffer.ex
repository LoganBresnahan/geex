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
  path is a fresh empty buffer — the file is created on first `save/1`); an explicit
  `:text` overrides (in-memory/test buffers). `save/1` writes the current text back to
  the path and clears `dirty`. Loading and saving are *not* recorded edit commands —
  they are I/O lifecycle, like navigation (ADR-0003) — so `save/1` never enters the
  undo history; only content edits (insert/delete/replace) do. `Doc` round-trips
  through `\\n` split/join, so `load → save` is byte-stable for LF files.
  """

  use GenServer

  alias Geex.EditorState

  @doc """
  Start a buffer. Options: `:path` (file path; its contents are loaded if the file
  exists, else a fresh empty buffer) and `:text` (explicit initial contents, overrides
  loading — for in-memory/test buffers).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Write the buffer's current text to its `:path` and clear `dirty`. Returns `:ok`,
  `{:error, :no_path}` (buffer has no backing file), or `{:error, posix}`. Not an edit
  — `save/1` does not touch the undo history.
  """
  @spec save(GenServer.server()) :: :ok | {:error, term()}
  def save(server), do: GenServer.call(server, :save)

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

    text =
      cond do
        Keyword.has_key?(opts, :text) -> Keyword.get(opts, :text)
        is_binary(path) and File.regular?(path) -> File.read!(path)
        true -> ""
      end

    state = %{
      path: path,
      editor: EditorState.new(text),
      # newest-first internally (O(1) prepend); exposed oldest-first via snapshot.
      history: [],
      dirty: false
    }

    {:ok, state}
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

  def handle_call(:save, _from, %{path: nil} = state), do: {:reply, {:error, :no_path}, state}

  def handle_call(:save, _from, state) do
    case File.write(state.path, EditorState.text(state.editor)) do
      :ok -> {:reply, :ok, %{state | dirty: false}}
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
