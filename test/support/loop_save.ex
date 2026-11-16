defmodule Geex.LoopSave do
  @moduledoc """
  Tests: let the loop's save run to its end, as the loop would (ADR-0035's 2026-11-15
  amendment). A test calls `Geex.Loop.handle_info/2` in its own process, so the save's messages
  come to it: each is handed to the loop until the save is over. A state with no save under way
  comes back as it is.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @spec finish(map()) :: map()
  def finish(%{saving: %{pid: pid}} = state) do
    receive do
      {:geex_saved_file, ^pid, _path, _result} = msg -> state |> handle(msg) |> finish()
      {:geex_saved, ^pid} = msg -> handle(state, msg)
    after
      5_000 -> flunk("the save didn't finish")
    end
  end

  def finish(state), do: state

  defp handle(state, msg) do
    {:noreply, state} = Geex.Loop.handle_info(msg, state)
    state
  end
end
