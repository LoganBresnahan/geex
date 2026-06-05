# ADR-0020: Diff / search-replace edit tool

- **Status:** Accepted — **implemented** (`Geex.Edit.Resolve` + `Geex.Commands.Edit`), with two refinements to the original plan, noted inline in the Decision
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
- **A pure `Geex.Edit.Resolve`** ports Moby's tiers, but only the **two deterministic
  tiers _apply_** (first confident, unique hit wins): (1) exact-unique substring;
  (2) whitespace-normalized line window, **re-indented to the file** (and preserving the
  file's line endings). geex is **stricter than Moby** on two axes: it refuses on `> 1`
  match (`:ambiguous`, counting *overlapping* occurrences) rather than first-match-wins; and
  it **never fuzzily _applies_ an anchor/patch/staleness match** — Moby's riskiest path and
  the source of its silent-duplication scar. Instead, when neither tier applies, a
  line-presence **classifier** only shapes the *refusal message* (`:stale` if most search
  lines still exist in the file → "re-read"; else `:not_found` → "quote exact text"). It
  returns a coordinate span + replacement text; it does not mutate. *(This refines the
  original four-applying-tier plan — the abandoned tiers 3/4 now inform refusal, not apply.)*
- **Compiles to the `Doc.replace` primitive as one atomic command.** `Geex.Commands.Edit`
  is a single `%Command{}` whose `run/2` resolves and applies each block **sequentially**
  against the *post-edit* doc (re-resolved each time, so no coordinate drift) via
  `Geex.Buffer.Doc.replace/3` — the same primitive `Geex.Commands.Replace` uses. Because
  `Geex.Buffer` leaves its state untouched when a command returns `{:error, _}`, a block
  that won't resolve **rolls back the whole edit for free** (all-or-nothing — a partial
  multi-block edit can never corrupt the file). One `%Edit{}` lands in the undo history;
  it records the search/replace *intent* (not baked coordinates), so replay re-resolves
  against the same reconstructed doc — deterministic. *(This refines the original
  "N separately-dispatched `Replace` commands through `Dispatch.run/1`" plan, which gave
  no atomicity; `Replace` remains the human/coordinate tool, not the `edit` apply path.)*
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
