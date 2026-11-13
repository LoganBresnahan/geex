defmodule Geex.Theme.Palette do
  @moduledoc """
  The editor-chrome colours of a theme — everything that is *not* a syntax
  capture ([ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md)):
  the editor background/foreground, line numbers, the active line, the cursor,
  and the selection. Colours are opaque `{:rgb, …}` (alpha already flattened), or for the
  built-in terminal palette (`Geex.Theme.Terminal`) `:default` and `{:ansi, n}`.

  `mark` is the attrs added to whatever is drawn on `active_line_bg` or `selection` (a picked
  row, the selection, the minibuffer line): `[]` for a theme with real colours there, and
  `[:reverse]` for the terminal palette when it doesn't know the terminal's background, so the
  pick still shows.

  `search` is the background of a search's other matches on screen (ADR-0053's 2026-11-13
  amendment): a theme sets it as `"search"`; one that doesn't gets the colour halfway between
  its background and its selection. `nil` (the terminal palette without the terminal's
  background, where the selection is reverse video) draws them underlined instead.

  `accent` is a light blue for what is yours or in hand: what is installed in the `Alt+Y` view
  (a grammar, a theme, the theme in use), the files open in a tab in the tree, and the edits
  pane's highlighted entry while it has focus (ADR-0040 §7). A theme file sets it as
  `"accent"`; one that doesn't gets ANSI bright cyan when dark, blue when light.
  """

  @enforce_keys [:bg, :fg]
  defstruct [
    :bg,
    :fg,
    :line_number,
    :active_line_number,
    :active_line_bg,
    :cursor,
    :selection,
    search: nil,
    accent: {:ansi, 14},
    mark: []
  ]

  @type t :: %__MODULE__{
          bg: Geex.Cell.colour(),
          fg: Geex.Cell.colour(),
          line_number: Geex.Cell.colour(),
          active_line_number: Geex.Cell.colour(),
          active_line_bg: Geex.Cell.colour(),
          cursor: Geex.Cell.colour(),
          selection: Geex.Cell.colour(),
          search: Geex.Cell.colour() | nil,
          accent: Geex.Cell.colour(),
          mark: [Geex.Cell.attr()]
        }
end
