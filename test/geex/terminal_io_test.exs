defmodule Geex.TerminalIOTest do
  # The terminal's end of input (2026-11-16): `Geex.TerminalIO` says so and stays, so its
  # supervisor never restarts it into the same end of input until it gives up and takes the tree
  # down, the loop and a save it waits for with it. The process isn't started under `mix test`
  # (it takes the tty), so its callbacks are called on a state of its shape.
  use ExUnit.Case, async: true

  alias Geex.TerminalIO

  defp state do
    %{
      reader_ref: make_ref(),
      subscribers: MapSet.new([self()]),
      monitors: %{},
      bg_answer: nil,
      eof: false
    }
  end

  test "end of input: each subscriber told, and the process stays" do
    state = state()

    assert {:noreply, %{eof: true} = after_eof} =
             TerminalIO.handle_info({state.reader_ref, :eof}, state)

    assert_received {:geex_io, :eof}

    # A subscriber that comes later (a restarted loop) is told at once.
    me = self()
    late = spawn_link(fn -> receive(do: (msg -> send(me, {:late, msg}))) end)
    {:noreply, _} = TerminalIO.handle_cast({:subscribe, late}, after_eof)
    assert_receive {:late, {:geex_io, :eof}}
  end

  # BUG-21: the stop watchdog puts the terminal back when the stop hangs; the process's own stop,
  # if it comes after, leaves it (a state with no tty: touching it would crash).
  test "once restored, a restore or the stop leaves the terminal alone" do
    restored = %{restored: true}
    assert TerminalIO.handle_call(:restore, self(), restored) == {:reply, :ok, restored}
    assert TerminalIO.terminate(:shutdown, restored) == :ok
  end

  # mod-verify's review: a frame from a loop still running would land on the restored screen.
  test "once restored, nothing more is drawn" do
    restored = %{restored: true}
    assert TerminalIO.handle_cast({:write, "frame"}, restored) == {:noreply, restored}
    assert TerminalIO.handle_cast({:mouse, true}, restored) == {:noreply, restored}
  end

  test "before it, a new subscriber hears nothing of it" do
    me = self()
    other = spawn_link(fn -> receive(do: (msg -> send(me, {:other, msg}))) end)
    {:noreply, _} = TerminalIO.handle_cast({:subscribe, other}, state())
    refute_receive {:other, _}, 50
  end
end
