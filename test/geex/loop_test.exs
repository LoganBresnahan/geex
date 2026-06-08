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
end
