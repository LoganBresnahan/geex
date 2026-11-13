defmodule Geex.SearchTest do
  # ADR-0053 and its 2026-11-13 amendment: where a query's matches are, and where Alt+N goes.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.{Gen, Search, Text}

  doctest Geex.Search

  # mod-verify's R12: a reference that shares nothing with the implementation. Every position
  # where the query's graphemes occur (overlapping), then the leftmost non-overlapping of them,
  # over plain lists from Geex.Text.graphemes/1 (no tuples, no :binary.matches, no ASCII path).
  defp reference(text, query) do
    gq = Text.graphemes(query)
    fold? = Enum.any?(gq, &(String.downcase(&1) != &1)) |> Kernel.not()
    f = fn gs -> if fold?, do: Enum.map(gs, &String.downcase/1), else: gs end
    q = f.(gq)
    n = length(q)

    if n == 0 do
      []
    else
      text
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, i} ->
        gs = line |> String.replace_suffix("\r", "") |> Text.graphemes() |> f.()
        starts = for s <- 0..(length(gs) - n)//1, Enum.slice(gs, s, n) == q, do: s

        starts
        |> Enum.reduce({[], -1}, fn s, {acc, free_from} ->
          if s >= free_from, do: {[{i, s, s + n} | acc], s + n}, else: {acc, free_from}
        end)
        |> elem(0)
        |> Enum.reverse()
      end)
    end
  end

  # A query: a piece of the text itself (so there are matches), sometimes with its case changed,
  # or a fragment of its own.
  defp query(text) do
    graphemes = text |> String.split("\n") |> Enum.flat_map(&Text.graphemes/1)

    frequency([
      {3,
       gen all(
             at <- integer(0..max(length(graphemes) - 1, 0)),
             len <- integer(1..3),
             how <- member_of([:as_is, :up, :down])
           ) do
         q = graphemes |> Enum.slice(at, len) |> Enum.join() |> String.replace("\r", "")

         case how do
           :as_is -> q
           :up -> String.upcase(q)
           :down -> String.downcase(q)
         end
       end},
      {1, Gen.fragment(max_length: 3)}
    ])
  end

  property "the matches are the reference's: leftmost, non-overlapping, per line, smart case" do
    check all(
            text <- Gen.text(),
            q <- query(text)
          ) do
      assert Search.to_list(Search.matches(text, q)) == reference(text, q)
    end
  end

  property "each match is the query, folded when it has no capital, and on one line" do
    check all(
            text <- Gen.text(),
            q <- query(text)
          ) do
      lines = String.split(text, "\n")

      fold = fn s ->
        if Search.capital?(q),
          do: s,
          else: s |> Text.graphemes() |> Enum.map_join(&String.downcase/1)
      end

      for {l, s, e} <- Search.to_list(Search.matches(text, q)) do
        assert e - s == Text.length(q)
        assert fold.(Text.slice(Enum.at(lines, l), s, e - s)) == fold.(q)
      end
    end
  end

  property "Alt+N's next match, the count's index and the on-screen lines read the one set" do
    check all(
            text <- Gen.text(),
            q <- query(text),
            line <- integer(0..9),
            col <- integer(0..12),
            first <- integer(0..9),
            span <- integer(0..4)
          ) do
      packed = Search.matches(text, q)
      list = Search.to_list(packed)
      pos = {line, col}

      case Enum.find_index(list, fn {l, s, _} -> {l, s} >= pos end) do
        nil when list == [] -> assert Search.next_at(packed, pos) == nil
        nil -> assert Search.next_at(packed, pos) == {hd(list), 0, true}
        i -> assert Search.next_at(packed, pos) == {Enum.at(list, i), i, false}
      end

      for {m, i} <- Enum.with_index(list), do: assert(Search.index_of(packed, m) == i + 1)
      assert Search.count(packed) == length(list)

      assert Search.on_lines(packed, first, first + span) ==
               Enum.filter(list, fn {l, _, _} -> l >= first and l <= first + span end)

      # One screen row: the matches on `first` overlapping columns col..col+span.
      assert Search.on_line(packed, first, col, col + span) ==
               Enum.filter(list, fn {l, s, e} -> l == first and s < col + span and e > col end)

      # The first match found without counting them all is next_at's, wrapping alike.
      expected =
        case Search.next_at(packed, pos) do
          nil -> nil
          {m, _i, wrapped?} -> {m, wrapped?}
        end

      assert Search.first_from(text, q, pos) == expected
    end
  end

  describe "the cases" do
    test "\"aa\" in \"aaaa\" is at 0 and 2; a match never crosses a line end" do
      assert Search.line_matches("aaaa", "aa") == [{0, 2}, {2, 4}]
      # The same on the grapheme path (a non-ASCII line, or query), not only by bytes.
      assert Search.line_matches("éééé", "éé") == [{0, 2}, {2, 4}]
      assert Search.line_matches("aaaaé", "aa") == [{0, 2}, {2, 4}]
      assert Search.to_list(Search.matches("ab\nab", "b\na")) == []
    end

    test "an empty query matches nothing, and has no next match" do
      assert Search.matches("abc", "") == <<>>
      assert Search.next_at(Search.matches("abc", ""), {0, 0}) == nil
      assert Search.first_from("abc", "", {0, 0}) == nil
    end

    test "CRLF: the \\r is no part of a line's text, and columns are the line's" do
      text = "ab\r\ncab\r\n"
      assert Search.to_list(Search.matches(text, "ab")) == [{0, 0, 2}, {1, 1, 3}]
      assert Search.to_list(Search.matches(text, "b\r")) == []
    end

    test "smart case: ß, ǅ, the Kelvin sign, U+023A" do
      # Lowercase folds; uppercase isn't used, so ß never becomes SS.
      assert Search.line_matches("STRASSE straße", "straße") == [{8, 14}]
      assert Search.line_matches("Straße STRASSE", "STRASSE") == [{7, 14}]
      # A titlecase or Kelvin capital makes the search exact.
      assert Search.capital?("ǅ") and Search.capital?("K")
      assert Search.line_matches("ǆ ǅ", "ǅ") == [{2, 3}]
      assert Search.line_matches("k K", "k") == [{0, 1}, {2, 3}]
      # Ⱥ lowercases to ⱥ with more bytes; columns stay the original line's.
      assert Search.line_matches("xȺy Ⱥ", "ⱥ") == [{1, 2}, {4, 5}]
    end

    test "é precomposed and é decomposed don't match each other" do
      assert Search.line_matches("café", "café") == []
      assert Search.line_matches("café", "café") == []
    end

    test "bytes that aren't UTF-8 are one grapheme each and match only themselves" do
      line = "©" <> <<0xE9>> <> " caf" <> <<0xE9>>
      assert Search.line_matches(line, "©" <> <<0xE9>>) == [{0, 2}]
      assert Search.line_matches(line, <<0xE9>>) == [{1, 2}, {6, 7}]
      assert Search.line_matches(line, "café") == []
    end

    test "the positions Alt+N and the search as typed start from" do
      sel = {{0, 9}, {0, 4}}
      assert Search.after_position(sel, {0, 4}) == {0, 9}
      assert Search.start_position(sel, {0, 4}) == {0, 4}
      assert Search.after_position(nil, {2, 3}) == {2, 3}
    end
  end

  describe "what a search costs" do
    # The fastest of three; relative bounds, as CI's runner is slower than this machine.
    defp ms(fun), do: for(_ <- 1..3, do: elem(:timer.tc(fun), 0)) |> Enum.min() |> div(1000)

    test "an ASCII query in ASCII text goes by bytes, as fast as a grapheme walk or faster" do
      text = String.duplicate("the quick brown fox jumps over the lazy dog\n", 20_000)
      ascii = ms(fn -> Search.matches(text, "lazy") end)
      # The same text with one é per line takes the grapheme path.
      accented = String.replace(text, "brown", "brówn")
      graphemes = ms(fn -> Search.matches(accented, "lazy") end)
      assert Search.count(Search.matches(text, "lazy")) == 20_000
      assert ascii <= graphemes + 20
    end

    test "a screen row reads its own window of a line with a million matches" do
      packed = Search.matches(String.duplicate("a", 2_000_000), "aa")
      assert ms(fn -> Search.on_line(packed, 0, 1_000_001, 1_000_101) end) < 50
      assert length(Search.on_line(packed, 0, 1_000_001, 1_000_101)) == 51
    end

    test "a query holding a non-ASCII byte skips ASCII lines" do
      text = String.duplicate("the quick brown fox jumps over the lazy dog\n", 20_000)
      ascii = ms(fn -> Search.matches(text, "lazy") end)
      assert Search.count(Search.matches(text, "é")) == 0
      assert ms(fn -> Search.matches(text, "é") end) <= 3 * ascii + 50
    end

    test "a million matches pack into 12 MB, read by binary search" do
      packed = Search.matches(String.duplicate("a", 2_000_000), "aa")
      assert Search.count(packed) == 1_000_000 and byte_size(packed) == 12_000_000
      assert ms(fn -> Search.next_at(packed, {0, 1_234_567}) end) < 50
      assert Search.next_at(packed, {0, 1_234_567}) == {{0, 1_234_568, 1_234_570}, 617_284, false}
    end
  end
end
