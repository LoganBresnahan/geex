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

  @doc """
  Shift every span across a byte `footprint` (`%{at, removed, added}` from
  `Geex.Edit.Footprint`) — the *optimistic* overlay transform that keeps colours
  aligned across an edit until the async re-highlight lands
  ([ADR-0022](../../../doc/adr/0022-capability-reactor.md)).

  A byte position past the removed region's end (`at + removed`) shifts by
  `added - removed`; one inside the removed bytes collapses to `at`. At the edit
  boundary the two ends are treated **asymmetrically** so freshly inserted bytes
  inherit *neither* neighbour's colour: a span **start** exactly at `at` slides
  *right* with the inserted bytes (strict `< at` stays), while a span **end** exactly
  at `at` *stays* (inclusive `<= at`). So a char typed between two tokens is left
  uncoloured by both for the optimistic frame, matching the eventual re-highlight.
  A span whose end no longer exceeds its start (fully deleted) is dropped, so the
  result is always a list of valid spans.

  This is a structural approximation — token *types* don't change — so the exact
  re-highlight that follows supersedes it; it only has to be right about *where*
  the existing colours move, which prevents the typing-tail flicker.
  """
  @spec shift_all([t()], %{at: non_neg_integer(), removed: non_neg_integer(), added: non_neg_integer()}) ::
          [t()]
  def shift_all(spans, %{at: at, removed: removed, added: added}) do
    removed_end = at + removed
    delta = added - removed

    Enum.flat_map(spans, fn %__MODULE__{start_byte: s, end_byte: e} = span ->
      ns = shift_start(s, at, removed_end, delta)
      ne = shift_end(e, at, removed_end, delta)
      if ne > ns, do: [%{span | start_byte: ns, end_byte: ne}], else: []
    end)
  end

  # A START byte exactly at `at` slides right with the inserted bytes (strict `<`).
  defp shift_start(p, at, _removed_end, _delta) when p < at, do: p
  defp shift_start(p, _at, removed_end, delta) when p >= removed_end, do: p + delta
  defp shift_start(_p, at, _removed_end, _delta), do: at

  # An END byte exactly at `at` stays (a token ending at the edit doesn't absorb the
  # typed char — inclusive `<=`).
  defp shift_end(p, at, _removed_end, _delta) when p <= at, do: p
  defp shift_end(p, _at, removed_end, delta) when p >= removed_end, do: p + delta
  defp shift_end(_p, at, _removed_end, _delta), do: at
end
