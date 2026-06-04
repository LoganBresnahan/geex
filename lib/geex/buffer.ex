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
  """

  use GenServer

  alias Geex.EditorState

  @doc """
  Start a buffer. Options: `:path` (file path, may be `nil`) and `:text` (initial
  contents, default `""`).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

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
    state = %{
      path: Keyword.get(opts, :path),
      editor: EditorState.new(Keyword.get(opts, :text, "")),
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
