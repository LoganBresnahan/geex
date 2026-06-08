defmodule Geex.Theme.Style do
  @moduledoc """
  The style a theme assigns to a capture: foreground/background colour + attrs.

  Deliberately the same colour/attr vocabulary as `Geex.Cell`
  (`{:rgb, r, g, b}` | `:default`; `:bold`/`:italic`/`:underline`/…), so a
  resolved style drops straight onto a cell. A theme
  ([ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md)) is a map
  of capture name → `Style`.
  """

  defstruct fg: :default, bg: :default, attrs: []

  @type t :: %__MODULE__{
          fg: Geex.Cell.colour(),
          bg: Geex.Cell.colour(),
          attrs: [Geex.Cell.attr()]
        }
end
