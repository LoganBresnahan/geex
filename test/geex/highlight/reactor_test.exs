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

  test "fires off the command stream: a dispatched edit re-highlights", %{
    buf: buf,
    reactor: reactor
  } do
    {:ok, _} = Reactor.await(reactor, 0)

    # Insert a comment; version goes 0 -> 1.
    assert {:ok, snap} = Buffer.dispatch(buf, insert(1, 0, "  # note\n"))
    assert snap.version == 1

    assert {:ok, overlay} = Reactor.await(reactor, 1)
    assert overlay.version == 1
    # The new comment is now highlighted.
    assert "comment" in captures(overlay)
  end

  test "render/1 returns the exact overlay when nothing is pending", %{reactor: reactor} do
    {:ok, exact} = Reactor.await(reactor, 0)
    assert Reactor.render(reactor) == exact
  end

  test "render/1 returns an optimistically byte-shifted overlay across an edit", %{
    buf: buf,
    reactor: reactor
  } do
    {:ok, exact} = Reactor.await(reactor, 0)
    refute exact.spans == []

    # Simulate the buffer's post-dispatch emit for a 2-byte insert at offset 0 (version 1),
    # ahead of the real re-highlight: render/1 must serve the shifted overlay so the painted
    # colours stay aligned, while highlights/1 keeps the exact result.
    footprint = %{at: 0, removed: 0, added: 2}
    send(reactor, {:geex_buffer_change, buf, 1, footprint})

    render = Reactor.render(reactor)
    assert render.version == 1
    assert render.spans == Geex.Highlight.Span.shift_all(exact.spans, footprint)
    # The authoritative overlay is untouched by the optimism (still the exact v0 pass).
    assert Reactor.highlights(reactor).version == 0
  end

  test "an :unknown-footprint edit keeps the prior optimistic overlay (no version regression)", %{
    buf: buf,
    reactor: reactor
  } do
    {:ok, _exact} = Reactor.await(reactor, 0)
    fp = %{at: 0, removed: 0, added: 1}
    send(reactor, {:geex_buffer_change, buf, 1, fp})
    send(reactor, {:geex_buffer_change, buf, 2, fp})
    assert Reactor.render(reactor).version == 2

    # A non-shiftable (multi-block `edit`) change must NOT drop render back to the old
    # exact result — it keeps the still-valid shifts the prior edits accumulated.
    send(reactor, {:geex_buffer_change, buf, 3, :unknown})
    assert Reactor.render(reactor).version == 2
  end

  test "a :reset (undo) change drops the optimistic overlay so render re-derives (ADR-0031)", %{
    buf: buf,
    reactor: reactor
  } do
    {:ok, exact} = Reactor.await(reactor, 0)
    fp = %{at: 0, removed: 0, added: 1}
    send(reactor, {:geex_buffer_change, buf, 1, fp})
    send(reactor, {:geex_buffer_change, buf, 2, fp})
    assert Reactor.render(reactor).version == 2

    # Undo emits a :reset at a LOWER version. Unlike :unknown, the optimistic overlay must be
    # DROPPED (undo moved the version backwards — keeping it would freeze stale colours across a
    # run of undos), so render falls back to the exact result rather than the version-2 overlay.
    send(reactor, {:geex_buffer_change, buf, 0, :reset})
    assert Reactor.render(reactor) == exact
    assert Reactor.render(reactor).version == 0
  end

  describe "render_overlay/1 — the paint-overlay selection (pure)" do
    test "the optimistic overlay always wins when present" do
      opt = %{version: 3, spans: [:o]}

      assert Reactor.render_overlay(%{
               optimistic: opt,
               result: %{version: 1, spans: [:r]},
               in_flight: nil
             }) == opt
    end

    test "serves the exact result when no pass is in flight" do
      res = %{version: 2, spans: [:r]}
      assert Reactor.render_overlay(%{optimistic: nil, result: res, in_flight: nil}) == res
    end

    test "serves the result while an in-flight pass is at or ahead of it (forward editing)" do
      res = %{version: 1, spans: [:r]}

      assert Reactor.render_overlay(%{optimistic: nil, result: res, in_flight: %{version: 2}}) ==
               res
    end

    test "suppresses a result stranded AHEAD of an in-flight pass at a lower version (post-undo)" do
      # undo moved the version backwards: `result` holds the pre-undo (v2) spans while the
      # corrective pass runs at v0 — painting them would be byte-misaligned, so serve nil.
      res = %{version: 2, spans: [:stale]}

      assert Reactor.render_overlay(%{optimistic: nil, result: res, in_flight: %{version: 0}}) ==
               nil
    end

    test "nil result with a pass in flight yields nil (the initial pass)" do
      assert Reactor.render_overlay(%{optimistic: nil, result: nil, in_flight: %{version: 0}}) ==
               nil
    end
  end

  test "subscribe/2 returns the current overlay so a subscriber can paint immediately", %{
    reactor: reactor
  } do
    {:ok, _} = Reactor.await(reactor, 0)
    assert %{version: 0, spans: _} = Reactor.subscribe(reactor)
  end

  test "subscribe/2 pushes {:geex_highlights, buffer, version} when a pass lands", %{
    buf: buf,
    reactor: reactor
  } do
    # Drain the initial pass, then subscribe, so we observe the EDIT's notification.
    {:ok, _} = Reactor.await(reactor, 0)
    Reactor.subscribe(reactor)

    {:ok, snap} = Buffer.dispatch(buf, insert(1, 0, "  # note\n"))
    assert_receive {:geex_highlights, ^buf, version}, 1_000
    assert version >= snap.version
  end

  test "unsubscribe/2 stops overlay-ready notifications", %{buf: buf, reactor: reactor} do
    {:ok, _} = Reactor.await(reactor, 0)
    Reactor.subscribe(reactor)
    Reactor.unsubscribe(reactor)
    # A sync round-trip ensures the unsubscribe cast is processed before the edit.
    _ = Reactor.highlights(reactor)

    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "q = 1\n"))
    refute_receive {:geex_highlights, ^buf, _}, 300
  end

  test "a subscriber that exits is dropped without disturbing the reactor", %{
    buf: buf,
    reactor: reactor
  } do
    {:ok, _} = Reactor.await(reactor, 0)
    test = self()

    sub =
      spawn(fn ->
        Reactor.subscribe(reactor)
        send(test, :subscribed)
        Process.sleep(:infinity)
      end)

    assert_receive :subscribed, 1_000
    Process.exit(sub, :kill)

    # The reactor survives the dead subscriber and keeps notifying the live one
    # (the test process subscribes itself via the default pid).
    Reactor.subscribe(reactor)
    {:ok, snap} = Buffer.dispatch(buf, insert(0, 0, "z = 0\n"))
    assert_receive {:geex_highlights, ^buf, v}, 1_000
    assert v >= snap.version
    assert Process.alive?(reactor)
  end

  test "latest-wins: a burst of edits coalesces to an overlay for the newest text", %{
    buf: buf,
    reactor: reactor
  } do
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
    assert Reactor.highlights(reactor) in [nil] or
             match?(%{spans: _}, Reactor.highlights(reactor))

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
