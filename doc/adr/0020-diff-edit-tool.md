# ADR-0020: Diff / search-replace edit tool

- **Status:** Accepted (approach decided; implementation follows file-lifecycle + reconcile)
- **Date:** 2026-06-04
- **Relates to:** [ADR-0014](0014-editor-state-and-dispatch-ownership.md), [ADR-0016](0016-external-harness-integration.md); detail in [research/diff-edit-tool.md](../research/diff-edit-tool.md)

## Context

Harnesses (Claude Code, aider, …) natively edit by emitting `old_text → new_text` /
search-replace blocks, not coordinates. When a harness's built-in writers are denied
([ADR-0016](0016-external-harness-integration.md)), the model's instinct is still to quote
old text and give new text — so geex should offer a tool shaped that way, on top of the
coordinate `replace` primitive ([ADR-0014](0014-editor-state-and-dispatch-ownership.md)).
The hard part is **robust apply** (matching possibly-stale `old_text`). Reference inputs:
**DeepSeek-Moby**'s hard-won apply engine and the Elixir/Hex diff ecosystem — surveyed in
[research/diff-edit-tool.md](../research/diff-edit-tool.md).

## Decision

- **Accept search/replace blocks, not unified diffs.** LLMs emit line-numbered diffs
  unreliably; the contract is "quote the old text verbatim with 2-3 lines of context, give
  the new text." A new `Geex.Commands.Edit` (MCP tool `edit`) takes an `edits` array of
  `{search, replace}` (+ optional `description`).
- **A pure `Geex.Edit.Resolve`** ports Moby's tiered matcher, first confident hit wins:
  (1) exact-unique substring; (2) whitespace-normalized line window, **re-indented to the
  file**; (3) **staleness gate** — whole-file similarity `< 0.75` ⇒ refuse; (4) anchor /
  order match. geex is **stricter than Moby**: refuse on `> 1` match (`:ambiguous`) rather
  than first-match-wins — safer against disk truth. It returns a coordinate span +
  replacement text; it does not mutate.
- **Compiles to the spine (resolve-and-snapshot).** Each confident block → a
  `Geex.Commands.Replace` `%Command{}` (the existing primitive) stamped with provenance and
  run through `Geex.Dispatch.run/1`. The diff tool is a *front-end*; `Replace` stays the
  sole doc mutator and every edit lands in the undo history. Multiple blocks apply
  **sequentially** (each re-resolved against the post-edit doc) to avoid coordinate drift.
- **Refuse, never guess, never merge.** No confident match → MCP `isError: true` with a
  self-correction message (`:stale` → "re-read"; `:ambiguous` → "add context"; `:not_found`
  → "quote exact text"); the model self-corrects. (Moby's scar: a "merge on uncertainty"
  fallback silently duplicated code on disk — geex refuses instead.)
- **No hex dependency.** `String/List.myers_difference` (built-in) cover diff + similarity;
  no Elixir lib does robust fuzzy *apply* (the hard part), so a dep wouldn't remove the
  work. ~200-300 lines of pure Elixir. One new arg type (`:edits`) in `Geex.Command.Type`
  + `Geex.MCP.Schema` (the only spine touch).

## Consequences

- Harness-ergonomic editing **on the one-dispatcher spine** — the `edit` tool is a
  projection that compiles to `replace`; undo/replay/provenance apply unchanged.
- Closes the coverage-gate ergonomics: an LLM can edit by quoting code, the way it's
  trained to, while every mutation is still a provenance-tagged `%Command{}`.
- **Riskiest:** (1) grapheme offset ↔ `{row,col}` conversion (off-by-one corrupts edits —
  property-test against naive string replace); (2) multi-block coordinate stability (apply
  sequentially / bottom-up); (3) the `isError` self-correction loop depends on the host
  surfacing tool errors as an actionable turn.

## See

[research/diff-edit-tool.md](../research/diff-edit-tool.md) (the full survey + algorithm),
[ADR-0014](0014-editor-state-and-dispatch-ownership.md) (the `replace` target),
[ADR-0016](0016-external-harness-integration.md) (the coverage gate).
