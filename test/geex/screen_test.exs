defmodule Geex.ScreenTest do
  use ExUnit.Case, async: true

  alias Geex.{Cell, Screen}

  describe "new/2" do
    test "creates a screen with the given dimensions and no cells set" do
      s = Screen.new(80, 24)
      assert s.w == 80
      assert s.h == 24
      assert s.cells == %{}
    end
  end

  describe "get_cell/3" do
    test "unset coordinates return a blank cell" do
      s = Screen.new(5, 5)
      assert Screen.get_cell(s, 2, 2) == Cell.blank()
    end

    test "out-of-bounds coordinates return a blank cell" do
      s = Screen.new(5, 5)
      assert Screen.get_cell(s, -1, 0) == Cell.blank()
      assert Screen.get_cell(s, 5, 0) == Cell.blank()
      assert Screen.get_cell(s, 0, 5) == Cell.blank()
    end

    test "returns the cell that was set" do
      s = Screen.new(5, 5) |> Screen.set_cell(2, 3, %Cell{char: "x"})
      assert Screen.get_cell(s, 2, 3) == %Cell{char: "x"}
    end
  end

  describe "set_cell/4" do
    test "out-of-bounds writes are dropped" do
      s = Screen.new(5, 5) |> Screen.set_cell(10, 10, %Cell{char: "x"})
      assert s.cells == %{}
    end

    test "writing a blank cell removes the entry" do
      s =
        Screen.new(5, 5)
        |> Screen.set_cell(0, 0, %Cell{char: "x"})
        |> Screen.set_cell(0, 0, Cell.blank())

      assert s.cells == %{}
    end
  end

  describe "draw_text/5" do
    test "writes graphemes left to right" do
      s = Screen.new(10, 1) |> Screen.draw_text(2, 0, "hi")
      assert Screen.get_cell(s, 2, 0).char == "h"
      assert Screen.get_cell(s, 3, 0).char == "i"
      assert Screen.get_cell(s, 4, 0) == Cell.blank()
    end

    test "stops at the right edge (no wrap)" do
      s = Screen.new(3, 1) |> Screen.draw_text(1, 0, "abcdef")
      assert Screen.get_cell(s, 1, 0).char == "a"
      assert Screen.get_cell(s, 2, 0).char == "b"
      # c..f are out of bounds → dropped
      assert map_size(s.cells) == 2
    end

    test "applies style uniformly across the run" do
      style = %Cell{fg: {:ansi, 1}, attrs: [:bold]}
      s = Screen.new(5, 1) |> Screen.draw_text(0, 0, "ab", style)
      assert Screen.get_cell(s, 0, 0) == %Cell{char: "a", fg: {:ansi, 1}, attrs: [:bold]}
      assert Screen.get_cell(s, 1, 0) == %Cell{char: "b", fg: {:ansi, 1}, attrs: [:bold]}
    end

    test "multi-byte graphemes count as one column" do
      s = Screen.new(5, 1) |> Screen.draw_text(0, 0, "éé")
      assert Screen.get_cell(s, 0, 0).char == "é"
      assert Screen.get_cell(s, 1, 0).char == "é"
    end

    test "a wide glyph takes two columns; the next grapheme lands after it" do
      # U+5B57 字 (wide), then "x".
      s = Screen.new(5, 1) |> Screen.draw_text(0, 0, "\u{5B57}x")
      assert Screen.get_cell(s, 0, 0).char == "\u{5B57}"
      # Column 1 is the continuation (empty char), not "x".
      assert Screen.get_cell(s, 1, 0).char == ""
      assert Screen.get_cell(s, 2, 0).char == "x"
    end
  end

  describe "put_grapheme/4" do
    test "a narrow glyph occupies one column and advances by one" do
      {s, next} = Screen.put_grapheme(Screen.new(5, 1), 1, 0, %Cell{char: "a"})
      assert next == 2
      assert Screen.get_cell(s, 1, 0).char == "a"
    end

    test "a wide glyph occupies two columns (lead + continuation) and advances by two" do
      {s, next} = Screen.put_grapheme(Screen.new(5, 1), 0, 0, %Cell{char: "\u{5B57}", fg: {:ansi, 1}})
      assert next == 2
      assert Screen.get_cell(s, 0, 0) == %Cell{char: "\u{5B57}", fg: {:ansi, 1}}
      # The continuation shares the glyph's style but carries an empty char.
      assert Screen.get_cell(s, 1, 0) == %Cell{char: "", fg: {:ansi, 1}}
    end

    test "a zero-width grapheme places nothing and does not advance" do
      {s, next} = Screen.put_grapheme(Screen.new(5, 1), 2, 0, %Cell{char: "​"})
      assert next == 2
      assert s.cells == %{}
    end

    test "a wide glyph with no room for its continuation is padded blank, not half-drawn" do
      # 1-wide screen: a 2-column glyph cannot fit. It must not be placed (drawing
      # the lead alone would overflow the single column).
      {s, next} = Screen.put_grapheme(Screen.new(1, 1), 0, 0, %Cell{char: "\u{5B57}"})
      assert next == 2
      assert Screen.get_cell(s, 0, 0) == Cell.blank()
      assert s.cells == %{}
    end

    test "a wide glyph at the last column of a wider screen is also dropped, not half-drawn" do
      # Screen is 2 wide; placing at column 1 (the last) leaves no room for column 2.
      {s, next} = Screen.put_grapheme(Screen.new(2, 1), 1, 0, %Cell{char: "\u{5B57}"})
      assert next == 3
      assert Screen.get_cell(s, 1, 0) == Cell.blank()
    end
  end

  describe "fill_rect/6" do
    test "fills the rectangle with the cell" do
      s = Screen.new(5, 5) |> Screen.fill_rect(1, 1, 2, 2, %Cell{char: "#"})

      for x <- 1..2, y <- 1..2 do
        assert Screen.get_cell(s, x, y).char == "#"
      end

      assert Screen.get_cell(s, 0, 0) == Cell.blank()
      assert Screen.get_cell(s, 3, 3) == Cell.blank()
    end

    test "clips to screen bounds" do
      s = Screen.new(3, 3) |> Screen.fill_rect(2, 2, 5, 5, %Cell{char: "#"})
      # Only (2,2) is in-bounds for this 3x3 screen
      assert Screen.get_cell(s, 2, 2).char == "#"
      assert map_size(s.cells) == 1
    end
  end

  describe "resize/3" do
    test "drops cells outside the new bounds, keeps the rest" do
      s =
        Screen.new(5, 5)
        |> Screen.set_cell(1, 1, %Cell{char: "a"})
        |> Screen.set_cell(4, 4, %Cell{char: "b"})

      shrunk = Screen.resize(s, 3, 3)
      assert shrunk.w == 3
      assert shrunk.h == 3
      assert Screen.get_cell(shrunk, 1, 1).char == "a"
      assert Screen.get_cell(shrunk, 4, 4) == Cell.blank()
    end
  end

  describe "clear/1" do
    test "removes every cell" do
      s =
        Screen.new(5, 5)
        |> Screen.draw_text(0, 0, "hello")
        |> Screen.clear()

      assert s.cells == %{}
      assert s.w == 5
      assert s.h == 5
    end
  end
end
