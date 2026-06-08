defmodule Geex.Highlight.Span do
  @moduledoc """
  One highlight capture span — geex's **host-in** `Highlight` contract
  ([ADR-0021](../../../doc/adr/0021-capability-connections.md) /
  [ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md)).

  A span is `{byte offset, byte offset, capture name}`. The **capture name**
  (`"keyword"`, `"string.escape"`, `"function"`) is the engine↔theme contract:
  this data is engine- *and* theme-agnostic — it carries no colour. A theme
  ([ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md)) maps the
  capture name to a `Style`; the renderer turns that into ANSI.

  Offsets are **byte** offsets into the source (tree-sitter is byte-oriented),
  not grapheme indices — the renderer slices the source by these directly.
  """

  @enforce_keys [:start_byte, :end_byte, :capture]
  defstruct [:start_byte, :end_byte, :capture]

  @type t :: %__MODULE__{
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          capture: String.t()
        }
end
