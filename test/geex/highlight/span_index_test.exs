defmodule Geex.Highlight.SpanIndexTest do
  use ExUnit.Case, async: true

  alias Geex.Highlight.{Span, SpanIndex}

  doctest SpanIndex

  test "a window holds exactly the spans a walk over all of them would keep" do
    :rand.seed(:exsss, {1, 2, 3})

    spans =
      for _ <- 1..2_000 do
        start = :rand.uniform(10_000) - 1
        %Span{start_byte: start, end_byte: start + :rand.uniform(300), capture: "c"}
      end

    index = SpanIndex.build(spans)

    for _ <- 1..200 do
      from = :rand.uniform(10_400) - 1
      to = from + :rand.uniform(500)
      walked = Enum.filter(spans, &(&1.end_byte > from and &1.start_byte < to))
      assert Enum.sort(SpanIndex.window(index, from, to)) == Enum.sort(walked)
    end
  end

  test "no spans: every window is empty" do
    assert SpanIndex.window(SpanIndex.build([]), 0, 100) == []
  end
end
