defmodule Geex.Highlight.PaintTest do
  use ExUnit.Case, async: true

  alias Geex.{Highlight, Renderer, Screen}
  alias Geex.Highlight.{Paint, Span}

  doctest Paint

  @keyword_red {:rgb, 239, 93, 50}

  defp theme, do: Geex.Fixtures.birds()

  describe "to_screen/6 — project spans onto a styled cell grid" do
    test "styled bytes get the token colour; unstyled bytes get the palette fg" do
      text = "def x\nend"
      spans = [%Span{start_byte: 0, end_byte: 3, capture: "keyword"}]

      screen = Paint.to_screen(text, spans, theme(), 10, 5)

      # "def" is keyword-red on row 0.
      assert %{char: "d", fg: @keyword_red} = Screen.get_cell(screen, 0, 0)
      assert %{char: "f", fg: @keyword_red} = Screen.get_cell(screen, 2, 0)
      # The space and "x" are unstyled → editor foreground.
      assert %{char: " ", fg: fg} = Screen.get_cell(screen, 3, 0)
      assert fg == theme().palette.fg
      # Newline advances the row.
      assert %{char: "e"} = Screen.get_cell(screen, 0, 1)
    end

    test "scroll drops earlier rows (the first visible line moves to the top)" do
      text = "row0\nrow1\nrow2"
      screen = Paint.to_screen(text, [], theme(), 10, 5, 1)

      assert %{char: "r"} = Screen.get_cell(screen, 0, 0)
      assert %{char: "1"} = Screen.get_cell(screen, 3, 0)
    end

    test "multibyte graphemes advance one column but the right number of bytes" do
      text = "aé"
      # é occupies bytes 1..2; style it.
      spans = [%Span{start_byte: 1, end_byte: 3, capture: "keyword"}]
      screen = Paint.to_screen(text, spans, theme(), 5, 1)

      assert %{char: "a"} = Screen.get_cell(screen, 0, 0)
      assert %{char: "é", fg: @keyword_red} = Screen.get_cell(screen, 1, 0)
    end

    test "a span starting mid-grapheme still colours the grapheme" do
      text = "aé"
      # span covers only byte 2 (the interior byte of é at bytes 1..2)
      spans = [%Span{start_byte: 2, end_byte: 3, capture: "keyword"}]
      screen = Paint.to_screen(text, spans, theme(), 5, 1)

      assert %{char: "é", fg: @keyword_red} = Screen.get_cell(screen, 1, 0)
    end

    test "CRLF terminates the line and is not drawn as a cell" do
      screen = Paint.to_screen("ab\r\ncd", [], theme(), 10, 5)

      assert %{char: "a"} = Screen.get_cell(screen, 0, 0)
      assert %{char: "b"} = Screen.get_cell(screen, 1, 0)
      # The "\r\n" grapheme advances the row rather than painting a cell.
      assert Screen.get_cell(screen, 2, 0).char == " "
      assert %{char: "c"} = Screen.get_cell(screen, 0, 1)
      assert %{char: "d"} = Screen.get_cell(screen, 1, 1)
    end

    test "a wide glyph spans two columns; the next grapheme lands at column 2" do
      # "中x" — U+4E2D (3 bytes, wide) then "x". The span colours the wide glyph.
      text = "\u{4E2D}x"
      spans = [%Span{start_byte: 0, end_byte: 3, capture: "keyword"}]
      screen = Paint.to_screen(text, spans, theme(), 10, 1)

      assert %{char: "\u{4E2D}", fg: @keyword_red} = Screen.get_cell(screen, 0, 0)
      # Column 1 is the continuation: empty char, carrying the wide glyph's style
      # (so the renderer treats both halves as one styled run).
      assert %{char: "", fg: @keyword_red} = Screen.get_cell(screen, 1, 0)
      # "x" lands at column 2 — not column 1, which the wide glyph already covers.
      assert %{char: "x"} = Screen.get_cell(screen, 2, 0)
    end

    test "horizontal scroll drops graphemes past the left edge" do
      # "abc" scrolled right by 1 column → "a" is off-screen, "b" leads.
      screen = Paint.to_screen("abc", [], theme(), 6, 1, 0, 0, 1)
      assert Screen.get_cell(screen, 0, 0).char == "b"
      assert Screen.get_cell(screen, 1, 0).char == "c"
    end

    test "a wide glyph straddling the left edge shows a blank in its visible column" do
      # "中文": each is width 2. hscroll 1 scrolls off 中's left half; its right half
      # (column 0) becomes a blank, and 文 follows at columns 1–2.
      screen = Paint.to_screen("\u{4E2D}\u{6587}", [], theme(), 6, 1, 0, 0, 1)
      assert Screen.get_cell(screen, 0, 0).char == " "
      assert Screen.get_cell(screen, 1, 0).char == "\u{6587}"
      assert Screen.get_cell(screen, 2, 0).char == ""
    end
  end

  describe "to_screen/9 — selection background overlay" do
    alias Geex.Selection

    test "cells inside the selection get the palette selection bg; outside keep the editor bg" do
      sel = Selection.new({0, 1}) |> Selection.extend({0, 4})
      screen = Paint.to_screen("hello", [], theme(), 10, 1, 0, 0, 0, sel)
      sel_bg = theme().palette.selection
      bg = theme().palette.bg

      # half-open [1, 4): graphemes 1,2,3 selected; 0 and 4 not
      assert Screen.get_cell(screen, 0, 0).bg == bg
      assert Screen.get_cell(screen, 1, 0).bg == sel_bg
      assert Screen.get_cell(screen, 3, 0).bg == sel_bg
      assert Screen.get_cell(screen, 4, 0).bg == bg
    end

    test "the selection bg spans lines but keeps each cell's syntax fg" do
      src = "def f\nx = 1"
      {:ok, spans} = Highlight.spans(src, "elixir")
      sel = Selection.new({0, 0}) |> Selection.extend({1, 1})
      screen = Paint.to_screen(src, spans, theme(), 20, 2, 0, 0, 0, sel)

      # "def" keyword keeps its red fg AND gains the selection bg
      assert %{fg: @keyword_red, bg: sel_bg} = Screen.get_cell(screen, 0, 0)
      assert sel_bg == theme().palette.selection
      # line 1, col 0 is selected (it's < the {1,1} active end); col 1 is not
      assert Screen.get_cell(screen, 0, 1).bg == theme().palette.selection
      assert Screen.get_cell(screen, 1, 1).bg == theme().palette.bg
    end

    test "no selection (nil) leaves backgrounds at the editor bg" do
      screen = Paint.to_screen("hi", [], theme(), 5, 1, 0, 0, 0, nil)
      assert Screen.get_cell(screen, 0, 0).bg == theme().palette.bg
    end

    test "a multi-line selection fills each spanned line's newline region (no ragged edge)" do
      # {0,0}..{1,1} covers "ab", line 0's newline, and "c". The newline being selected fills
      # line 0's trailing run to the right edge; line 1's newline is *not* selected, so "cd"
      # ends without a trailing fill.
      sel = Selection.new({0, 0}) |> Selection.extend({1, 1})
      screen = Paint.to_screen("ab\ncd", [], theme(), 10, 2, 0, 0, 0, sel)
      sel_bg = theme().palette.selection
      bg = theme().palette.bg

      assert Screen.get_cell(screen, 0, 0).bg == sel_bg
      assert Screen.get_cell(screen, 1, 0).bg == sel_bg
      # the gap past "ab" to the right edge is filled (the selected newline)
      assert Screen.get_cell(screen, 2, 0).bg == sel_bg
      assert Screen.get_cell(screen, 9, 0).bg == sel_bg
      # line 1: only "c" is selected; its newline isn't, so no trailing fill past "cd"
      assert Screen.get_cell(screen, 0, 1).bg == sel_bg
      assert Screen.get_cell(screen, 1, 1).bg == bg
      assert Screen.get_cell(screen, 2, 1).bg == bg
    end

    test "a CRLF line keeps the \\r as a content column, so a selection over it aligns" do
      # "ab\r\ncd": Doc splits on \n only, so line 0 is "ab\r" (graphemes a,b,\r — len 3). A
      # selection {0,0}..{1,0} covers "ab", the zero-width \r, and the newline.
      sel = Selection.new({0, 0}) |> Selection.extend({1, 0})
      screen = Paint.to_screen("ab\r\ncd", [], theme(), 10, 2, 0, 0, 0, sel)
      sel_bg = theme().palette.selection

      assert Screen.get_cell(screen, 0, 0).bg == sel_bg
      assert Screen.get_cell(screen, 1, 0).bg == sel_bg
      # the \r is zero-width (no glyph), so content ends at column 2; the selected newline
      # fills from there to the edge — aligned with the Doc/cursor column model.
      assert Screen.get_cell(screen, 2, 0).bg == sel_bg
      assert Screen.get_cell(screen, 9, 0).bg == sel_bg
      # line 1 "cd" is past the half-open active end {1,0}, so it stays unselected
      assert Screen.get_cell(screen, 0, 1).bg == theme().palette.bg
    end
  end

  describe "end-to-end: reactor-shaped spans render to truecolor on screen" do
    test "real elixir highlighting projects + renders as 24-bit SGR" do
      src = "def f, do: :ok\n"
      {:ok, spans} = Highlight.spans(src, "elixir")

      screen = Paint.to_screen(src, spans, theme(), 40, 3)
      assert %{char: "d", fg: @keyword_red} = Screen.get_cell(screen, 0, 0)

      out = IO.iodata_to_binary(Renderer.diff(Screen.new(40, 3), screen))
      assert out =~ "38;2;239;93;50", "keyword red truecolor SGR present"
      assert out =~ "d"
    end
  end
end
