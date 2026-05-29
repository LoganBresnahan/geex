defmodule Geex.Session do
  @moduledoc """
  Geex-level state holder and command entry point.

  v0.1 state:
    * `:view`       — active `Geex.View` (cursor, selection, scroll, buffer_pid)
    * `:clipboard`  — `%{name => binary}`; `:default` is the unnamed slot
    * `:minibuffer` — `%{mode: :inactive | :command, input: binary, cursor: non_neg_integer()}`
    * `:layout`     — placeholder; meaningful in v0.3 when panes split

  Dispatch lives in `Geex.Dispatcher` (a module of pure functions);
  Session's `handle_call` will route command structs through it.
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
