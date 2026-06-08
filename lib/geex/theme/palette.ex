defmodule Geex.Theme.Palette do
  @moduledoc """
  The editor-chrome colours of a theme — everything that is *not* a syntax
  capture ([ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md)):
  the editor background/foreground, line numbers, the active line, the cursor,
  and the selection. Colours are opaque `{:rgb, …}` (alpha already flattened).
  """

  @enforce_keys [:bg, :fg]
  defstruct [:bg, :fg, :line_number, :active_line_number, :active_line_bg, :cursor, :selection]

  @type t :: %__MODULE__{
          bg: Geex.Cell.colour(),
          fg: Geex.Cell.colour(),
          line_number: Geex.Cell.colour(),
          active_line_number: Geex.Cell.colour(),
          active_line_bg: Geex.Cell.colour(),
          cursor: Geex.Cell.colour(),
          selection: Geex.Cell.colour()
        }
end
