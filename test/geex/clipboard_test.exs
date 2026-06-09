defmodule Geex.ClipboardTest do
  use ExUnit.Case, async: true

  alias Geex.Clipboard

  setup do
    # An isolated instance so the global singleton (and other tests) are untouched.
    clip = start_supervised!({Clipboard, name: :"clip_#{:erlang.unique_integer([:positive])}"})
    %{clip: clip}
  end

  test "an empty ring yields \"\" on top", %{clip: clip} do
    assert Clipboard.top(clip) == ""
    assert Clipboard.ring(clip) == []
  end

  test "push makes the text the top entry; pushes stack newest-first", %{clip: clip} do
    :ok = Clipboard.push("first", clip)
    assert Clipboard.top(clip) == "first"
    :ok = Clipboard.push("second", clip)
    assert Clipboard.top(clip) == "second"
    assert Clipboard.ring(clip) == ["second", "first"]
  end

  test "push is synchronous, so an immediately following top sees it", %{clip: clip} do
    :ok = Clipboard.push("x", clip)
    assert Clipboard.top(clip) == "x"
  end

  test "the ring is capped (oldest entries fall off)", %{clip: clip} do
    for n <- 1..130, do: Clipboard.push("e#{n}", clip)
    ring = Clipboard.ring(clip)
    assert length(ring) == 100
    assert List.first(ring) == "e130"
    assert List.last(ring) == "e31"
  end
end
