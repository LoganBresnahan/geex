defmodule Geex.View do
  @moduledoc """
  A viewport onto a buffer — per-pane state.

  Holds the cursor, selection, scroll offset, and viewport rectangle for
  one pane's view of a buffer. Two panes can show the same buffer with
  independent cursors / selections / scroll positions; cursors do *not*
  live on the buffer itself.

  In v0.1 there is exactly one View (held inside `Geex.Session`).
  In v0.3+ each Pane will hold its own View; the active pane's View is
  what commands resolve coordinates against.
  """

  defstruct buffer_pid: nil,
            cursor: {0, 0},
            selection: nil,
            scroll: 0,
            viewport: %Geex.Rect{}

  @type cursor :: {non_neg_integer(), non_neg_integer()}

  @type selection :: nil | %{from: cursor(), to: cursor()}

  @type t :: %__MODULE__{
          buffer_pid: pid() | nil,
          cursor: cursor(),
          selection: selection(),
          scroll: non_neg_integer(),
          viewport: Geex.Rect.t()
        }
end
