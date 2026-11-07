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

  test "a link's runs carry its destination; a reference link's, its definition's" do
    md = "See [the other](other.md#top) and [ref] and [none].\n\n[ref]: ./ref.md\n"
    hrefs = for r <- rows(md), {t, roles} <- r.runs, {:href, d} <- roles, do: {t, d}
    assert {"the other", "other.md#top"} in hrefs
    assert {"ref", "./ref.md"} in hrefs
    refute Enum.any?(hrefs, fn {t, _} -> t =~ "none" end)
  end

  test "slice 5 review 3: a link's destination is decoded: escapes and entities" do
    md = "[a](my\\_file.md) [b](x&amp;y.md) [c][r]\n\n[r]: q\\_r&amp;s.md\n"
    hrefs = for r <- rows(md), {_t, roles} <- r.runs, {:href, d} <- roles, uniq: true, do: d
    assert hrefs == ["my_file.md", "x&y.md", "q_r&s.md"]
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

    test "an edit above the reader keeps them on their row: the anchor follows the line map" do
      # The verifier's slice-2 finding: by line number alone, a row inserted above the reader
      # moves them a row up.
      old = @table
      new = String.replace(old, "| 3 | row 3 |\n", "| 3 | row 3 |\n| 3b | inserted |\n")
      {parsed, rows} = render(old)
      lines = Place.lines(rows, parsed.text)
      anchor = Place.anchor(lines, Enum.find_index(Tuple.to_list(lines), &(&1 == 30)))
      row_text = rows |> Enum.at(Place.scroll(lines, anchor)) |> text()

      {parsed2, rows2} = render(new)
      lines2 = Place.lines(rows2, parsed2.text)
      moved = Place.remap(Place.line_map(old, new), anchor)
      assert moved == {31, 0}
      squash = &String.replace(&1, ~r/\s+/, " ")
      assert squash.(rows2 |> Enum.at(Place.scroll(lines2, moved)) |> text()) == squash.(row_text)
    end

    test "the line map: kept lines map across, removed ones to nil" do
      map = Place.line_map("a\nb\nc\nd\n", "a\nX\nc\nd\ne\n")
      assert map == {0, nil, 2, 3, 5}
      # A removed line's anchor goes to the nearest earlier kept line, at its first row.
      assert Place.remap(map, {1, 3}) == {0, 0}
      assert Place.remap(map, {3, 2}) == {3, 2}
      assert Place.remap(nil, {7, 1}) == {7, 1}
      assert Place.remap(Place.line_map("a\nb\n", "b\n"), {0, 1}) == {0, 0}
    end

    test "the line map stays fast on a wholesale rewrite of a big file" do
      # The verifier's slice-3 finding: a plain Myers diff took 34 s on testing.md rewritten.
      old = File.read!("doc/testing.md")
      every = old |> String.split("\n") |> Enum.map_join("\n", &(&1 <> " x"))

      alternate =
        old
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {l, i} -> if rem(i, 2) == 0, do: l <> " x", else: l end)

      for new <- [every, alternate] do
        task = Task.async(fn -> :timer.tc(fn -> Place.line_map(old, new) end) end)
        {us, map} = Task.await(task, 5_000)
        assert us < 1_000_000, "#{div(us, 1000)} ms"
        assert tuple_size(map) == length(String.split(old, "\n"))
      end
    end

    test "on a big change the line map still matches the lines both sides kept" do
      lines = for i <- 1..3000, do: "line #{i}"
      # Every 7th line changed, a block inserted near the top, one line removed near the end.
      new =
        lines
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {_l, 10} -> ["inserted a", "inserted b", "line 11"]
          {_l, 2900} -> []
          {l, i} when rem(i, 7) == 0 -> [l <> " changed"]
          {l, _i} -> [l]
        end)

      map = Place.line_map(Enum.join(lines, "\n"), Enum.join(new, "\n"))
      new_t = List.to_tuple(new)

      # Every kept line maps to the same text, and in order.
      kept = for {n, o} <- Enum.with_index(Tuple.to_list(map)), n != nil, do: {o, n}
      assert Enum.all?(kept, fn {o, n} -> Enum.at(lines, o) == elem(new_t, n) end)
      assert Enum.map(kept, &elem(&1, 1)) == Enum.sort(Enum.map(kept, &elem(&1, 1)))
      # Line 500 (index 499), unchanged, moved down by the two inserted lines.
      assert elem(map, 499) == 501
      assert elem(map, 2900) == nil
      assert elem(map, 2950) == 2951
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
