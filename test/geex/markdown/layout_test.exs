defmodule Geex.Markdown.LayoutTest do
  # The markdown preview's layout (ADR-0043 §4's corrections, §5, §6), parsed with the fixture
  # grammars. Each `describe` is one of the review's failure cases (doc/research/adr-0043-review.md).
  use ExUnit.Case, async: true

  alias Geex.Markdown
  alias Geex.Markdown.{Place, Style}

  doctest Place

  defp render(md, width \\ 60) do
    {:ok, grammars} = Markdown.handles()
    {:ok, parsed} = Markdown.parse(md, grammars)
    {parsed, Markdown.rows(parsed, width)}
  end

  defp rows(md, width \\ 60), do: md |> render(width) |> elem(1)
  defp text(row), do: Enum.map_join(row.runs, &elem(&1, 0))

  defp texts(md, width \\ 60),
    do: md |> rows(width) |> Enum.map(&(&1 |> text() |> String.trim_trailing()))

  defp roles(rows), do: for(r <- rows, {_t, roles} <- r.runs, role <- roles, do: role)

  test "every row fits the width, however narrow: a preview has no horizontal scroll (§1)" do
    md = "- a\n  - b\n    - c\n      - deep item with words\n\n> > quoted twice\n"

    for width <- [1, 3, 8, 20] do
      for row <- rows(md, width),
          do: assert(Geex.Markdown.Layout.runs_width(row.runs) <= width, inspect({width, row}))
    end
  end

  describe "F33: a table cell's column comes from the pipes before it" do
    test "an empty || cell keeps the rest of the row under its headers" do
      assert "│ x │   │ z │" in texts("| a | b | c |\n|---|---|---|\n|x||z|\n")
    end

    test "a row without a leading pipe, a pipe in a code span, and an escaped pipe" do
      t = texts("| a | b | c |\n|---|---|---|\nx || z\n| `p|q` | r | s |\n| p \\| q | r | s |\n")
      assert Enum.any?(t, &(&1 =~ ~r/^│ x\s+│\s+│ z │$/))
      # GFM splits the cell on a pipe inside a code span, so `p and q` are two cells, and the
      # fourth is past the header's count.
      assert Enum.any?(t, &(&1 =~ ~r/^│ `p\s+│ q`\s+│ r\s+│$/))
      assert Enum.any?(t, &(&1 =~ ~r/^│ p \| q │ r\s+│ s\s+│$/))
    end

    test "cells past the header's count are dropped, as GFM does" do
      assert "│ x │ y │" in texts("| a | b |\n|---|---|\n| x | y | z |\n")
    end
  end

  describe "F35: closing #s, list numbers and $…$ render as GitHub does" do
    test "a heading drops its closing sequence, not an escaped or attached one" do
      assert hd(texts("# Title ##\n")) == "Title"
      assert hd(texts("## Title #   \n")) == "Title"
      assert hd(texts("### foo \\###\n")) == "foo ###"
      assert hd(texts("# foo#\n")) == "foo#"
      assert hd(texts("# #\n")) == ""
    end

    test "an ordered list counts up from its first number, aligned right, keeping its delimiter" do
      assert texts("1. one\n1. two\n1. three\n") == ["1. one", "2. two", "3. three"]
      assert texts("3) a\n3) b\n") == ["3) a", "4) b"]
      assert texts("9. a\n9. b\n") == [" 9. a", "10. b"]
    end

    test "$…$ is math, drawn as code, only where GitHub reads it so" do
      prose = rows("It costs $5 and $10, and $HOME or $PATH.\n")
      refute :code in roles(prose)

      assert texts("It costs $5 and $10, and $HOME or $PATH.\n") == [
               "It costs $5 and $10, and $HOME or $PATH."
             ]

      math = rows("Area is $x^2$ here.\n")
      assert {"$x^2$", [:code]} in hd(math).runs

      for md <- ["a $x $ b\n", "a $ x$ b\n", "a $x$5 b\n", "a $x$b c\n"],
          do: refute(:code in roles(rows(md)), md)

      assert :code in roles(rows("a $5 and 10$ b\n"))
    end
  end

  describe "F34: a CRLF file renders like its LF twin" do
    test "html, front matter and indented code gain no stray rows and keep no \\r" do
      lf = "---\ntitle: x\n---\n\n<div>\nhtml\n</div>\n\n    code\n    more\n\npara\n"
      crlf = String.replace(lf, "\n", "\r\n")
      {lf_parsed, lf_rows} = render(lf)
      {crlf_parsed, crlf_rows} = render(crlf)

      assert Enum.map(crlf_rows, &text/1) == Enum.map(lf_rows, &text/1)
      refute Enum.any?(crlf_rows, &(text(&1) =~ "\r"))
      # Rows still name the same source lines.
      assert Place.lines(crlf_rows, crlf_parsed.text) == Place.lines(lf_rows, lf_parsed.text)
    end
  end

  describe "F36: code reads as code with no tint" do
    test "with the terminal theme and no OSC 11 answer, each code row starts with a ▏ bar" do
      theme = Geex.Theme.Terminal.theme(nil)
      assert theme.palette.active_line_bg == :default

      for row <- rows("```\nplain\ncode\n```\n") do
        {glyph, style} = Style.run(theme, hd(row.runs))
        assert glyph == "▏"
        assert style.fg == theme.palette.line_number
      end
    end

    test "a theme with a tint keeps the space" do
      theme = Geex.Fixtures.birds()
      [row | _] = rows("```\nplain\n```\n")
      assert {" ", style} = Style.run(theme, hd(row.runs))
      assert style.bg == theme.palette.active_line_bg
    end
  end

  describe "F30/F18: code runs carry capture names, resolved against the theme when drawn" do
    @code "```elixir\ndefmodule A do\n  def f(x), do: :ok\nend\n```\n"

    test "no colours in the rows, and the theme picks the same colour the editor would" do
      {parsed, rows} = render(@code)
      refute Enum.any?(roles(rows), &match?({:style, _}, &1))
      assert Enum.any?(roles(rows), &match?({:captures, [_ | _]}, &1))

      # The same bytes, highlighted for the editor: Paint's choice per byte.
      code = "defmodule A do\n  def f(x), do: :ok\nend"
      {:ok, spans} = Geex.Highlight.spans(code, "elixir")
      assert parsed.code[{code, "elixir"}] == spans

      for theme <- [Geex.Fixtures.birds(), Geex.Theme.Terminal.theme(nil)] do
        paint = Geex.Highlight.Paint.styles(theme, spans)
        lines = String.split(code, "\n")
        # Code rows follow the label row; each starts with the gutter run.
        for {line, row} <- Enum.zip(lines, Enum.drop(rows, 1)) do
          offset = line_offset(code, line)
          [_gutter | runs] = row.runs

          Enum.reduce(runs, 0, fn {t, roles} = run, at ->
            if at < byte_size(line) do
              {_t, style} = Style.run(theme, run)

              want = paint[offset + at]
              fg = if want && want.fg != :default, do: want.fg, else: theme.palette.fg
              assert style.fg == fg, "#{inspect(t)} #{inspect(roles)} in #{inspect(line)}"
            end

            at + byte_size(t)
          end)
        end
      end
    end

    test "captures are narrowest first, the most dotted first at equal width" do
      {_parsed, rows} = render(@code)

      for {:captures, names} <- roles(rows) do
        assert names == Enum.uniq(names)
      end
    end

    test "an info string reaches its grammar through the alias table" do
      assert Markdown.language("ex") == "elixir"
      assert Markdown.language("sh") == "bash"
      assert Markdown.language("Elixir") == "elixir"
      assert Markdown.language("cobol") == "cobol"

      {parsed, rows} = render("```ex\n:ok\n```\n")
      assert Map.has_key?(parsed.code, {":ok", "ex"})
      assert Enum.any?(roles(rows), &match?({:captures, [_ | _]}, &1))
      assert "elixir" in parsed.languages
    end
  end

  defp line_offset(code, line) do
    {at, _} = :binary.match(code, line)
    at
  end

  describe "F29: rows name the source line they draw, and the reader keeps their place" do
    @table "# Index\n\n| n | what |\n|---|---|\n" <>
             Enum.map_join(1..40, "", &"| #{&1} | row #{&1} |\n")

    test "each table row, code line and html line names its own line" do
      {parsed, rows} = render(@table)
      lines = Place.lines(rows, parsed.text)
      # The header is line 2, the delimiter line 3, the rows lines 4..43.
      body =
        for {row, line} <- Enum.zip(rows, Tuple.to_list(lines)), text(row) =~ ~r/^│ \d/, do: line

      assert body == Enum.to_list(4..43)

      {parsed, rows} = render("```sh\none\ntwo\n```\n\n<div>\nx\n</div>\n")
      # The label takes the fence line; the closing fence draws nothing; a blank row names none.
      assert Tuple.to_list(Place.lines(rows, parsed.text)) == [0, 1, 2, nil, 5, 6, 7]
    end

    test "a paragraph's wrapped rows keep the block's start" do
      {parsed, rows} = render("intro\n\n" <> String.duplicate("word ", 40) <> "\n", 20)
      lines = Tuple.to_list(Place.lines(rows, parsed.text))
      assert [0, 2 | wrapped] = Enum.reject(lines, &(&1 == nil))
      assert Enum.all?(wrapped, &(&1 == 2))
    end

    test "deep in a tall table, a re-render keeps the row on screen" do
      {parsed, rows} = render(@table)
      lines = Place.lines(rows, parsed.text)
      top = Enum.find_index(Tuple.to_list(lines), &(&1 == 30))
      anchor = Place.anchor(lines, top)
      assert anchor == {30, 0}

      # An agent appends a row: the reader stays on line 30, not the table's first row.
      {parsed2, rows2} = render(@table <> "| 41 | row 41 |\n")
      lines2 = Place.lines(rows2, parsed2.text)
      assert elem(lines2, Place.scroll(lines2, anchor)) == 30
    end

    test "inside a wrapped row the offset is kept, clamped to the line's rows" do
      md = "| a | b |\n|---|---|\n| #{String.duplicate("long ", 12)} | x |\n| next | y |\n"
      {parsed, rows} = render(md, 30)
      lines = Place.lines(rows, parsed.text)
      first = Enum.find_index(Tuple.to_list(lines), &(&1 == 2))
      assert elem(lines, first + 2) == 2
      anchor = Place.anchor(lines, first + 2)
      assert anchor == {2, 2}
      assert Place.scroll(lines, anchor) == first + 2

      # Wider, the row wraps less: the offset is clamped to its last row.
      {parsed, rows} = render(md, 50)
      lines = Place.lines(rows, parsed.text)
      i = Place.scroll(lines, anchor)
      assert elem(lines, i) == 2 and elem(lines, i + 1) != 2
    end

    test "a line with no rows goes to the nearest earlier line that has some" do
      # A link definition draws nothing.
      {parsed, rows} = render("one\n\n[foo]: /url \"title\"\n\nthree\n")
      lines = Place.lines(rows, parsed.text)
      i = Place.scroll(lines, {2, 0})
      assert elem(lines, i) == 0
      assert Place.scroll(lines, {0, 5}) == 0
      assert Place.scroll({}, {3, 0}) == 0
    end
  end
end
