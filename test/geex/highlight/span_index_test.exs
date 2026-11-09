defmodule Geex.Highlight.SpanIndexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.Highlight.{Span, SpanIndex}

  doctest SpanIndex

  # ADR-0044: for any spans and any windows, the index finds what a walk over every span keeps.
  property "a window holds exactly the spans a walk over all of them would keep" do
    check all(
            spans <- list_of(span(), max_length: 300),
            windows <-
              list_of(tuple({integer(0..2_400), integer(0..500)}), min_length: 1, max_length: 20)
          ) do
      index = SpanIndex.build(spans)

      for {from, width} <- windows do
        to = from + width
        walked = Enum.filter(spans, &(&1.end_byte > from and &1.start_byte < to))
        assert Enum.sort(SpanIndex.window(index, from, to)) == Enum.sort(walked)
      end
    end
  end

  defp span do
    gen all(start <- integer(0..2_000), length <- integer(0..300)) do
      %Span{start_byte: start, end_byte: start + length, capture: "c"}
    end
  end

  test "no spans: every window is empty" do
    assert SpanIndex.window(SpanIndex.build([]), 0, 100) == []
  end
end
