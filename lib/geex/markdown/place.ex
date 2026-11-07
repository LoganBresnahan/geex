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
  `nil` for a line removed (or one this map couldn't place).

  Bounded, so a wholesale rewrite of a big file can't stall a render: the common prefix and
  suffix match directly; a small middle (200 lines both sides together) goes through
  `List.myers_difference/2`, which is O(N·D); a larger one is matched on the lines that occur
  once on each side, in their longest common order (patience diff, O(n log n)), and each gap
  between those matches is done again the same way. Lines left unmatched are `nil`, so
  `remap/2` lands on the nearest earlier kept line.

      iex> Geex.Markdown.Place.line_map("a\\nb\\nc", "a\\nnew\\nb\\nc")
      {0, 2, 3}
  """
  @spec line_map(String.t(), String.t()) :: tuple()
  def line_map(old_text, new_text) do
    old = old_text |> String.split("\n") |> List.to_tuple()
    new = new_text |> String.split("\n") |> List.to_tuple()
    pairs = match(old, 0, tuple_size(old), new, 0, tuple_size(new), [])
    map = Map.new(pairs)
    List.to_tuple(for i <- 0..(tuple_size(old) - 1)//1, do: Map.get(map, i))
  end

  @myers_max 200

  # The matched `{old, new}` line pairs of old[os, oe) and new[ns, ne), prepended to `acc`.
  defp match(old, os, oe, new, ns, ne, acc) do
    # The common prefix and suffix.
    {os, ns, acc} = prefix(old, os, oe, new, ns, ne, acc)
    {oe, ne, acc} = suffix(old, os, oe, new, ns, ne, acc)

    cond do
      os >= oe or ns >= ne -> acc
      oe - os + (ne - ns) <= @myers_max -> myers(old, os, oe, new, ns, ne, acc)
      true -> patience(old, os, oe, new, ns, ne, acc)
    end
  end

  defp prefix(old, os, oe, new, ns, ne, acc) do
    if os < oe and ns < ne and elem(old, os) == elem(new, ns),
      do: prefix(old, os + 1, oe, new, ns + 1, ne, [{os, ns} | acc]),
      else: {os, ns, acc}
  end

  defp suffix(old, os, oe, new, ns, ne, acc) do
    if oe > os and ne > ns and elem(old, oe - 1) == elem(new, ne - 1),
      do: suffix(old, os, oe - 1, new, ns, ne - 1, [{oe - 1, ne - 1} | acc]),
      else: {oe, ne, acc}
  end

  defp myers(old, os, oe, new, ns, ne, acc) do
    a = for i <- os..(oe - 1)//1, do: elem(old, i)
    b = for i <- ns..(ne - 1)//1, do: elem(new, i)

    {acc, _o, _n} =
      a
      |> List.myers_difference(b)
      |> Enum.reduce({acc, os, ns}, fn
        {:eq, lines}, {acc, o, n} ->
          k = length(lines)
          {Enum.reduce(0..(k - 1)//1, acc, &[{o + &1, n + &1} | &2]), o + k, n + k}

        {:del, lines}, {acc, o, n} ->
          {acc, o + length(lines), n}

        {:ins, lines}, {acc, o, n} ->
          {acc, o, n + length(lines)}
      end)

    acc
  end

  # Lines that occur exactly once in each range, matched; the longest run of them in the same
  # order on both sides anchors the ranges, and each gap between anchors is matched again.
  defp patience(old, os, oe, new, ns, ne, acc) do
    in_old = once(old, os, oe)
    in_new = once(new, ns, ne)

    anchors =
      in_old
      |> Enum.flat_map(fn {line, o} ->
        case in_new do
          %{^line => n} -> [{o, n}]
          _ -> []
        end
      end)
      |> Enum.sort()
      |> longest_increasing()

    if anchors == [] do
      # Nothing to anchor on: leave the middle unmatched.
      acc
    else
      {acc, o, n} =
        Enum.reduce(anchors, {acc, os, ns}, fn {ao, an}, {acc, o, n} ->
          acc = match(old, o, ao, new, n, an, acc)
          {[{ao, an} | acc], ao + 1, an + 1}
        end)

      match(old, o, oe, new, n, ne, acc)
    end
  end

  # `line => index` for the lines occurring once in t[s, e).
  defp once(t, s, e) do
    {seen, dup} =
      Enum.reduce(s..(e - 1)//1, {%{}, MapSet.new()}, fn i, {seen, dup} ->
        line = elem(t, i)

        if Map.has_key?(seen, line),
          do: {seen, MapSet.put(dup, line)},
          else: {Map.put(seen, line, i), dup}
      end)

    Map.drop(seen, MapSet.to_list(dup))
  end

  # The longest subsequence of `pairs` (sorted by old index) whose new indexes increase:
  # patience sorting, O(n log n).
  defp longest_increasing([]), do: []

  defp longest_increasing(pairs) do
    t = List.to_tuple(pairs)

    {tails, len, prev} =
      Enum.reduce(0..(tuple_size(t) - 1), {:array.new(), 0, %{}}, fn i, {tails, len, prev} ->
        {_o, n} = elem(t, i)
        pos = first_not_below(tails, t, n, 0, len)
        prev = if pos > 0, do: Map.put(prev, i, :array.get(pos - 1, tails)), else: prev
        {:array.set(pos, i, tails), max(len, pos + 1), prev}
      end)

    last = :array.get(len - 1, tails)

    Stream.unfold(last, fn
      nil -> nil
      i -> {elem(t, i), Map.get(prev, i)}
    end)
    |> Enum.reverse()
  end

  # The first pile whose top's new index is >= n (binary search over piles [lo, hi)).
  defp first_not_below(_tails, _t, _n, lo, hi) when lo >= hi, do: lo

  defp first_not_below(tails, t, n, lo, hi) do
    mid = div(lo + hi, 2)
    {_o, top} = elem(t, :array.get(mid, tails))

    if top < n,
      do: first_not_below(tails, t, n, mid + 1, hi),
      else: first_not_below(tails, t, n, lo, mid)
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
