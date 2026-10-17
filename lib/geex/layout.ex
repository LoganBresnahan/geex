defmodule Geex.Layout do
  @moduledoc """
  Where each pane goes on the screen ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md)
  §4). Pure: the terminal size and which panels are shown in, `Geex.Rect`s out.

  A fixed shape, not a general split tree: the file tree in a column on the left, the editor on
  the right, the edits pane in a band under the editor (a title row and up to 8 rows), and the
  status line across the bottom row. The editor's rectangle includes its horizontal scroll-bar
  row; the tree's includes its divider column on the right. `split/2` then divides the editor's
  rectangle among the file panes ([ADR-0038](../../doc/adr/0038-split-panes-and-tabs.md)).

      iex> l = Geex.Layout.resolve(80, 24, %{edits: true, tree: false})
      iex> {l.editor.h, l.edits.y, l.edits.h, l.status, l.tree}
      {15, 15, 8, 23, nil}

      iex> l = Geex.Layout.resolve(120, 30, %{edits: true, tree: true})
      iex> {l.tree.w, l.editor.x, l.editor.w, l.edits.x}
      {30, 30, 90, 30}
  """

  alias Geex.Rect

  # Below this many rows, a shown edits pane would leave the editor too little room.
  @min_h 12
  # The list's rows, plus its title row.
  @rows 8
  # Below this many columns, a shown tree would leave the editor too little room.
  @min_w 60
  # The narrowest a dragged tree gets.
  @least_tree 12

  @type t :: %{
          editor: Rect.t(),
          edits: Rect.t() | nil,
          tree: Rect.t() | nil,
          status: non_neg_integer()
        }

  @doc """
  The rectangles for a `w` × `h` terminal. `shown`: whether the edits pane and the tree are
  shown (a missing key means not). The tree takes a quarter of the width, 20 to 36 columns, or
  `shown[:tree_w]` columns when one was dragged ([ADR-0039](../../doc/adr/0039-mouse.md) step 3),
  leaving the editor at least 40, or what the file panes need (`shown[:least]`, `least/1`). The
  edits pane takes up to 9 rows, a third of the height, or `shown[:edits_h]`, leaving the editor
  at least 6 rows, or what the panes need.

      iex> l = Geex.Layout.resolve(120, 30, %{edits: true, tree: true, tree_w: 50, edits_h: 4})
      iex> {l.tree.w, l.editor.w, l.edits.h, l.editor.h}
      {50, 70, 4, 25}
      iex> l = Geex.Layout.resolve(120, 30, %{edits: true, tree: true, tree_w: 200, edits_h: 99})
      iex> {l.tree.w, l.edits.h}
      {80, 23}
  """
  @spec resolve(non_neg_integer(), non_neg_integer(), map()) :: t()
  def resolve(w, h, shown) do
    {least_w, least_h} = shown[:least] || {0, 0}

    tree_w =
      cond do
        !(shown[:tree] && w >= @min_w) -> 0
        tw = shown[:tree_w] -> tw |> min(w - max(40, least_w)) |> max(@least_tree)
        true -> w |> div(4) |> max(20) |> min(36)
      end

    edits_h =
      cond do
        !(shown[:edits] && h >= @min_h) -> 0
        eh = shown[:edits_h] -> eh |> min(h - 1 - max(6, least_h)) |> max(2)
        true -> min(@rows + 1, div(h, 3))
      end

    editor_w = w - tree_w
    editor_h = max(h - 1 - edits_h, 0)

    %{
      editor: %Rect{x: tree_w, y: 0, w: editor_w, h: editor_h},
      edits: if(edits_h > 0, do: %Rect{x: tree_w, y: editor_h, w: editor_w, h: edits_h}),
      tree: if(tree_w > 0, do: %Rect{x: 0, y: 0, w: tree_w, h: max(h - 1, 0)}),
      status: max(h - 1, 0)
    }
  end

  @typedoc """
  How the editor's rectangle is split into file panes (ADR-0038): a pane, or two halves of a
  split, `:rows` stacked top and bottom, `:cols` side by side, the first half taking `ratio` of
  the room (0.5 is even; ADR-0038's 2026-10-17 amendment).
  """
  @type split :: {:pane, term()} | {:rows | :cols, split(), split(), float()}

  # The smallest a file pane is kept: a tab bar, two text rows and the scroll-bar row; a gutter
  # and a few columns of text. `Geex.Loop` refuses a split that would make a smaller one.
  @min_pane_w 12
  @min_pane_h 4

  @doc "The smallest file pane, `{w, h}`: what a split's halves are kept to when there's room."
  @spec min_pane() :: {pos_integer(), pos_integer()}
  def min_pane, do: {@min_pane_w, @min_pane_h}

  @doc """
  Each file pane's rectangle within `rect`, in reading order (left to right, top to bottom). A
  split gives its first half `ratio` of its rectangle; a `:cols` split keeps one column between
  the halves for a divider (`dividers/2`). Each half is kept at least as big as the panes in it
  need (`min_pane/0`) while the rectangle has room for both.

      iex> r = %Geex.Rect{x: 30, y: 0, w: 91, h: 20}
      iex> Geex.Layout.split(r, {:cols, {:pane, 1}, {:rows, {:pane, 2}, {:pane, 3}, 0.5}, 0.5})
      [
        {1, %Geex.Rect{x: 30, y: 0, w: 45, h: 20}},
        {2, %Geex.Rect{x: 76, y: 0, w: 45, h: 10}},
        {3, %Geex.Rect{x: 76, y: 10, w: 45, h: 10}}
      ]
      iex> Geex.Layout.split(r, {:cols, {:pane, 1}, {:pane, 2}, 0.25}) |> Enum.map(&elem(&1, 1).w)
      [22, 68]
      iex> Geex.Layout.split(r, {:cols, {:pane, 1}, {:pane, 2}, 0.01}) |> Enum.map(&elem(&1, 1).w)
      [12, 78]
  """
  @spec split(Rect.t(), split()) :: [{term(), Rect.t()}]
  def split(rect, {:pane, id}), do: [{id, rect}]

  def split(%Rect{} = r, {_dir, a, b, _ratio} = node) do
    {ra, rb, _at} = cut(r, node)
    split(ra, a) ++ split(rb, b)
  end

  @doc """
  The one-column dividers between side-by-side panes.

      iex> Geex.Layout.dividers(%Geex.Rect{x: 0, y: 0, w: 81, h: 20}, {:cols, {:pane, 1}, {:pane, 2}, 0.5})
      [%Geex.Rect{x: 40, y: 0, w: 1, h: 20}]
  """
  @spec dividers(Rect.t(), split()) :: [Rect.t()]
  def dividers(rect, split) do
    for %{dir: :cols, node: node, at: x} <- handles(rect, split),
        do: %Rect{x: x, y: node.y, w: 1, h: node.h}
  end

  @doc """
  Every split's boundary, outermost first: its `path` from the top (`:a` the first half, `:b` the
  second), its direction, its rectangle (`node`), and `at`: a `:cols` split's divider column, or
  the first row of a `:rows` split's second half (the top row of the panes below, their tab bars).
  Dragging one changes that split's ratio ([ADR-0039](../../doc/adr/0039-mouse.md) step 3).

      iex> r = %Geex.Rect{x: 0, y: 0, w: 81, h: 20}
      iex> Geex.Layout.handles(r, {:cols, {:pane, 1}, {:rows, {:pane, 2}, {:pane, 3}, 0.5}, 0.5})
      [
        %{path: [], dir: :cols, node: %Geex.Rect{x: 0, y: 0, w: 81, h: 20}, at: 40},
        %{path: [:b], dir: :rows, node: %Geex.Rect{x: 41, y: 0, w: 40, h: 20}, at: 10}
      ]
  """
  @spec handles(Rect.t(), split()) :: [
          %{path: [:a | :b], dir: :rows | :cols, node: Rect.t(), at: non_neg_integer()}
        ]
  def handles(rect, split), do: handles(rect, split, [])

  defp handles(_rect, {:pane, _id}, _path), do: []

  defp handles(%Rect{} = r, {dir, a, b, _ratio} = node, path) do
    {ra, rb, at} = cut(r, node)

    [%{path: Enum.reverse(path), dir: dir, node: r, at: at}] ++
      handles(ra, a, [:a | path]) ++ handles(rb, b, [:b | path])
  end

  @doc """
  The ratio that puts a split's boundary at `at` (a divider column, or the second half's first
  row), kept to the halves' least sizes. Exact: `split/2` puts it back at `at`.

      iex> node = {:cols, {:pane, 1}, {:pane, 2}, 0.5}
      iex> r = %Geex.Rect{x: 10, y: 0, w: 81, h: 20}
      iex> ratio = Geex.Layout.ratio_at(r, node, 30)
      iex> Geex.Layout.split(r, put_elem(node, 3, ratio)) |> Enum.map(&elem(&1, 1).w)
      [20, 60]
      iex> Geex.Layout.ratio_at(r, node, 12) == Geex.Layout.ratio_at(r, node, 22)
      true
  """
  @spec ratio_at(Rect.t(), split(), integer()) :: float()
  def ratio_at(%Rect{} = r, {dir, a, b, _ratio}, at) do
    {room, first} = if dir == :rows, do: {r.h, at - r.y}, else: {max(r.w - 1, 0), at - r.x}
    first = keep(first, room, least(a, dir), least(b, dir))
    if room > 0, do: (first + 0.5) / room, else: 0.5
  end

  # A split's two halves and its boundary (`handles/2`'s `at`).
  defp cut(%Rect{} = r, {:rows, a, b, ratio}) do
    top = keep(trunc(r.h * ratio), r.h, least(a, :rows), least(b, :rows))
    {%{r | h: top}, %{r | y: r.y + top, h: r.h - top}, r.y + top}
  end

  defp cut(%Rect{} = r, {:cols, a, b, ratio}) do
    room = max(r.w - 1, 0)
    left = keep(trunc(room * ratio), room, least(a, :cols), least(b, :cols))
    {%{r | w: left}, %{r | x: r.x + left + 1, w: max(r.w - left - 1, 0)}, r.x + left}
  end

  # The first half's size, kept between the halves' least sizes. When `room` is short of both,
  # the least sizes shrink in proportion, so neither half collapses to nothing before the other.
  defp keep(first, room, least_a, least_b) do
    least_a = min(least_a, div(room * least_a, max(least_a + least_b, 1)))
    least_b = min(least_b, room - least_a)
    first |> max(least_a) |> min(room - least_b)
  end

  @doc """
  The least `{w, h}` the file panes of `split` need (`min_pane/0` each, a divider between columns).
  `resolve/3` keeps the editor this big while a dragged tree or edits pane allows.

      iex> Geex.Layout.least({:cols, {:pane, 1}, {:rows, {:pane, 2}, {:pane, 3}, 0.5}, 0.5})
      {25, 8}
  """
  @spec least(split()) :: {pos_integer(), pos_integer()}
  def least(split), do: {least(split, :cols), least(split, :rows)}

  # The least size a subtree needs along a split's axis: panes, plus a divider between columns.
  defp least({:pane, _}, :rows), do: @min_pane_h
  defp least({:pane, _}, :cols), do: @min_pane_w
  defp least({dir, a, b, _}, dir) when dir == :cols, do: least(a, :cols) + 1 + least(b, :cols)
  defp least({dir, a, b, _}, dir), do: least(a, dir) + least(b, dir)
  defp least({_other, a, b, _}, dir), do: max(least(a, dir), least(b, dir))
end
