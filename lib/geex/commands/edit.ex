defmodule Geex.Commands.Edit do
  @moduledoc """
  The harness-ergonomic editing front-end (ADR-0020): an LLM edits by quoting old
  text and giving new text — the way it's trained to — and geex compiles that to the
  coordinate `replace` primitive. `edits` is an array of `{search, replace}` blocks
  (quote the old text verbatim with a few lines of context; give the new text).

  It is **one atomic command**, not N dispatched edits. `run/2` resolves and applies
  each block sequentially against the *post-edit* document (so block 2 sees block 1's
  result — no coordinate drift), via `Geex.Buffer.Doc.replace/3` — the same primitive
  `Geex.Commands.Replace` uses. If any block can't be resolved confidently, `run/2`
  returns `{:error, {:edit_failed, message}}` and **nothing is applied** (the buffer
  leaves dispatch untouched on error — `Geex.Buffer`): all-or-nothing, so a partial
  edit can never corrupt the file. The model gets a self-correction message and resends.

  Matching is delegated to the pure `Geex.Edit.Resolve` (exact-unique, then
  whitespace-normalized window with re-indentation; refuse-don't-guess). Refusals are
  classified into actionable guidance: `:stale` → re-read; `:ambiguous` → add context;
  `:not_found` → quote exact text.
  """

  use Geex.Command

  alias Geex.Buffer.Doc
  alias Geex.Edit.Resolve
  alias Geex.EditorState

  command :edit do
    description(
      "Edit the active buffer with search/replace blocks. Quote the OLD text verbatim " <>
        "(include 2-3 lines of surrounding context so it's unique) and give the NEW text. " <>
        "Blocks apply in order; if any block can't be matched confidently, the whole edit " <>
        "is refused with guidance and nothing changes."
    )

    arg(:edits, :edits,
      description:
        "Array of {search, replace} objects. `search` must quote text from the buffer " <>
          "verbatim; `replace` is the new text (empty to delete)."
    )

    arg(:description, :string,
      default: "",
      description: "Optional summary of the change (recorded with the command)."
    )

    run(cmd, state) do
      apply_blocks(cmd.edits, state)
    end
  end

  # Thread the EditorState through the blocks, re-resolving each against the current
  # (post-previous-block) text. Halt with {:error, {:edit_failed, msg}} on the first
  # block that won't resolve — the caller's dispatch discards the partial state.
  defp apply_blocks(edits, state) do
    total = length(edits)

    edits
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, state}, fn {block, index}, {:ok, acc} ->
      text = EditorState.text(acc)

      case Resolve.resolve_block(text, block.search, block.replace) do
        {:ok, span, replacement} ->
          case EditorState.update_doc(acc, &Doc.replace(&1, span, replacement)) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, {:edit_failed, apply_error(index, reason)}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:edit_failed, refusal(index, total, block, reason)}}}
      end
    end)
  end

  defp refusal(index, total, block, reason) do
    "edit block #{index}/#{total} (search starts: #{snippet(block.search)}): " <>
      guidance(reason) <> " No edits were applied."
  end

  defp guidance(:stale),
    do: "the file has changed since you read it — re-read it and re-quote the exact current text."

  defp guidance(:ambiguous),
    do:
      "that text matches more than one place — add a few surrounding lines so the search is unique."

  defp guidance(:not_found),
    do: "no matching text found — quote the old text exactly as it appears in the buffer."

  # A resolved span that Doc.replace still rejects would be an internal coordinate bug;
  # surface it rather than corrupt. Defensive — Resolve only returns valid spans.
  defp apply_error(index, reason),
    do:
      "edit block #{index}: could not apply the resolved span (#{inspect(reason)}). No edits were applied."

  defp snippet(search) do
    first = search |> String.split("\n") |> List.first() |> String.trim()

    if String.length(first) > 60 do
      inspect(String.slice(first, 0, 60) <> "…")
    else
      inspect(first)
    end
  end
end
