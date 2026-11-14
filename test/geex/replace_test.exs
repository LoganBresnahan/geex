defmodule Geex.ReplaceTest do
  # `replace` / `replace-all`'s pure core (2026-11-13): one command per text replacing the
  # search's own matches.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.{Dispatch, EditorState, Gen, Replace, Search, Text}

  doctest Geex.Replace

  defp applied(text, cmd) do
    {:ok, state} = Dispatch.apply_command(cmd, EditorState.new(text))
    EditorState.text(state)
  end

  # The oracle: each line on its own, its matches (the search's) spliced out of the line's
  # original graphemes right to left, the replacement one element, joined at the end. A different
  # walk from the module's left-to-right one; it never re-splits edited text, where a replacement
  # starting with a combining mark would join the grapheme before it.
  defp expected(text, query, replacement) do
    text
    |> :binary.split("\n", [:global])
    |> Enum.map_join("\n", fn line ->
      line
      |> Search.line_matches(query)
      |> Enum.reverse()
      |> Enum.reduce(Text.graphemes(line), fn {s, e}, gs ->
        Enum.take(gs, s) ++ [replacement] ++ Enum.drop(gs, e)
      end)
      |> Enum.join()
    end)
  end

  test "smart case: a query with no capital replaces either case; with one, exactly" do
    {:ok, cmd, 2} = Replace.plan("Foo foo", "foo", "x")
    assert applied("Foo foo", cmd) == "x x"
    {:ok, cmd, 1} = Replace.plan("Foo foo", "Foo", "x")
    assert applied("Foo foo", cmd) == "x foo"
  end

  test "a CRLF file keeps its line ends; untouched lines keep everything" do
    text = "keep\r\nfoo here\r\nkeep too\r\nfoo\r\n"
    {:ok, cmd, 2} = Replace.plan(text, "foo", "bar")
    assert applied(text, cmd) == "keep\r\nbar here\r\nkeep too\r\nbar\r\n"
  end

  test "a line with a byte that isn't UTF-8 and wide characters around the match" do
    text = <<"文 foo ", 0xFF, " foo 😀\n">>
    {:ok, cmd, 2} = Replace.plan(text, "foo", "é")
    assert applied(text, cmd) == <<"文 é ", 0xFF, " é 😀\n">>
  end

  test "the replacement holding the query is not searched again; an empty one deletes" do
    {:ok, cmd, 2} = Replace.plan("aa aa", "aa", "aaa")
    assert applied("aa aa", cmd) == "aaa aaa"
    {:ok, cmd, 1} = Replace.plan("x-y", "-", "")
    assert applied("x-y", cmd) == "xy"
  end

  # The deep run's counterexample (it was the first oracle's mistake, not the module's): a
  # replacement that is a lone combining mark replaces each match, though it joins the grapheme
  # before it in the result.
  test "a replacement that is a combining mark replaces every match" do
    {:ok, cmd, 2} = Replace.plan("yy", "y", "\u0301")
    assert applied("yy", cmd) == "\u0301\u0301"
  end

  test "no match, an empty query: nothing to do" do
    assert Replace.plan("abc", "", "x") == :none
    assert Replace.plan("", "a", "x") == :none
  end

  test "the command is the human's" do
    {:ok, cmd, 1} = Replace.plan("a", "a", "b")
    assert cmd.meta.actor == :human
  end

  property "the result is the search's matches replaced; the count is the search's; lines stay" do
    check all(
            text <- Gen.text(),
            query <- one_of([Gen.fragment(max_length: 2), constant("a")]),
            replacement <- Gen.fragment(max_length: 3)
          ) do
      case Replace.plan(text, query, replacement) do
        :none ->
          assert Search.count(Search.matches(text, query)) == 0

        {:ok, cmd, n} ->
          assert n == Search.count(Search.matches(text, query))
          result = applied(text, cmd)
          assert result == expected(text, query, replacement)

          assert length(:binary.split(result, "\n", [:global])) ==
                   length(:binary.split(text, "\n", [:global]))
      end
    end
  end
end
