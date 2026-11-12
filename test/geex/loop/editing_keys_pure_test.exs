defmodule Geex.Loop.EditingKeysPureTest do
  # ADR-0052's pure edits and selections in `Geex.Loop.Keymap`: their laws as properties, and the
  # cases worth pinning.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.Buffer.Doc
  alias Geex.Commands.{Insert, Replace}
  alias Geex.Loop.Keymap

  defp line,
    do:
      member_of([
        "",
        "x",
        "  x",
        "\tx",
        "   ",
        "a b",
        "x\r",
        "  y\r",
        "\r",
        "é",
        "  👍🏽 é",
        "# c",
        "  #d",
        "f(a, [b])"
      ])

  defp text_of(lines, final_break?),
    do: Enum.join(lines, "\n") <> if(final_break?, do: "\n", else: "")

  defp run(text, %Insert{line: l, col: c, text: t}),
    do: text |> Doc.new() |> Doc.insert({l, c}, t) |> ok() |> Doc.text()

  defp run(text, %Replace{} = cmd) do
    range = {{cmd.start_line, cmd.start_col}, {cmd.end_line, cmd.end_col}}
    text |> Doc.new() |> Doc.replace(range, cmd.text) |> ok() |> Doc.text()
  end

  defp ok({:ok, doc}), do: doc

  defp ending(l), do: if(String.ends_with?(l, "\r"), do: "\r", else: "")
  defp body(l), do: String.replace_suffix(l, "\r", "")

  property "moving lines up then down (or down then up) gives the text back; endings stay put" do
    check all(
            lines <- list_of(line(), min_length: 1, max_length: 10),
            final <- boolean(),
            a <- integer(0..(length(lines) - 1)),
            b <- integer(a..(length(lines) - 1)),
            dir <- member_of([:up, :down])
          ) do
      text = text_of(lines, final)
      # The empty line after a final line break isn't one to swap with.
      count = length(String.split(text, "\n"))
      top = if String.ends_with?(text, "\n"), do: count - 2, else: count - 1

      case Keymap.move_lines(text, {a, b}, dir) do
        nil ->
          assert b > top or (dir == :up and a == 0) or (dir == :down and b == top)

        {cmd, d} ->
          moved = run(text, cmd)
          after_lines = String.split(moved, "\n")
          before_lines = String.split(text, "\n")
          assert length(after_lines) == length(before_lines)
          assert Enum.map(after_lines, &ending/1) == Enum.map(before_lines, &ending/1)

          assert Enum.sort(Enum.map(after_lines, &body/1)) ==
                   Enum.sort(Enum.map(before_lines, &body/1))

          back = if dir == :up, do: :down, else: :up

          case Keymap.move_lines(moved, {a + d, b + d}, back) do
            # The one way back refused: the text's last line was moved up past an empty line, so
            # the text now ends in a line break, and the empty line after it isn't one to swap
            # with (ADR-0052 §6).
            nil ->
              assert String.ends_with?(moved, "\n") and not String.ends_with?(text, "\n")

            {cmd2, _} ->
              assert run(moved, cmd2) == text
          end
      end
    end
  end

  property "duplicating lines adds exactly them, below, and changes nothing else" do
    check all(
            lines <- list_of(line(), min_length: 1, max_length: 10),
            final <- boolean(),
            a <- integer(0..(length(lines) - 1)),
            b <- integer(a..(length(lines) - 1))
          ) do
      text = text_of(lines, final)
      {cmd, n} = Keymap.duplicate_lines(text, {a, b})
      assert n == b - a + 1
      old = String.split(text, "\n")
      new = String.split(run(text, cmd), "\n")
      assert length(new) == length(old) + n
      assert Enum.take(new, a) == Enum.take(old, a)
      assert Enum.drop(new, b + 1 + n) == Enum.drop(old, b + 1)
      # The copy's and the original's text, whatever line break joins them.
      assert Enum.map(Enum.slice(new, (b + 1)..(b + n)), &body/1) ==
               Enum.map(Enum.slice(old, a..b), &body/1)

      assert Enum.map(Enum.slice(new, a..b), &body/1) == Enum.map(Enum.slice(old, a..b), &body/1)
    end
  end

  property "commenting lines not all commented, then again, gives them back; others never change" do
    check all(
            lines <- list_of(line(), min_length: 1, max_length: 10),
            a <- integer(0..(length(lines) - 1)),
            b <- integer(a..(length(lines) - 1)),
            marker <- member_of(["#", "//", "--"])
          ) do
      text = Enum.join(lines, "\n")

      case Keymap.comment_lines(text, {a, b}, marker) do
        nil ->
          assert Enum.all?(Enum.slice(lines, a..b), &(String.trim(&1) == ""))

        {cmd, _changes} ->
          commented = run(text, cmd)
          new = String.split(commented, "\n")

          for {{old, now}, i} <- Enum.with_index(Enum.zip(lines, new)),
              i < a or i > b or String.trim(old) == "",
              do: assert(now == old)

          filled = for l <- Enum.slice(lines, a..b), String.trim(l) != "", do: l
          all? = Enum.all?(filled, &(&1 |> String.trim_leading() |> String.starts_with?(marker)))

          if not all? do
            {cmd2, _} = Keymap.comment_lines(commented, {a, b}, marker)
            assert run(commented, cmd2) == text
          end
      end
    end
  end

  property "moving selected text keeps it whole, keeps the line's graphemes; there and back" do
    check all(
            l <- string(Enum.concat([?a..?c, [?\s, ?,, ?(]]), min_length: 1, max_length: 12),
            a <- integer(0..(String.length(l) - 1)),
            b <- integer((a + 1)..String.length(l)),
            how <-
              member_of([:left, :right, :word_back, :word_forward, :line_start, :line_end])
          ) do
      text = "first\n" <> l <> "\nlast"
      sel = String.slice(l, a..(b - 1))

      with {cmd, {1, f}, {1, t}} <- Keymap.move_text(text, {{1, a}, {1, b}}, how) do
        moved = run(text, cmd)
        [first, new_l, last] = String.split(moved, "\n")
        assert {first, last} == {"first", "last"}
        assert String.slice(new_l, f..(t - 1)) == sel
        assert Enum.sort(String.graphemes(new_l)) == Enum.sort(String.graphemes(l))

        back = %{left: :right, right: :left, word_back: :word_forward, word_forward: :word_back}
        # A word swap undoes itself when the selection is a whole word (space to space, ADR-0052
        # §2): inside one, the word beside it is only the word's other part.
        space? = &(&1 in [nil, " "])

        whole_word? =
          not String.contains?(sel, " ") and a > 0 and space?.(String.at(l, a - 1)) and
            space?.(String.at(l, b))

        if back[how] && (how in [:left, :right] or whole_word? or a == 0) do
          {cmd2, {1, ^a}, {1, ^b}} = Keymap.move_text(moved, {{1, f}, {1, t}}, back[how])
          assert run(moved, cmd2) == text
        end
      end
    end
  end

  property "a bracket's pair's pair is the bracket" do
    check all(
            lines <-
              list_of(string(Enum.concat([~c"()[]{}", ~c"ab "]), max_length: 10),
                min_length: 1,
                max_length: 5
              ),
            l <- integer(0..(length(lines) - 1)),
            c <- integer(0..String.length(Enum.at(lines, l)))
          ) do
      text = Enum.join(lines, "\n")
      g = String.at(Enum.at(lines, l), c)

      if g in ~w|( ) [ ] { }| do
        case Keymap.matching_bracket({l, c}, text) do
          nil -> :ok
          pair -> assert Keymap.matching_bracket(pair, text) == {l, c}
        end
      end
    end
  end

  property "a bigger selection holds the smaller one" do
    check all(
            lines <- list_of(line(), min_length: 1, max_length: 6),
            l <- integer(0..(length(lines) - 1)),
            c <- integer(0..String.length(body(Enum.at(lines, l)))),
            kind <- member_of([:char, :word, :line])
          ) do
      text = Enum.join(lines, "\n")

      with {from, to} = range <- Keymap.select_more(kind, text, {l, c}, nil) do
        assert from < to

        with {from2, to2} <- Keymap.select_more(kind, text, to, range) do
          assert from2 <= from and to2 >= to and {from2, to2} != range
        end
      end
    end
  end

  describe "the cases" do
    test "a word runs from space to space: punctuation is part of it" do
      assert Keymap.select_more(:word, "foo(bar_1, baz)", {0, 3}, nil) == {{0, 0}, {0, 10}}
      assert Keymap.select_more(:word, "  x", {0, 0}, nil) == {{0, 2}, {0, 3}}
      assert Keymap.select_more(:word, "x ()", {0, 4}, nil) == {{0, 2}, {0, 4}}
      assert Keymap.select_more(:word, " \t ", {0, 1}, nil) == nil
      # A tab separates words as a space does.
      assert Keymap.select_more(:word, "a\tb.c", {0, 3}, nil) == {{0, 2}, {0, 5}}
      # Taking in the next word crosses a line.
      assert Keymap.select_more(:word, "ab\n cd", {0, 2}, {{0, 0}, {0, 2}}) == {{0, 0}, {1, 3}}
    end

    test "select line: the last line ends at its end; an empty last line is nothing" do
      assert Keymap.select_more(:line, "a\nbc", {1, 0}, nil) == {{1, 0}, {1, 2}}
      assert Keymap.select_more(:line, "a\n", {1, 0}, nil) == nil
      # A selection within a line takes in its whole line first.
      assert Keymap.select_more(:line, "abc\nd", {0, 2}, {{0, 1}, {0, 2}}) == {{0, 0}, {1, 0}}
    end

    test "select character: one grapheme, an emoji whole; at a line's end, the line break" do
      assert Keymap.select_more(:char, "👍🏽x", {0, 0}, nil) == {{0, 0}, {0, 1}}
      assert Keymap.select_more(:char, "a\nb", {0, 1}, nil) == {{0, 1}, {1, 0}}
      assert Keymap.select_more(:char, "a", {0, 1}, nil) == nil
    end

    test "the bracket around, across lines and past other pairs" do
      text = "f(a) {\n  [x]\n  y\n}"
      assert Keymap.matching_bracket({2, 2}, text) == {0, 5}
      assert Keymap.matching_bracket({0, 5}, text) == {3, 0}
      # Just after a bracket is on it: the `[` before the cursor goes to its `]`.
      assert Keymap.matching_bracket({1, 3}, text) == {1, 4}
      assert Keymap.matching_bracket({1, 5}, text) == {1, 2}
      assert Keymap.matching_bracket({0, 0}, "x)") == nil
    end

    test "comment markers by name and extension; none for block-only languages" do
      assert Keymap.comment_marker("/p/Dockerfile") == "#"
      assert Keymap.comment_marker("/p/GNUmakefile") == "#"
      assert Keymap.comment_marker("/p/x.erl") == "%"
      assert Keymap.comment_marker("/p/x.lisp") == ";"
      assert Keymap.comment_marker("/p/x.html") == nil
      assert Keymap.comment_marker("/p/x.json") == nil
      assert Keymap.comment_marker("/p/README") == nil
    end

    test "commenting a CRLF line keeps its ending; uncommenting takes one space only" do
      {cmd, _} = Keymap.comment_lines("a\r\n  b\r\n", {0, 1}, "//")
      assert run("a\r\n  b\r\n", cmd) == "// a\r\n//   b\r\n"
      {cmd, _} = Keymap.comment_lines("#  x\n", {0, 0}, "#")
      assert run("#  x\n", cmd) == " x\n"
    end

    test "moving to the line's start stops after the indent, then at 0" do
      {cmd, from, _} = Keymap.move_text("  ab cd", {{0, 5}, {0, 7}}, :line_start)
      assert {run("  ab cd", cmd), from} == {"  cdab ", {0, 2}}
      {cmd, from, _} = Keymap.move_text("  ab", {{0, 1}, {0, 2}}, :line_start)
      assert {run("  ab", cmd), from} == {"  ab", {0, 0}}
      assert Keymap.move_text("ab", {{0, 0}, {0, 1}}, :line_start) == nil
      assert Keymap.move_text("ab", {{0, 1}, {0, 2}}, :line_end) == nil
      assert Keymap.move_text("ab\ncd", {{0, 1}, {1, 1}}, :right) == nil
    end
  end
end
