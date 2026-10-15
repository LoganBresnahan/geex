defmodule Geex.Layout do
  @moduledoc """
  Where each pane goes on the screen ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md)
  §4). Pure: the terminal size and which panels are shown in, `Geex.Rect`s out.

  A fixed shape, not a general split tree: the file tree in a column on the left, the editor on
  the right, the edits pane in a band under the editor (a title row and up to 8 rows), and the
  status line across the bottom row. The editor's rectangle includes its horizontal scroll-bar
  row; the tree's includes its divider column on the right.

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
end
