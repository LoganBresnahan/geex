defmodule Geex.LoopTest do
  use ExUnit.Case, async: true

  alias Geex.{Loop, Screen}

  describe "cursor_xy/3 — width-correct cursor position" do
    test "ASCII: x is the grapheme count, y is the line minus scroll" do
      assert Loop.cursor_xy("hello", {0, 3}, 0) == {3, 0}
    end

    test "a wide glyph before the cursor shifts x by two" do
      # "a中" before the cursor occupies 1 + 2 = 3 columns (U+4E2D is wide).
      assert Loop.cursor_xy("a\u{4E2D}b", {0, 2}, 0) == {3, 0}
    end

    test "the cursor's line selects the line; col counts within it" do
      assert Loop.cursor_xy("ab\ncd", {1, 1}, 0) == {1, 1}
    end

    test "scroll lifts the row" do
      assert Loop.cursor_xy("a\nb\nc", {2, 0}, 1) == {0, 1}
    end

    test "col past the line end clamps to the line width" do
      assert Loop.cursor_xy("ab", {0, 9}, 0) == {2, 0}
    end

    test "a line past the text end is empty (x = 0)" do
      assert Loop.cursor_xy("ab", {3, 0}, 0) == {0, 3}
    end
  end

  describe "frame/7 — screen + cursor for the given inputs" do
    test "paints the text and reports the cursor position" do
      theme = Geex.Theme.default()
      {screen, cursor} = Loop.frame("def\nend", [], theme, {1, 2}, 20, 3, 0)

      assert %Screen{} = screen
      assert Screen.get_cell(screen, 0, 0).char == "d"
      assert Screen.get_cell(screen, 0, 1).char == "e"
      # cursor after "en" on line 1 → {x: 2, y: 1}
      assert cursor == {2, 1}
    end
  end

  describe "scroll_for/3 — keep the cursor's line in the viewport" do
    test "a visible cursor leaves the viewport put" do
      assert Loop.scroll_for(0, 5, 10) == 0
      assert Loop.scroll_for(3, 5, 10) == 3
    end

    test "a cursor below the viewport scrolls down so it lands on the bottom row" do
      # line 12 in a 10-row window → scroll 3 (shows lines 3..12; cursor at row 9)
      assert Loop.scroll_for(0, 12, 10) == 3
    end

    test "a cursor above the viewport scrolls up so it lands on the top row" do
      assert Loop.scroll_for(5, 3, 10) == 3
    end

    test "the top of the file pins scroll at 0" do
      assert Loop.scroll_for(4, 0, 10) == 0
    end

    test "a zero-height viewport is a no-op" do
      assert Loop.scroll_for(7, 100, 0) == 7
    end
  end
end
