defmodule Geex.Loop.Mouse do
  @moduledoc """
  Where a mouse event lands in a file pane ([ADR-0039](../../../doc/adr/0039-mouse.md)). Pure:
  the pane's rectangle, its text and its scroll in, a caret out. `Geex.Loop` does the rest.

  A file pane's rows (ADR-0038): the tab bar, the text, then the horizontal scroll bar. Its
  columns: the line-number gutter, then the text. A screen column turns into a grapheme through
  the same width walk the drawing uses (`Geex.Width.col_at_display/2`), so a wide character's
  two columns both land on it, a zero-width one is never landed on, and a click past a line's
  end lands at its end. Width never addresses (ADR-0027): the caret is in graphemes.
  """

  alias Geex.{Rect, Width}

  # Two presses closer than this, on the same cell, are a double-click.
  @double_ms 400

  @type pos :: {non_neg_integer(), non_neg_integer()}

  @doc """
  The caret at screen cell `{x, y}` in a file pane at `rect` showing `text` scrolled to
  `{scroll, hscroll}`, and which way the pointer is at or past the text's edge: `{dx, dy}`, each
  `-1` (on the gutter or left of it, or above the text), `0`, or `1` (on the text's last column
  or past it, or below the text). A point outside the text lands on the nearest caret inside it.

      iex> rect = %Geex.Rect{x: 10, y: 0, w: 30, h: 10}
      iex> text = "one\\n字字x\\nthree"
      iex> # the gutter is 4 columns, so the text starts at x 14, on row 1 (under the tab bar)
      iex> Geex.Loop.Mouse.text_pos(text, rect, {0, 0}, {16, 2})
      {{1, 1}, {0, 0}}
      iex> Geex.Loop.Mouse.text_pos(text, rect, {0, 0}, {17, 2})
      {{1, 1}, {0, 0}}
      iex> Geex.Loop.Mouse.text_pos(text, rect, {0, 0}, {35, 1})
      {{0, 3}, {0, 0}}
      iex> Geex.Loop.Mouse.text_pos(text, rect, {0, 0}, {12, 0})
      {{0, 0}, {-1, -1}}
  """
  @spec text_pos(
          String.t(),
          Rect.t(),
          {non_neg_integer(), non_neg_integer()},
          {integer(), integer()}
        ) ::
          {pos(), {-1 | 0 | 1, -1 | 0 | 1}}
  def text_pos(text, %Rect{} = rect, {scroll, hscroll}, {x, y}) do
    lines = String.split(text, "\n")
    gw = gutter_width(length(lines))
    # The text rows: under the tab bar, above the scroll-bar row. The text columns: after the
    # gutter, before the vertical scroll bar when the text overflows the rows.
    rows = max(rect.h - 2, 1)
    cols = max(rect.w - gw - if(length(lines) > rows, do: 1, else: 0), 1)
    row = y - rect.y - 1
    col = x - rect.x - gw

    dy = if(row < 0, do: -1, else: if(row >= rows, do: 1, else: 0))
    # The last text column counts as the right edge: a pane against the terminal's right edge
    # gives the pointer nowhere further to go.
    dx = if(col < 0, do: -1, else: if(col >= cols - 1, do: 1, else: 0))
    col = min(col, cols - 1)

    line = scroll + (row |> max(0) |> min(rows - 1))

    if line >= length(lines) do
      last = length(lines) - 1
      {{last, String.length(List.last(lines))}, {dx, dy}}
    else
      text_line = Enum.at(lines, line)
      g = Width.col_at_display(text_line, max(col, 0) + hscroll + 1) - 1
      {{line, min(g, String.length(text_line))}, {dx, dy}}
    end
  end

  # `Geex.Loop.gutter_width/1` from a line count: the digits (at least two) and a margin each side.
  defp gutter_width(n), do: max(String.length(Integer.to_string(n)), 2) + 2

  @doc """
  The word at caret `col` of `line`, as `{from, to}` grapheme columns (half-open): the run of
  word characters (letters, digits, `_`), spaces, or other characters the caret's grapheme
  belongs to. At a line's end, the grapheme before it. An empty line gives `{0, 0}`.

      iex> Geex.Loop.Mouse.word_at("def foo_bar(x)", 6)
      {4, 11}
      iex> Geex.Loop.Mouse.word_at("def foo_bar(x)", 3)
      {3, 4}
      iex> Geex.Loop.Mouse.word_at("a 字字 b", 3)
      {2, 4}
  """
  @spec word_at(String.t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def word_at(line, col) do
    gs = line |> String.graphemes() |> List.to_tuple()
    n = tuple_size(gs)

    if n == 0 do
      {0, 0}
    else
      i = min(col, n - 1)
      kind = kind(elem(gs, i))
      from = Enum.find(i..0//-1, 0, &(&1 == 0 or kind(elem(gs, &1 - 1)) != kind))
      to = Enum.find(i..(n - 1)//1, n - 1, &(&1 == n - 1 or kind(elem(gs, &1 + 1)) != kind))
      {from, to + 1}
    end
  end

  defp kind(g) do
    cond do
      g in [" ", "\t"] -> :space
      String.valid?(g) and g =~ ~r/^[\p{L}\p{N}_]/u -> :word
      true -> :other
    end
  end

  @doc """
  Whether a press at `{x, y}` at time `now` (milliseconds) is the second of a double-click,
  given the last press (`{time, x, y}`, or `nil`).

      iex> Geex.Loop.Mouse.double?({1000, 5, 5}, 1300, {5, 5})
      true
      iex> Geex.Loop.Mouse.double?({1000, 5, 5}, 1500, {5, 5})
      false
      iex> Geex.Loop.Mouse.double?({1000, 5, 5}, 1100, {6, 5})
      false
  """
  @spec double?({integer(), integer(), integer()} | nil, integer(), {integer(), integer()}) ::
          boolean()
  def double?({t, x, y}, now, {x, y}), do: now - t <= @double_ms
  def double?(_last, _now, _at), do: false
end
