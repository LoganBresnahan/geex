defmodule Geex.Loop.TabBar do
  @moduledoc """
  Where things are on a file pane's tab bar ([ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md)
  §5, [ADR-0039](../../../doc/adr/0039-mouse.md)): each tab's label and its `×`, and the pane's
  own `×` at the right end. Pure, so drawing and a click read the same layout.

  A tab reads ` N name × `: its number (`Alt+1` … `Alt+9`), its file name (with ` [+]` for unsaved edits),
  and a `×` that closes it. When the pane can close (it isn't the only one), the bar's last three
  columns are ` × `, which closes the pane. When the bar is the top of a stacked split's lower
  half, it keeps two columns for the split's handle (`handle(:rows)`), just before the pane's `×` ([ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md)
  §6), so the split can be dragged however many tabs there are.

  Tabs that don't fit are hidden whole, and a mark at each end counts them: `‹2` at the left,
  `3›` at the right (roadmap item 18.5). The bar follows the shown tab: it starts at the first
  tab that keeps the shown one visible. Scrolled (the wheel, a click on a mark), it starts at the
  `first` tab it is given instead, and the shown tab may be out of view; the loop drops the
  scroll when the shown tab changes. A tab too wide for the bar on its own is cut.

  A markdown file's tabs carry the preview's glyph between the name and the `×`, so the `×`
  keeps the label's last two columns: ` N name ◫ × ` ([ADR-0043](../../../doc/adr/0043-markdown-preview.md)
  §1). It is part of the label, drawn in the tab's colours as the `×` is; a click on it toggles
  the preview. A preview's own tab has none: its `×` closes it.
  """

  alias Geex.Width

  @pane_close " × "

  # The preview's glyph (ADR-0043 §1): U+25EB, East Asian Width Neutral (one column in any font;
  # `¶` is Ambiguous), in DejaVu Sans Mono (and so Menlo), JetBrains Mono, FreeMono, and Cascadia
  # Mono and Code (Windows Terminal's defaults); not in Consolas. Swap it here.
  @preview_glyph "◫"

  # The handles' glyphs (ADR-0038 §6): one per direction an edge moves, the same grip turned, 4
  # dots along the edge and 2 across. Each braille cell is one column in any font (not East
  # Asian ambiguous width). Swap them here.
  @handle_cols "⣿"
  @handle_rows "⠛⠛"

  @type glyph :: non_neg_integer() | nil
  @type mark :: %{x: non_neg_integer(), w: pos_integer(), text: String.t()} | nil
  @type t :: %{
          tabs: [
            %{i: non_neg_integer(), x: non_neg_integer(), label: String.t(), glyph: glyph()}
          ],
          close: non_neg_integer() | nil,
          handle: non_neg_integer() | nil,
          w: non_neg_integer(),
          first: non_neg_integer(),
          left: mark(),
          right: mark()
        }

  @doc """
  The bar for tabs named `names`, tab `at` shown, `w` columns wide; `closable?` when the pane
  has its own `×`; `handle?` when it keeps a split's handle; `first`, the tab a scrolled bar
  starts at (`nil` follows the shown tab). Each tab's `x` is from the bar's left edge. A name
  given as `{name, :glyph}` carries the preview's glyph, and its tab's `glyph` is the glyph's
  column. `first` in the answer is the tab the bar starts at, and `left` and `right` the marks
  counting the hidden tabs (`nil` when none are hidden on that side).

      iex> bar = Geex.Loop.TabBar.layout(["a.txt", "b.txt [+]"], 0, 40, true)
      iex> Enum.map(bar.tabs, &{&1.i, &1.x, &1.label})
      [{0, 0, " 1 a.txt × "}, {1, 11, " 2 b.txt [+] × "}]
      iex> Geex.Loop.TabBar.layout([{"a.md", :glyph}], 0, 40, false).tabs
      [%{i: 0, x: 0, label: " 1 a.md ◫ × ", glyph: 8}]
      iex> {bar.close, bar.handle}
      {37, nil}
      iex> Geex.Loop.TabBar.layout(["a.txt"], 0, 40, true, true).handle
      35

  Five tabs of 11 columns in 30: the bar follows tab 3, so tabs 0 and 1 are hidden at the left,
  and tab 4 at the right; scrolled to start at 0, tab 3 is out of view.

      iex> names = ~w(a.txt b.txt c.txt d.txt e.txt)
      iex> bar = Geex.Loop.TabBar.layout(names, 3, 30, false)
      iex> {bar.first, Enum.map(bar.tabs, & &1.i), bar.left, bar.right}
      {2, [2, 3], %{x: 0, w: 2, text: "‹2"}, %{x: 28, w: 2, text: "1›"}}
      iex> bar = Geex.Loop.TabBar.layout(names, 3, 30, false, false, 0)
      iex> {bar.first, Enum.map(bar.tabs, & &1.i), bar.left, bar.right}
      {0, [0, 1], nil, %{x: 28, w: 2, text: "3›"}}
  """
  @spec layout(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          boolean(),
          non_neg_integer() | nil
        ) :: t()
  def layout(names, at, w, closable?, handle? \\ false, first \\ nil) do
    room = if closable?, do: max(w - Width.string(@pane_close), 0), else: w
    handle = if handle? and room >= 2, do: room - 2
    room = if handle, do: handle, else: room

    labels =
      names
      |> Enum.with_index()
      |> Enum.map(fn
        {{name, :glyph}, i} -> {i, " #{i + 1} " <> name <> " #{@preview_glyph} × ", true}
        {name, i} -> {i, " #{i + 1} " <> name <> " × ", false}
      end)

    widths = Enum.map(labels, &Width.string(elem(&1, 1)))
    # A mark's columns: the arrow and the most digits a count can have here. A bar too narrow
    # for both marks and a column of tab between them has none.
    mark_w = 1 + length(Integer.digits(max(length(labels), 1)))
    marks? = room > 2 * mark_w
    mark_w = if marks?, do: mark_w, else: 0
    first = first_shown(widths, at, room, mark_w, first)
    {count, left_w, right?} = place(widths, first, room, mark_w)
    right? = right? and marks?

    {tabs, _x} =
      labels
      |> Enum.slice(first, count)
      |> Enum.map_reduce(left_w, fn {i, label, glyph?}, x ->
        lw = Width.string(label)
        glyph = if glyph?, do: x + lw - 4
        {%{i: i, x: x, label: label, glyph: glyph}, x + lw}
      end)

    hidden_right = length(labels) - first - count

    %{
      tabs: tabs,
      close: if(closable? and w >= Width.string(@pane_close), do: w - 3),
      handle: handle,
      # The labels' room: up to the right mark, when there is one.
      w: if(right?, do: room - mark_w, else: room),
      first: first,
      left:
        if(first > 0 and marks?,
          do: %{x: 0, w: mark_w, text: String.pad_trailing("‹#{first}", mark_w)}
        ),
      right:
        if(right?,
          do: %{x: room - mark_w, w: mark_w, text: String.pad_leading("#{hidden_right}›", mark_w)}
        )
    }
  end

  # The tab the bar starts at. Following tab `at`: the first start that keeps it in view. Scrolled:
  # the start asked for, kept between the first tab and the last start that still reaches the
  # last tab (scrolling further would only hide tabs).
  defp first_shown([], _at, _room, _mark_w, _first), do: 0

  defp first_shown(widths, at, room, mark_w, nil) do
    Enum.find(0..at//1, at, fn f ->
      {count, _, _} = place(widths, f, room, mark_w)
      f + count > at
    end)
  end

  defp first_shown(widths, _at, room, mark_w, first) do
    last = length(widths) - 1

    reaches_end =
      Enum.find(0..last//1, last, fn f ->
        {count, _, _} = place(widths, f, room, mark_w)
        f + count > last
      end)

    first |> max(0) |> min(reaches_end)
  end

  # How many tabs from `first` fit, the left mark's columns, and whether a right mark is needed.
  # Room is kept for the right mark only when some tabs are left over; at least one tab is
  # placed, cut when it is too wide on its own, and then there is no right mark unless tabs
  # follow it.
  defp place(widths, first, room, mark_w) do
    left_w = if first > 0, do: mark_w, else: 0
    rest = Enum.drop(widths, first)
    all = fitting(rest, room - left_w)

    if all == length(rest) do
      {all, left_w, false}
    else
      count = max(fitting(rest, room - left_w - mark_w), 1)
      {count, left_w, count < length(rest)}
    end
  end

  # How many of `widths`, in order, fit in `room` columns.
  defp fitting(widths, room) do
    widths
    |> Enum.reduce_while({0, 0}, fn w, {n, used} ->
      if used + w <= room, do: {:cont, {n + 1, used + w}}, else: {:halt, {n, used}}
    end)
    |> elem(0)
  end

  @doc """
  What the bar's column `x` is: a tab, a tab's `×`, the pane's `×`, the split's handle (and the
  space after it), a mark (scroll the bar a tab that way), or nothing.
  """
  @spec hit(t(), integer()) ::
          {:tab, non_neg_integer()}
          | {:close_tab, non_neg_integer()}
          | {:toggle_preview, non_neg_integer()}
          | :close_pane
          | :handle
          | {:scroll, -1 | 1}
          | nil
  def hit(%{close: close}, x) when is_integer(close) and x >= close, do: :close_pane
  def hit(%{handle: h}, x) when is_integer(h) and x in h..(h + 1)//1, do: :handle

  def hit(%{left: %{x: lx, w: mw}}, x) when x >= lx and x < lx + mw, do: {:scroll, -1}
  def hit(%{right: %{x: rx, w: mw}}, x) when x >= rx and x < rx + mw, do: {:scroll, 1}

  def hit(%{tabs: tabs, w: room}, x) when x < room do
    Enum.find_value(tabs, fn %{i: i, x: tx, label: label} = tab ->
      lw = Width.string(label)

      cond do
        x < tx or x >= tx + lw -> nil
        # The `×` and the space after it.
        x >= tx + lw - 2 -> {:close_tab, i}
        # The preview's glyph and the space after it.
        tab.glyph != nil and x >= tab.glyph -> {:toggle_preview, i}
        true -> {:tab, i}
      end
    end)
  end

  def hit(_bar, _x), do: nil

  @doc """
  A handle's glyph, by the way its edge moves: `:cols` for an edge dragged left and right (a
  side-by-side divider, the tree's edge), `:rows` for one dragged up and down (a stacked split's
  bar, the edits pane's title). The `:rows` glyph is two columns: the handle and the space after
  it, the hit area a bar keeps.

      iex> {Geex.Loop.TabBar.handle(:cols), Geex.Loop.TabBar.handle(:rows)}
      {"⣿", "⠛⠛"}
  """
  @spec handle(:cols | :rows) :: String.t()
  def handle(:cols), do: @handle_cols
  def handle(:rows), do: @handle_rows

  @doc "The markdown preview's glyph."
  @spec preview_glyph() :: String.t()
  def preview_glyph, do: @preview_glyph

  @doc "The pane's `×`, as drawn in the bar's last three columns."
  @spec pane_close() :: String.t()
  def pane_close, do: @pane_close
end
