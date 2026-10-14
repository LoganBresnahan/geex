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

  describe "gutter_width/1 — line-number gutter sizing" do
    test "a small file gets the two-digit minimum (4 columns)" do
      assert Loop.gutter_width("") == 4
      assert Loop.gutter_width("a\nb\nc") == 4
    end

    test "grows when the line count crosses a power of ten" do
      assert Loop.gutter_width(String.duplicate("x\n", 98) <> "x") == 4
      assert Loop.gutter_width(String.duplicate("x\n", 99) <> "x") == 5
    end
  end

  describe "frame/8 — screen + cursor (with the line-number gutter)" do
    setup do: %{theme: Geex.Theme.default()}

    test "paints the text inset past the gutter and offsets the cursor", %{theme: theme} do
      # "def\nend": 2 lines → gutter_width 4, so text starts at column 4.
      {screen, cursor, _hscroll} = Loop.frame("def\nend", [], theme, {1, 2}, 20, 3, 0)

      assert %Screen{} = screen
      assert Loop.gutter_width("def\nend") == 4
      assert Screen.get_cell(screen, 4, 0).char == "d"
      assert Screen.get_cell(screen, 4, 1).char == "e"
      # after "en" on line 1 → x 2 within the line, + 4 gutter columns = {6, 1}
      assert cursor == {6, 1}
    end

    test "draws right-aligned 1-based line numbers in the gutter", %{theme: theme} do
      {screen, _cursor, _hscroll} = Loop.frame("def\nend", [], theme, {0, 0}, 20, 3, 0)
      # 4-col gutter "  1 " / "  2 " → the digit lands at column 2.
      assert Screen.get_cell(screen, 2, 0).char == "1"
      assert Screen.get_cell(screen, 2, 1).char == "2"
    end

    test "brightens the cursor's line number, dims the rest", %{theme: theme} do
      pal = theme.palette
      {screen, _cursor, _hscroll} = Loop.frame("def\nend", [], theme, {1, 0}, 20, 3, 0)
      assert Screen.get_cell(screen, 2, 1).fg == pal.active_line_number
      assert Screen.get_cell(screen, 2, 0).fg == pal.line_number
    end

    test "rows past end-of-file carry no number", %{theme: theme} do
      {screen, _cursor, _hscroll} = Loop.frame("only", [], theme, {0, 0}, 20, 3, 0)
      assert Screen.get_cell(screen, 2, 0).char == "1"
      assert Screen.get_cell(screen, 2, 1).char == " "
    end
  end

  describe "frame/8 — horizontal scroll" do
    setup do: %{theme: Geex.Theme.default()}

    test "a line that fits leaves hscroll at 0", %{theme: theme} do
      {_screen, {cx, _cy}, hscroll} = Loop.frame("abc", [], theme, {0, 3}, 20, 3, 0, 0)
      assert hscroll == 0
      assert cx == 7
    end

    test "the cursor past the right edge scrolls the text left", %{theme: theme} do
      long = "abcdefghijklmnopqrst"
      # w 14, gutter 4 → text area 10 wide; cursor at column 15 is off the right.
      {screen, {cx, _cy}, hscroll} = Loop.frame(long, [], theme, {0, 15}, 14, 3, 0, 0)
      assert hscroll > 0
      # cursor stays inside the text area [4, 14)
      assert cx >= 4 and cx < 14
      # the first text column is no longer "a" — the line scrolled left
      assert Screen.get_cell(screen, 4, 0).char != "a"
    end

    test "moving back to the line start snaps hscroll to 0", %{theme: theme} do
      long = "abcdefghijklmnopqrst"
      {_screen, {cx, _cy}, hscroll} = Loop.frame(long, [], theme, {0, 1}, 14, 3, 0, 10)
      assert hscroll == 0
      assert cx == 5
    end
  end

  describe "frame/8 — current-line highlight" do
    setup do: %{theme: Geex.Theme.default()}

    test "tints the cursor's whole row (gutter + text) with active_line_bg", %{theme: theme} do
      pal = theme.palette
      {screen, _cursor, _hscroll} = Loop.frame("ab\ncd\nef", [], theme, {1, 0}, 20, 3, 0)
      # cursor on line 1 → its gutter cell and text cell carry the active-line background...
      assert Screen.get_cell(screen, 0, 1).bg == pal.active_line_bg
      assert Screen.get_cell(screen, 4, 1).bg == pal.active_line_bg
      # ...while another row keeps the plain editor background.
      assert Screen.get_cell(screen, 4, 0).bg == pal.bg
    end
  end

  describe "scrollbar_thumb/3 — scroll bar geometry (both axes)" do
    test "thumb length is proportional to the visible fraction" do
      # 10 of 20 cells visible → a half-length thumb at the start.
      assert {0, 5} = Loop.scrollbar_thumb(10, 20, 0)
    end

    test "the thumb travels from start to end with the scroll" do
      assert {0, 5} = Loop.scrollbar_thumb(10, 20, 0)
      assert {5, 5} = Loop.scrollbar_thumb(10, 20, 10)
    end

    test "a tiny viewport over a huge content still shows a one-cell thumb" do
      assert {0, 1} = Loop.scrollbar_thumb(10, 1000, 0)
    end
  end

  describe "max_line_width/1 — widest line in the whole buffer" do
    test "is the widest display width across all lines" do
      # "ijklmno" is the widest at 7 — regardless of which lines are on screen.
      assert Loop.max_line_width("ab\ncdef\ngh\nijklmno") == 7
    end

    test "counts display columns, so a wide glyph is two" do
      # "a中" = 1 + 2 = 3 columns.
      assert Loop.max_line_width("a\u{4E2D}") == 3
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

    test "a too-long left segment still keeps a space before the position" do
      assert Loop.status_text("doc.txt  a long notice", "5:16", 20) =~ "notice 5:16"
    end
  end
end
