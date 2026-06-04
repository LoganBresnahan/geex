defmodule Geex.Session do
  @moduledoc """
  Geex-level state holder: the **cross-buffer / global** state and the active-buffer
  pointer (ADR-0014).

  v0.1 state:
    * `:view`       — active `Geex.View` (cursor, selection, scroll, `buffer_pid`).
                      The `buffer_pid` is the active buffer; cursor/selection/scroll
                      are view-local and ephemeral (ADR-0014 §2).
    * `:clipboard`  — placeholder; the clipboard becomes a sibling `Geex.Clipboard`
                      subsystem with its own ring history (ADR-0015).
    * `:minibuffer` — `%{mode, input, cursor}` for command-line entry.
    * `:layout`     — placeholder; meaningful in v0.3 when panes split.

  Dispatch lives in `Geex.Dispatch`. The per-buffer `Geex.Buffer` process owns the
  `EditorState` and the one undo history and applies commands via `Geex.Dispatch.run/1`;
  Session holds only this cross-buffer state. `snapshot/0` is the read-only headless
  query surface (§15b): it merges the view-local cursor with the active buffer's
  recorded snapshot. See `doc/adr/0014` and `doc/adr/0015`.
  """

  use GenServer

  alias Geex.View

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Make `pid` (or `nil`) the active buffer the view points at."
  @spec set_active_buffer(pid() | nil) :: :ok
  def set_active_buffer(pid) when is_pid(pid) or is_nil(pid),
    do: GenServer.call(__MODULE__, {:set_active_buffer, pid})

  @doc "The active buffer pid, or `:error` if none is active."
  @spec active_buffer() :: {:ok, pid()} | :error
  def active_buffer, do: GenServer.call(__MODULE__, :active_buffer)

  @doc """
  Read-only snapshot for headless inspection (§15b): the active buffer's recorded
  state plus the view-local `:cursor`. `{:error, :no_active_buffer}` if none active.
  """
  @spec snapshot() :: {:ok, map()} | {:error, :no_active_buffer}
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(_opts) do
    state = %{
      view: %View{},
      clipboard: %{},
      minibuffer: %{mode: :inactive, input: "", cursor: 0},
      layout: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_active_buffer, pid}, _from, state) do
    {:reply, :ok, put_in(state.view.buffer_pid, pid)}
  end

  def handle_call(:active_buffer, _from, state) do
    reply = if pid = state.view.buffer_pid, do: {:ok, pid}, else: :error
    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state) do
    reply =
      case state.view.buffer_pid do
        nil ->
          {:error, :no_active_buffer}

        pid ->
          buffer = Geex.Buffer.snapshot(pid)
          {:ok, Map.put(buffer, :cursor, state.view.cursor)}
      end

    {:reply, reply, state}
  end
end
