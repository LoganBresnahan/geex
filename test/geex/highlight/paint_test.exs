defmodule Geex.Highlight.PaintTest do
  use ExUnit.Case, async: true

  alias Geex.{Highlight, Renderer, Screen}
  alias Geex.Highlight.{Paint, Span}

  @keyword_red {:rgb, 239, 93, 50}

  defp theme, do: Geex.Theme.default()

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
