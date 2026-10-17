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

  @type t :: %{
          editor: Rect.t(),
          edits: Rect.t() | nil,
          tree: Rect.t() | nil,
          status: non_neg_integer()
        }

  @doc """
  The rectangles for a `w` × `h` terminal. `shown`: whether the edits pane and the tree are
  shown (a missing key means not). The tree takes a quarter of the width, 20 to 36 columns.
  """
  @spec resolve(non_neg_integer(), non_neg_integer(), map()) :: t()
  def resolve(w, h, shown) do
    tree_w = if shown[:tree] && w >= @min_w, do: w |> div(4) |> max(20) |> min(36), else: 0
    edits_h = if shown[:edits] && h >= @min_h, do: min(@rows + 1, div(h, 3)), else: 0
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
  split, `:rows` stacked top and bottom, `:cols` side by side.
  """
  @type split :: {:pane, term()} | {:rows | :cols, split(), split()}

  @doc """
  Each file pane's rectangle within `rect`, in reading order (left to right, top to bottom). A
  split halves its rectangle evenly; a `:cols` split keeps one column between the halves for a
  divider (`dividers/2`).

      iex> r = %Geex.Rect{x: 30, y: 0, w: 91, h: 20}
      iex> Geex.Layout.split(r, {:cols, {:pane, 1}, {:rows, {:pane, 2}, {:pane, 3}}})
      [
        {1, %Geex.Rect{x: 30, y: 0, w: 45, h: 20}},
        {2, %Geex.Rect{x: 76, y: 0, w: 45, h: 10}},
        {3, %Geex.Rect{x: 76, y: 10, w: 45, h: 10}}
      ]
  """
  @spec split(Rect.t(), split()) :: [{term(), Rect.t()}]
  def split(rect, {:pane, id}), do: [{id, rect}]

  def split(%Rect{} = r, {:rows, a, b}) do
    top = div(r.h, 2)
    split(%{r | h: top}, a) ++ split(%{r | y: r.y + top, h: r.h - top}, b)
  end

  def split(%Rect{} = r, {:cols, a, b}) do
    left = div(max(r.w - 1, 0), 2)
    split(%{r | w: left}, a) ++ split(%{r | x: r.x + left + 1, w: max(r.w - left - 1, 0)}, b)
  end

  @doc """
  The one-column dividers between side-by-side panes.

      iex> Geex.Layout.dividers(%Geex.Rect{x: 0, y: 0, w: 81, h: 20}, {:cols, {:pane, 1}, {:pane, 2}})
      [%Geex.Rect{x: 40, y: 0, w: 1, h: 20}]
  """
  @spec dividers(Rect.t(), split()) :: [Rect.t()]
  def dividers(_rect, {:pane, _id}), do: []

  def dividers(%Rect{} = r, {:rows, a, b}) do
    top = div(r.h, 2)
    dividers(%{r | h: top}, a) ++ dividers(%{r | y: r.y + top, h: r.h - top}, b)
  end

  def dividers(%Rect{} = r, {:cols, a, b}) do
    left = div(max(r.w - 1, 0), 2)

    [%Rect{x: r.x + left, y: r.y, w: 1, h: r.h}] ++
      dividers(%{r | w: left}, a) ++
      dividers(%{r | x: r.x + left + 1, w: max(r.w - left - 1, 0)}, b)
  end
end
