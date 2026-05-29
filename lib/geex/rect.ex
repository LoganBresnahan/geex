defmodule Geex.Rect do
  @moduledoc """
  Plain rectangle: top-left corner `{x, y}` plus `w`idth and `h`eight.
  Used for viewports, pane bounds, and any layout math.
  """

  defstruct x: 0, y: 0, w: 0, h: 0

  @type t :: %__MODULE__{
          x: non_neg_integer(),
          y: non_neg_integer(),
          w: non_neg_integer(),
          h: non_neg_integer()
        }
end
