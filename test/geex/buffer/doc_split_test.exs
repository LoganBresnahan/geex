defmodule Geex.Buffer.DocSplitTest do
  # BUG-13: `Geex.Buffer.Doc` cuts a line at a column by its bytes when the line is ASCII up to
  # there, and with `String.split_at/2` otherwise, never splitting the whole line into graphemes.
  # Held here to the grapheme lists it used before, on lines where an ASCII run meets a
  # combining mark at the column, and on long ones.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.Buffer.Doc
  alias Geex.Gen

  defp row do
    gen all(
          head <- string(:ascii, max_length: 20),
          pieces <- list_of(Gen.piece(), max_length: 8),
          mark <- member_of(["", "́", " ́", "👍🏽", "\r"]),
          times <- frequency([{4, constant(1)}, {1, integer(50..400)}])
        ) do
      String.duplicate(head <> Enum.join(pieces) <> mark, times)
    end
  end

  # The operations as they were, on grapheme lists.
  defp ref_insert(line, col, text) do
    gs = String.graphemes(line)

    if col >= 0 and col <= length(gs) do
      {pre, post} = Enum.split(gs, col)
      {:ok, Enum.join(pre) <> text <> Enum.join(post)}
    else
      {:error, :col_out_of_range}
    end
  end

  defp ref_delete(line, col, count) do
    gs = String.graphemes(line)

    if col >= 0 and col <= length(gs) do
      {pre, rest} = Enum.split(gs, col)
      {:ok, Enum.join(pre ++ Enum.drop(rest, count))}
    else
      {:error, :col_out_of_range}
    end
  end

  defp ref_slice(line, c1, c2) do
    gs = String.graphemes(line)

    if c1 >= 0 and c2 <= length(gs) and c1 <= c2,
      do: {:ok, gs |> Enum.slice(c1, c2 - c1) |> Enum.join()},
      else: {:error, :col_out_of_range}
  end

  property "insert, delete, replace, slice and byte_offset cut a line where the graphemes do" do
    check all(
            line <- row(),
            len = String.length(line),
            col <- integer(-1..(len + 2)),
            col2 <- integer(0..(len + 2)),
            count <- integer(0..5),
            text <- member_of(["", "x", "́", "é", "a\nb"])
          ) do
      doc = Doc.new("top\n" <> line <> "\nend")

      got = with {:ok, d} <- Doc.insert(doc, {1, col}, text), do: {:ok, Doc.text(d)}
      want = with {:ok, l} <- ref_insert(line, col, text), do: {:ok, "top\n" <> l <> "\nend"}
      assert got == want

      got = with {:ok, d} <- Doc.delete(doc, {1, col}, count), do: {:ok, Doc.text(d)}
      want = with {:ok, l} <- ref_delete(line, col, count), do: {:ok, "top\n" <> l <> "\nend"}
      assert (col < 0 and match?({:error, _}, got)) or got == want

      {c1, c2} = {min(col, col2), max(col, col2)}

      if c1 >= 0 do
        assert Doc.slice(doc, {{1, c1}, {1, c2}}) == ref_slice(line, c1, c2)

        got = with {:ok, d} <- Doc.replace(doc, {{1, c1}, {1, c2}}, text), do: {:ok, Doc.text(d)}

        want =
          with {:ok, kept} <- ref_slice(line, 0, c1),
               {:ok, _} <- ref_slice(line, c1, c2) do
            {:ok,
             "top\n" <>
               kept <>
               text <> (line |> String.graphemes() |> Enum.drop(c2) |> Enum.join()) <> "\nend"}
          end

        assert got == want

        prefix = line |> String.graphemes() |> Enum.take(c1) |> Enum.join()
        assert Doc.byte_offset(doc, {1, c1}) == 4 + byte_size(prefix)
      end
    end
  end

  test "a long ASCII line is cut by its bytes: an insert near its end is fast" do
    line = String.duplicate("ab, cd ", 300_000)
    doc = Doc.new(line)
    col = byte_size(line) - 10

    ms =
      for(_ <- 1..3, do: elem(:timer.tc(fn -> {:ok, _} = Doc.insert(doc, {0, col}, "x") end), 0))
      |> Enum.min()
      |> div(1000)

    assert ms < 20, "#{ms} ms"
  end
end
