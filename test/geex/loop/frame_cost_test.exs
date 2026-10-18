defmodule Geex.Loop.FrameCostTest do
  # The regression guard for ADR-0035's frame rule: a frame costs what the screen shows, not what
  # the file holds. A highlighted ~400 KB Elixir file (loop.ex three times over) is painted
  # through the loop's own handle_info/2, from the middle of the file. Before the windowed paint
  # one such frame took over a second; it takes about 10 ms now, so the bound below is loose
  # enough for a loaded machine and still far under the old cost. Uses the global Session and
  # Renderer, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Loop, Screen, Session}
  alias Geex.Highlight.Reactor

  @bound_ms 150

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_frame_cost_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "big.ex")
    File.write!(path, String.duplicate(File.read!("lib/geex/loop.ex"), 3))
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{path: path}
  end

  # The fastest of five runs: what the work costs, not how often the scheduler looked away.
  defp best_ms(f), do: Enum.min(for(_ <- 1..5, do: elem(:timer.tc(f), 0))) / 1000

  defp io(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp repaint(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    state
  end

  test "a key and its frame on a big highlighted file cost the screen, not the file",
       %{path: path} do
    {:ok, pid} = Session.open_file(path)
    reactor = start_supervised!({Reactor, buffer: pid, language: "elixir"})
    {:ok, %{spans: spans}} = Reactor.await(reactor, 0, 30_000)
    assert length(spans) > 50_000, "#{length(spans)} spans"

    lines = length(:binary.matches(File.read!(path), "\n"))
    Session.set_cursor({div(lines, 2), 0})
    state = %{Loop.new_state(120, 40) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    assert state.watched[pid].reactor == reactor
    state = repaint(state)
    assert {:ok, %{cursor: {line, 0}}} = Session.snapshot()
    assert line > 5_000

    # The window is the right one: the rows shown mid-file are highlighted.
    screen = Geex.Renderer.current()

    fgs =
      for y <- 0..(screen.h - 1),
          x <- 0..(screen.w - 1),
          cell = Screen.get_cell(screen, x, y),
          cell.char != " ",
          into: MapSet.new(),
          do: cell.fg

    assert MapSet.size(fgs) > 3

    for {label, f} <- [
          repaint: fn -> repaint(state) end,
          down: fn -> state |> io({:key, :down}) |> repaint() end,
          typing: fn -> state |> io({:char, "x"}) |> repaint() end
        ] do
      ms = best_ms(f)
      assert ms < @bound_ms, "#{label}: #{ms} ms (bound #{@bound_ms} ms)"
    end
  end
end
