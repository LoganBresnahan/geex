defmodule Geex.Loop.ScrollBar do
  @moduledoc """
  A file pane's two scroll bars ([ADR-0039](../../../doc/adr/0039-mouse.md) §7): where they are
  on screen, where the thumb sits, and what scroll a press or a drag on one asks for. Pure.
  `Geex.Loop` draws the thumbs with `thumb/3` and hit-tests a press with `layout/3` and `hit/2`.

  The vertical bar is the pane's last column, beside the text rows, shown when the text has more
  lines than rows. The horizontal bar is the pane's last row, under the text columns, shown when
  a line is wider than them. A pane's rows (ADR-0038): the tab bar, the text, then that last row.
  """

  alias Geex.Rect

  @enforce_keys [:axis, :x, :y, :len, :content, :offset]
  defstruct @enforce_keys

  @typedoc """
  One bar: `axis` `:v` (it scrolls lines) or `:h` (columns); its first cell `{x, y}` on screen;
  `len` cells long, the viewport; over `content` lines or columns, scrolled to `offset`.
  """
  @type t :: %__MODULE__{
          axis: :v | :h,
          x: non_neg_integer(),
          y: non_neg_integer(),
          len: pos_integer(),
          content: pos_integer(),
          offset: non_neg_integer()
        }

  @doc """
  The thumb as `{position, length}` along one axis: for a `viewport` of cells showing `content`
  cells, scrolled to `offset`. Its length is the visible fraction (at least one cell); its
  position is how far the scroll is.

      iex> Geex.Loop.ScrollBar.thumb(10, 20, 0)
      {0, 5}
      iex> Geex.Loop.ScrollBar.thumb(10, 20, 10)
      {5, 5}
  """
  @spec thumb(pos_integer(), pos_integer(), non_neg_integer()) ::
          {non_neg_integer(), pos_integer()}
  def thumb(viewport, content, offset) do
    len = max(div(viewport * viewport, content), 1)
    span = max(viewport - len, 0)
    pos = min(div(offset * span, max(content - viewport, 1)), span)
    {pos, len}
  end

  @doc """
  The bars a file pane at `rect` showing `text` scrolled to `{scroll, hscroll}` draws: none, one
  or both.

      iex> rect = %Geex.Rect{x: 10, y: 0, w: 20, h: 6}
      iex> text = Enum.map_join(1..9, "\\n", &"line \#{&1}")
      iex> [v] = Geex.Loop.ScrollBar.layout(text, rect, {2, 0})
      iex> {v.axis, v.x, v.y, v.len, v.content, v.offset}
      {:v, 29, 1, 4, 9, 2}
      iex> Geex.Loop.ScrollBar.layout("short", rect, {0, 0})
      []
  """
  @spec layout(String.t(), Rect.t(), {non_neg_integer(), non_neg_integer()}) :: [t()]
  def layout(text, %Rect{} = rect, {scroll, hscroll}) do
    lines = length(:binary.matches(text, "\n")) + 1
    rows = max(rect.h - 2, 0)
    vbar? = rows > 0 and lines > rows
    gw = Geex.Loop.gutter_width(text)
    cols = max(rect.w - if(vbar?, do: 1, else: 0) - gw, 0)
    widest = if cols > 0, do: Geex.Loop.max_line_width(text), else: 0

    v =
      if vbar?,
        do: %__MODULE__{
          axis: :v,
          x: rect.x + rect.w - 1,
          y: rect.y + 1,
          len: rows,
          content: lines,
          offset: scroll
        }

    h =
      if cols > 0 and rect.h >= 2 and widest > cols,
        do: %__MODULE__{
          axis: :h,
          x: rect.x + gw,
          y: rect.y + rect.h - 1,
          len: cols,
          content: widest,
          offset: hscroll
        }

    Enum.reject([v, h], &is_nil/1)
  end

  @doc """
  The bar under screen cell `{x, y}` and the cell along it (`0` at its top or left), or `nil`.

      iex> bar = %Geex.Loop.ScrollBar{axis: :v, x: 29, y: 1, len: 4, content: 9, offset: 0}
      iex> Geex.Loop.ScrollBar.hit([bar], {29, 3})
      {bar, 2}
      iex> Geex.Loop.ScrollBar.hit([bar], {28, 3})
      nil
  """
  @spec hit([t()], {integer(), integer()}) :: {t(), non_neg_integer()} | nil
  def hit(bars, {x, y}) do
    Enum.find_value(bars, fn
      %{axis: :v} = b -> x == b.x and y >= b.y and y < b.y + b.len and {b, y - b.y}
      %{axis: :h} = b -> y == b.y and x >= b.x and x < b.x + b.len and {b, x - b.x}
    end)
  end

  @doc """
  Where a press at `cell` holds the thumb: the cell within the thumb under the pointer while it is
  dragged. A press on the thumb keeps the point it took; a press on the track takes the thumb by
  its middle, so the thumb jumps to centre on the pointer.

      iex> bar = %Geex.Loop.ScrollBar{axis: :v, x: 0, y: 0, len: 10, content: 20, offset: 0}
      iex> Geex.Loop.ScrollBar.grab(bar, 3)
      3
      iex> Geex.Loop.ScrollBar.grab(bar, 8)
      2
  """
  @spec grab(t(), non_neg_integer()) :: non_neg_integer()
  def grab(%__MODULE__{} = bar, cell) do
    {pos, len} = thumb(bar.len, bar.content, bar.offset)
    if cell >= pos and cell < pos + len, do: cell - pos, else: div(len, 2)
  end

  @doc """
  The scroll that draws the thumb with its top at `top` (clamped to the bar): the least offset
  whose thumb is there, so dragging the thumb back and forth returns to the same scroll. From the
  top of the content to its end, as a page from the end shows it.

      iex> bar = %Geex.Loop.ScrollBar{axis: :v, x: 0, y: 0, len: 10, content: 20, offset: 0}
      iex> Enum.map([-3, 0, 1, 2, 5, 9], &Geex.Loop.ScrollBar.offset_at(bar, &1))
      [0, 0, 2, 4, 10, 10]
  """
  @spec offset_at(t(), integer()) :: non_neg_integer()
  def offset_at(%__MODULE__{len: len, content: content} = bar, top) do
    {_pos, thumb_len} = thumb(len, content, bar.offset)
    span = len - thumb_len
    most = max(content - len, 0)

    if span <= 0,
      do: 0,
      else: min(div((top |> max(0) |> min(span)) * most + span - 1, span), most)
  end
end
