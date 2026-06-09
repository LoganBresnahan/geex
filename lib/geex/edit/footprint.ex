defmodule Geex.Edit.Footprint do
  @moduledoc """
  The **byte footprint** of an edit command against the *pre-edit* document — the
  splice `%{at, removed, added}` (all byte counts) that turns the old text into the
  new one: at byte `at`, `removed` bytes are replaced by `added` bytes.

  It exists to shift a byte-oriented highlight overlay
  ([`Geex.Highlight.Span`](../highlight/span.ex)) across an edit *optimistically* —
  before the async re-highlight lands — so the tail of an edited line stays colour-
  aligned and doesn't flicker ([ADR-0022](../../../doc/adr/0022-capability-reactor.md)).
  The buffer computes it at dispatch (it has the pre-edit `Doc` + the command) and
  carries it on the change event; `Geex.Highlight.Span.shift_all/2` applies it.

  `:unknown` for any command whose byte footprint isn't a single contiguous splice
  (today: the multi-block `edit` tool) — the consumer then falls back to re-highlight
  with no optimistic shift (one stale frame, acceptable off the interactive path).
  """

  alias Geex.Buffer.Doc
  alias Geex.Commands.{Delete, Insert, Replace}

  @type t :: %{at: non_neg_integer(), removed: non_neg_integer(), added: non_neg_integer()}

  @doc """
  The byte footprint **between two texts** — the minimal single splice (the longest
  common byte prefix + suffix) that turns `before` into `after`.

  Used for undo/redo ([ADR-0031](../../../doc/adr/0031-undo-redo-history-operations.md)),
  which revert/replay the document wholesale rather than running a command with a known
  `of/2` footprint: each undo/redo step reverts exactly one contiguous command, so this
  splice is **exact**, and the reactor shifts its overlay by it just like a forward edit —
  so undo no longer flashes the whole region uncoloured while the re-highlight catches up.
  The footprint is expressed in `before`'s byte frame (the frame the live overlay is in).
  """
  @spec between(String.t(), String.t()) :: t()
  def between(before, aft) when is_binary(before) and is_binary(aft) do
    prefix = :binary.longest_common_prefix([before, aft])
    # Cap the suffix so the common prefix and suffix can't overlap in the shorter string
    # (e.g. "aa" -> "aaa": prefix 2, suffix must be 0, giving an insert of 1 byte at 2).
    max_suffix = min(byte_size(before), byte_size(aft)) - prefix
    suffix = min(:binary.longest_common_suffix([before, aft]), max_suffix)

    %{
      at: prefix,
      removed: byte_size(before) - prefix - suffix,
      added: byte_size(aft) - prefix - suffix
    }
  end

  @doc "The byte footprint of `command` applied to the pre-edit `doc`, or `:unknown`."
  @spec of(Doc.t(), struct()) :: t() | :unknown
  def of(%Doc{} = doc, %Insert{line: line, col: col, text: text}),
    do: %{at: Doc.byte_offset(doc, {line, col}), removed: 0, added: byte_size(text)}

  def of(%Doc{} = doc, %Delete{line: line, col: col, count: count}) do
    at = Doc.byte_offset(doc, {line, col})
    %{at: at, removed: Doc.byte_offset(doc, {line, col + count}) - at, added: 0}
  end

  def of(%Doc{} = doc, %Replace{
        start_line: sl,
        start_col: sc,
        end_line: el,
        end_col: ec,
        text: text
      }) do
    s = Doc.byte_offset(doc, {sl, sc})
    e = Doc.byte_offset(doc, {el, ec})
    %{at: s, removed: e - s, added: byte_size(text)}
  end

  def of(%Doc{}, _command), do: :unknown
end
