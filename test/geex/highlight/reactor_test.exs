defmodule Geex.Highlight.ReactorTest do
  use ExUnit.Case, async: true

  alias Geex.{Buffer, Command}
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Highlight.{Reactor, ReactorSupervisor}

  defp insert(line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    Command.put_meta(cmd, Meta.human())
  end

  defp captures(overlay), do: MapSet.new(overlay.spans, & &1.capture)

  setup do
    buf = start_supervised!({Buffer, text: "defmodule A do\nend\n"})
    reactor = start_supervised!({Reactor, buffer: buf, language: "elixir"})
    %{buf: buf, reactor: reactor}
  end

  test "highlights already-loaded content on start (initial pass)", %{reactor: reactor} do
    assert {:ok, overlay} = Reactor.await(reactor, 0)
    assert overlay.version == 0
    assert "keyword" in captures(overlay)
  end

  test "fires off the command stream: a dispatched edit re-highlights", %{buf: buf, reactor: reactor} do
    {:ok, _} = Reactor.await(reactor, 0)

    # Insert a comment; version goes 0 -> 1.
    assert {:ok, snap} = Buffer.dispatch(buf, insert(1, 0, "  # note\n"))
    assert snap.version == 1

    assert {:ok, overlay} = Reactor.await(reactor, 1)
    assert overlay.version == 1
    # The new comment is now highlighted.
    assert "comment" in captures(overlay)
  end

  test "latest-wins: a burst of edits coalesces to an overlay for the newest text", %{buf: buf, reactor: reactor} do
    {:ok, _} = Reactor.await(reactor, 0)

    final =
      Enum.reduce(1..8, nil, fn i, _ ->
        {:ok, snap} = Buffer.dispatch(buf, insert(0, 0, "x#{i} = #{i}\n"))
        snap.version
      end)

    assert {:ok, overlay} = Reactor.await(reactor, final)
    # Converged to the latest version (no stale overlay left behind).
    assert overlay.version == final
  end

  test "highlights/1 is nil before the first pass, then an overlay", %{reactor: reactor} do
    # Either nil (pass in flight) or already an overlay — both are valid shapes.
    assert Reactor.highlights(reactor) in [nil] or match?(%{spans: _}, Reactor.highlights(reactor))
    assert {:ok, %{spans: _}} = Reactor.await(reactor, 0)
  end

  test "the reactor follows its buffer: buffer death stops it", %{reactor: reactor} do
    buf2 = start_supervised!({Buffer, text: "x = 1\n"}, id: :death_buf)
    r2 = start_supervised!({Reactor, buffer: buf2, language: "elixir"}, id: :death_reactor)
    {:ok, _} = Reactor.await(r2, 0)

    ref = Process.monitor(r2)
    :ok = stop_supervised!(:death_buf)
    assert_receive {:DOWN, ^ref, :process, ^r2, _reason}, 1_000

    # And the original reactor is unaffected.
    assert Process.alive?(reactor)
  end

  test "for_buffer finds the reactor; ReactorSupervisor.start_reactor is idempotent" do
    buf = start_supervised!({Buffer, text: "y = 2\n"}, id: :sup_buf)
    assert {:ok, pid} = ReactorSupervisor.start_reactor(buf, "elixir")
    assert Reactor.for_buffer(buf) == {:ok, pid}
    # A second start collapses to the same reactor.
    assert {:ok, ^pid} = ReactorSupervisor.start_reactor(buf, "elixir")
  end

  test "stop releases the registration synchronously (immediate re-register works)" do
    buf = start_supervised!({Buffer, text: "x = 1\n"}, id: :stop_buf)
    {:ok, r1} = ReactorSupervisor.start_reactor(buf, "elixir")
    assert Reactor.for_buffer(buf) == {:ok, r1}

    assert :ok = Reactor.stop(r1)
    refute Process.alive?(r1)
    assert Reactor.for_buffer(buf) == :error

    # No stale {:already_started} from r1's dead registration.
    assert {:ok, r2} = ReactorSupervisor.start_reactor(buf, "elixir")
    assert r2 != r1
  end

  test "rewatch stops the stale reactor for a renamed buffer" do
    buf = start_supervised!({Buffer, text: "x = 1\n"}, id: :rewatch_buf)
    {:ok, r1} = ReactorSupervisor.start_reactor(buf, "elixir")

    # Gated off under mix test → rewatch stops the old reactor without starting a
    # new one; gated on (dev), watch/2 would then restart it for the new language.
    assert :ok = Reactor.rewatch(buf, "/tmp/whatever.json")
    refute Process.alive?(r1)
    assert Reactor.for_buffer(buf) == :error
  end
end
