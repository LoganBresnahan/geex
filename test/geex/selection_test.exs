defmodule Geex.SelectionTest do
  use ExUnit.Case, async: true

  alias Geex.Selection

  describe "new/1 + extend/2" do
    test "a new selection is collapsed at the position" do
      sel = Selection.new({2, 4})
      assert Selection.anchor(sel) == {2, 4}
      assert Selection.active(sel) == {2, 4}
      assert Selection.collapsed?(sel)
      assert Selection.range(sel) == {{2, 4}, {2, 4}}
    end

    test "extend moves the active end, leaving the anchor fixed" do
      sel = Selection.new({1, 0}) |> Selection.extend({3, 6})
      assert Selection.anchor(sel) == {1, 0}
      assert Selection.active(sel) == {3, 6}
      refute Selection.collapsed?(sel)
    end

    test "extend can be chained (the active end keeps moving)" do
      sel = Selection.new({0, 0}) |> Selection.extend({0, 5}) |> Selection.extend({0, 2})
      assert Selection.anchor(sel) == {0, 0}
      assert Selection.active(sel) == {0, 2}
    end
  end

  describe "range/1 — ordered, half-open carets" do
    test "forward selection: anchor before active" do
      sel = Selection.new({0, 1}) |> Selection.extend({0, 4})
      assert Selection.range(sel) == {{0, 1}, {0, 4}}
    end

    test "backward selection orders by document position, not by anchor/active" do
      sel = Selection.new({2, 3}) |> Selection.extend({0, 1})
      assert Selection.range(sel) == {{0, 1}, {2, 3}}
    end

    test "multi-line range orders by line first, then column" do
      sel = Selection.new({1, 9}) |> Selection.extend({1, 2})
      assert Selection.range(sel) == {{1, 2}, {1, 9}}
    end
  end

  describe "contains?/2 — half-open [start, end)" do
    test "a position inside the span is contained" do
      sel = Selection.new({0, 2}) |> Selection.extend({0, 6})
      assert Selection.contains?(sel, {0, 3})
    end

    test "the start caret is contained, the end caret is not (half-open)" do
      sel = Selection.new({0, 2}) |> Selection.extend({0, 6})
      assert Selection.contains?(sel, {0, 2})
      refute Selection.contains?(sel, {0, 6})
    end

    test "containment respects document order across lines" do
      sel = Selection.new({0, 5}) |> Selection.extend({2, 1})
      assert Selection.contains?(sel, {1, 0})
      assert Selection.contains?(sel, {0, 5})
      refute Selection.contains?(sel, {0, 4})
      refute Selection.contains?(sel, {2, 1})
    end

    test "a collapsed selection contains nothing" do
      sel = Selection.new({1, 1})
      refute Selection.contains?(sel, {1, 1})
    end
  end

  describe "select-all is caller-constructed (buffer-agnostic primitive)" do
    test "a selection over the whole buffer is new(top) extended to the last caret" do
      sel = Selection.new({0, 0}) |> Selection.extend({9, 12})
      assert Selection.range(sel) == {{0, 0}, {9, 12}}
      refute Selection.collapsed?(sel)
    end
  end
end
