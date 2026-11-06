defmodule Geex.Markdown.Place do
  @moduledoc """
  Keeping the reader's place in a markdown preview across a re-render
  ([ADR-0043](../../../doc/adr/0043-markdown-preview.md) §6). Pure.

  Each row names the source line it draws (`lines/2`, from the rows' `src` bytes; a blank row
  between blocks names none). Before a re-render the loop notes the top row's line and its offset
  among the consecutive rows sharing that line (`anchor/2`); afterwards it scrolls to the first
  row of that line, or of the nearest earlier line that has rows, plus the offset, clamped to
  that run (`scroll/2`). After the user's save the anchor is `{cursor line, 0}`.

  Lines are 0-based, as the buffer's cursor is. They are counted in each render's own text, so
  a CRLF file and its LF twin name the same lines.
  """

  @type lines :: tuple()
  @type anchor :: {non_neg_integer(), non_neg_integer()}

  @doc """
  The 0-based source line each row draws, as a tuple indexed by row (`nil` for a blank row).
  """
  @spec lines([map()], String.t()) :: lines()
  def lines(rows, text) do
    newlines = text |> :binary.matches("\n") |> Enum.map(&elem(&1, 0)) |> List.to_tuple()

    rows
    |> Enum.map(fn
      %{blank: true} -> nil
      %{src: src} -> count_below(newlines, src, 0, tuple_size(newlines))
    end)
    |> List.to_tuple()
  end

  # How many newlines sit before byte `at`: its 0-based line.
  defp count_below(_offsets, _at, lo, hi) when lo >= hi, do: lo

  defp count_below(offsets, at, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(offsets, mid) < at,
      do: count_below(offsets, at, mid + 1, hi),
      else: count_below(offsets, at, lo, mid)
  end

  @doc """
  Where the row at index `scroll` is: `{line, offset}`. A blank top row counts as the row after
  it (or before it, at the end).

      iex> Geex.Markdown.Place.anchor({0, 0, nil, 3, 3, 3}, 5)
      {3, 2}
      iex> Geex.Markdown.Place.anchor({0, nil, 3}, 1)
      {3, 0}
      iex> Geex.Markdown.Place.anchor({}, 0)
      {0, 0}
  """
  @spec anchor(lines(), non_neg_integer()) :: anchor()
  def anchor(lines, scroll) do
    n = tuple_size(lines)
    scroll = min(scroll, max(n - 1, 0))

    case Enum.find(scroll..(n - 1)//1, &elem(lines, &1)) ||
           Enum.find(scroll..0//-1, fn i -> i < n and elem(lines, i) end) do
      nil ->
        {0, 0}

      i ->
        line = elem(lines, i)
        start = run_start(lines, i, line)
        {line, if(i == scroll, do: i - start, else: 0)}
    end
  end

  defp run_start(lines, i, line) do
    if i > 0 and elem(lines, i - 1) == line, do: run_start(lines, i - 1, line), else: i
  end

  @doc """
  The row index to scroll to for `anchor`: the first row of its line (or of the nearest earlier
  line with rows), plus the offset, clamped to that line's run of rows.

      iex> Geex.Markdown.Place.scroll({0, 0, nil, 3, 3, 3}, {3, 1})
      4
      iex> Geex.Markdown.Place.scroll({0, 0, nil, 3, 3, 3}, {3, 9})
      5
      iex> Geex.Markdown.Place.scroll({0, 0, nil, 3, 3, 3}, {2, 1})
      1
  """
  @spec scroll(lines(), anchor()) :: non_neg_integer()
  def scroll(lines, {line, offset}) do
    list = Tuple.to_list(lines)

    target =
      list
      |> Enum.filter(&(is_integer(&1) and &1 <= line))
      |> Enum.max(fn -> nil end)

    case target && Enum.find_index(list, &(&1 == target)) do
      nil ->
        0

      first ->
        run = list |> Enum.drop(first) |> Enum.take_while(&(&1 == target)) |> length()
        first + min(offset, run - 1)
    end
  end
end
