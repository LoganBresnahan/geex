defmodule Geex.Session do
  @moduledoc """
  Geex-level state holder and command entry point.

  v0.1 state:
    * `:view`       — active `Geex.View` (cursor, selection, scroll, buffer_pid)
    * `:clipboard`  — `%{name => binary}`; `:default` is the unnamed slot
    * `:minibuffer` — `%{mode: :inactive | :command, input: binary, cursor: non_neg_integer()}`
    * `:layout`     — placeholder; meaningful in v0.3 when panes split

  Dispatch lives in `Geex.Dispatch`. The per-buffer `Geex.Buffer` process owns the
  `EditorState` and the one undo history and applies commands via `Geex.Dispatch.run/1`;
  Session holds only cross-buffer state (active buffer, minibuffer input). The clipboard
  moves to a sibling `Geex.Clipboard` subsystem. See `doc/adr/0014` and `doc/adr/0015`.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %{
      view: %Geex.View{},
      clipboard: %{},
      minibuffer: %{mode: :inactive, input: "", cursor: 0},
      layout: nil
    }

    {:ok, state}
  end
end
