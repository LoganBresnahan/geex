defmodule Geex.Highlight.SpanTest do
  use ExUnit.Case, async: true

  alias Geex.Highlight.Span

  defp span(s, e, cap \\ "x"), do: %Span{start_byte: s, end_byte: e, capture: cap}

  describe "shift_all/2 — insert (added > 0, removed == 0)" do
    test "spans entirely after the insert shift right by the added bytes" do
      ins = %{at: 5, removed: 0, added: 2}
      assert Span.shift_all([span(10, 15)], ins) == [span(12, 17)]
    end

    test "spans entirely before the insert are untouched" do
      ins = %{at: 20, removed: 0, added: 3}
      assert Span.shift_all([span(2, 8)], ins) == [span(2, 8)]
    end

    test "a span straddling the insert stretches to cover the inserted bytes" do
      # start <= at stays; end > at shifts — so [10,20] grows to [10,21] for a +1 insert at 15.
      assert Span.shift_all([span(10, 20)], %{at: 15, removed: 0, added: 1}) == [span(10, 21)]
    end

    test "an insert at a span's end boundary does not extend it (typed char excluded)" do
      assert Span.shift_all([span(10, 20)], %{at: 20, removed: 0, added: 1}) == [span(10, 20)]
    end

    test "an insert at a span's start boundary slides it right (typed char excluded, not swallowed)" do
      # The mirror image of the end-boundary case: a char typed at a token's start must
      # NOT take that token's colour — the token slides right, the new bytes stay neutral.
      assert Span.shift_all([span(8, 10)], %{at: 8, removed: 0, added: 2}) == [span(10, 12)]
    end

    test "a char typed between two adjacent tokens is left uncoloured by both" do
      spans = [span(2, 5, "keyword"), span(5, 9, "string")]
      # insert 2 bytes at the boundary (5): keyword end stays 5, string start slides to 7.
      assert Span.shift_all(spans, %{at: 5, removed: 0, added: 2}) ==
               [span(2, 5, "keyword"), span(7, 11, "string")]
    end
  end

  describe "shift_all/2 — delete (removed > 0, added == 0)" do
    test "spans after the deletion shift left by the removed bytes" do
      del = %{at: 5, removed: 3, added: 0}
      assert Span.shift_all([span(10, 15)], del) == [span(7, 12)]
    end

    test "a span fully inside the deleted region collapses and is dropped" do
      del = %{at: 5, removed: 10, added: 0}
      assert Span.shift_all([span(7, 12)], del) == []
    end

    test "a span straddling the deletion's end is clamped at the edit, then shifted" do
      # start 6 is inside [5,15) -> clamps to 5; end 20 >= 15 -> 20-10 = 10. [5,10].
      del = %{at: 5, removed: 10, added: 0}
      assert Span.shift_all([span(6, 20)], del) == [span(5, 10)]
    end
  end

  describe "shift_all/2 — replace (removed > 0, added > 0)" do
    test "tail shifts by the net delta (added - removed)" do
      rep = %{at: 4, removed: 2, added: 5}
      # delta = +3; a span past the removed region [10,14] -> [13,17].
      assert Span.shift_all([span(10, 14)], rep) == [span(13, 17)]
    end
  end

  describe "shift_all/2 — invariants" do
    test "every returned span is valid (start < end) and order is preserved" do
      spans = [span(0, 3, "a"), span(3, 9, "b"), span(9, 9, "empty"), span(9, 12, "c")]
      out = Span.shift_all(spans, %{at: 4, removed: 0, added: 1})
      assert Enum.all?(out, fn %Span{start_byte: s, end_byte: e} -> e > s end)
      assert Enum.map(out, & &1.capture) == ["a", "b", "c"]
    end

    test "an empty overlay stays empty" do
      assert Span.shift_all([], %{at: 0, removed: 0, added: 5}) == []
    end
  end
end
