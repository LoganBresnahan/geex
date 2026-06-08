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

  describe "scroll_for/4 — with a scrolloff margin" do
    test "scrolls early to keep the margin below the cursor" do
      # 20-row window, scrolloff 3: the cursor must stay 3 rows off the bottom, so a
      # cursor on line 10 (already visible at row 10) still doesn't scroll...
      assert Loop.scroll_for(0, 10, 20, 3) == 0
      # ...but line 17 is within 3 of the bottom (row 17 of 0..19) → scroll by 1.
      assert Loop.scroll_for(0, 17, 20, 3) == 1
    end

    test "scrolls early to keep the margin above the cursor" do
      # Viewport shows lines 10..29; cursor on line 11 is within 3 of the top → scroll up.
      assert Loop.scroll_for(10, 11, 20, 3) == 8
    end

    test "the top of the file pins scroll at 0 — the cursor rides above the margin" do
      assert Loop.scroll_for(0, 0, 20, 3) == 0
      assert Loop.scroll_for(0, 2, 20, 3) == 0
    end

    test "the margin is clamped to half the window so the bands never cross" do
      # h = 5 → margin clamps to div(4, 2) = 2, not the requested 10.
      assert Loop.scroll_for(0, 3, 5, 10) == 1
    end

    test "scrolloff 0 matches the no-margin edge alignment" do
      assert Loop.scroll_for(0, 12, 10, 0) == Loop.scroll_for(0, 12, 10)
    end
  end

  describe "status_text/3 — fixed-width status line" do
    test "pads the label left and the position flush right" do
      bar = Loop.status_text("foo.ex", "12:4", 20)
      assert String.length(bar) == 20
      assert String.starts_with?(bar, " foo.ex")
      assert String.ends_with?(bar, "12:4 ")
    end

    test "an empty right segment still fills the width" do
      bar = Loop.status_text("[no buffer]", "", 20)
      assert String.length(bar) == 20
      assert String.starts_with?(bar, " [no buffer]")
    end

    test "over-long content runs past the width (the renderer clips it)" do
      # left + right already exceed 8 columns, so there is no padding and the string
      # runs long; the screen clips it at the edge rather than this truncating.
      bar = Loop.status_text("a-very-long-name.ex", "999:42", 8)
      assert String.length(bar) > 8
    end
  end
end
