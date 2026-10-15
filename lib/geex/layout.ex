defmodule Geex.Layout do
  @moduledoc """
  Where each pane goes on the screen ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md)
  §4). Pure: the terminal size and which panels are shown in, `Geex.Rect`s out.

  A fixed shape, not a general split tree: the editor on top, the edits pane in a band under it
  (a title row and up to 8 rows), and the status line on the bottom row. The file tree joins as a
  left column in a later step. The editor's rectangle includes its horizontal scroll-bar row.

      iex> l = Geex.Layout.resolve(80, 24, %{edits: true})
      iex> {l.editor.h, l.edits.y, l.edits.h, l.status}
      {15, 15, 8, 23}

      iex> Geex.Layout.resolve(80, 24, %{edits: false}).edits
      nil
  """

  alias Geex.Rect

  # Below this many rows, a shown edits pane would leave the editor too little room.
  @min_h 12
  # The list's rows, plus its title row.
  @rows 8

  @type t :: %{editor: Rect.t(), edits: Rect.t() | nil, status: non_neg_integer()}

  @doc "The rectangles for a `w` × `h` terminal. `shown.edits`: the edits pane is shown."
  @spec resolve(non_neg_integer(), non_neg_integer(), %{edits: boolean()}) :: t()
  def resolve(w, h, %{edits: edits?}) do
    edits_h = if edits? and h >= @min_h, do: min(@rows + 1, div(h, 3)), else: 0
    editor_h = max(h - 1 - edits_h, 0)

    %{
      editor: %Rect{x: 0, y: 0, w: w, h: editor_h},
      edits: if(edits_h > 0, do: %Rect{x: 0, y: editor_h, w: w, h: edits_h}),
      status: max(h - 1, 0)
    }
  end
end
