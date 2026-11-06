defmodule Geex.Markdown.Place do
  @moduledoc """
  Keeping the reader's place in a markdown preview across a re-render
  ([ADR-0043](../../../doc/adr/0043-markdown-preview.md) §6). Pure.

  Each row names the source line it draws (`lines/2`, from the rows' `src` bytes; a blank row
  between blocks names none). Before a re-render the loop notes the top row's line and its offset
  among the consecutive rows sharing that line (`anchor/2`); afterwards it scrolls to the first
  row of that line, or of the nearest earlier line that has rows, plus the offset, clamped to
  that run (`scroll/2`). After the user's save the anchor is `{cursor line, 0}`.

  An anchor taken in one text is carried into the next by `remap/2` through `line_map/2`, a line
  diff the preview process computes on each re-read, so an edit above the reader (an agent
  writing an earlier section) leaves them on the same row. The save anchor is already a line in
  the new text and isn't remapped.

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

  @doc """
  Where each line of `old` went in `new`: a tuple indexed by old line, holding its new line, or
  `nil` for a line removed. The common prefix and suffix are matched directly and the middle by
  `List.myers_difference/2`.

      iex> Geex.Markdown.Place.line_map("a\\nb\\nc", "a\\nnew\\nb\\nc")
      {0, 2, 3}
  """
  @spec line_map(String.t(), String.t()) :: tuple()
  def line_map(old_text, new_text) do
    old = String.split(old_text, "\n")
    new = String.split(new_text, "\n")
    {prefix, old, new} = common_prefix(old, new, 0)
    {suffix, old_mid, new_mid} = common_suffix(old, new)

    {middle, _at} =
      old_mid
      |> List.myers_difference(new_mid)
      |> Enum.reduce({[], prefix}, fn
        {:eq, lines}, {acc, at} ->
          {Enum.reverse(Enum.to_list(at..(at + length(lines) - 1)//1), acc), at + length(lines)}

        {:del, lines}, {acc, at} ->
          {List.duplicate(nil, length(lines)) ++ acc, at}

        {:ins, lines}, {acc, at} ->
          {acc, at + length(lines)}
      end)

    tail_from = prefix + length(new_mid)

    (Enum.to_list(0..(prefix - 1)//1) ++
       Enum.reverse(middle) ++ Enum.to_list(tail_from..(tail_from + suffix - 1)//1))
    |> List.to_tuple()
  end

  defp common_prefix([x | old], [x | new], n), do: common_prefix(old, new, n + 1)
  defp common_prefix(old, new, n), do: {n, old, new}

  defp common_suffix(old, new) do
    {n, old_r, new_r} = common_prefix(Enum.reverse(old), Enum.reverse(new), 0)
    {n, Enum.reverse(old_r), Enum.reverse(new_r)}
  end

  @doc """
  `anchor` carried through a `line_map/2` (`nil`: the text didn't change). A removed line's
  anchor goes to the nearest earlier kept line, at its first row.
  """
  @spec remap(tuple() | nil, anchor()) :: anchor()
  def remap(nil, anchor), do: anchor

  def remap(map, {line, offset}) do
    if line < tuple_size(map) and elem(map, line) != nil do
      {elem(map, line), offset}
    else
      start = min(line, tuple_size(map)) - 1

      case Enum.find(start..0//-1, &(&1 >= 0 and elem(map, &1) != nil)) do
        nil -> {0, 0}
        i -> {elem(map, i), 0}
      end
    end
  end
end
