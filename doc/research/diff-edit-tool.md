# Research: the diff / search-replace edit tool

Reference inputs: **DeepSeek-Moby** (`/home/oof/deepseek-vscode-extension`, a working
VSCode extension whose `src/utils/diff.ts` `DiffEngine` is the hard-won apply engine) +
the Elixir/Hex diff ecosystem. Goal: an MCP `edit` tool that lets an LLM express an edit
as `old_text → new_text` and have geex apply it robustly by **compiling to the coordinate
`replace` primitive** (`Geex.Buffer.Doc.replace/3`). This is a *planned* tool (built after
file-lifecycle + reconcile); this note records the decided approach so it isn't lost.

## What Moby does (the part worth copying)

- **Edit representation:** search/replace blocks — `{search, replace}` (a structured JSON
  array via its `edit_file` tool; also parses aider-style `<<<<<<< SEARCH/=======/>>>>>>>
  REPLACE` text). It **never asks the model for a unified diff** (LLMs emit those
  unreliably); the contract is "quote the old text verbatim, include 2-3 lines of context
  for uniqueness."
- **Tiered matcher** (`applySearchReplace`, first hit wins): (1) exact substring; (2)
  whitespace-normalized line-window — compares `trim`-ed lines, then **re-indents the
  replacement to the file's actual indentation**; (3) **staleness gate** — whole-file
  similarity `< 0.75` ⇒ refuse (do *not* fuzzily reapply a stale snippet); (4) anchor /
  order match (substantial unique-ish anchor lines, same relative order ±3 drift, scored).
- **Failure = refuse, never guess.** No confident match → `success:false` with an
  actionable message ("re-read the file and quote exact text"); stale → "file changed,
  re-read." A retry loop feeds the model the nudge. **Scar to heed:** an old fallback that
  *merged* on uncertainty silently **duplicated code on disk** — they deleted it. geex must
  refuse on uncertainty, never merge.
- **Key insight:** the model's job is to quote old text; the engine's job is to *locate* it
  robustly and refuse when unsure. Half the reliability is the tool description (ask for
  verbatim + context); half is the tiered matcher.

## Elixir / Hex ecosystem

- **Built-in (no dep):** `String.myers_difference/2` (grapheme-level) and
  `List.myers_difference/2` (line-level) cover diff-compute *and* similarity
  (`eq_count / total`). `JSON` is built-in (already used).
- **Hex:** `text_diff` (renders a unified/colored diff — a thin wrapper over the built-in;
  not worth a dep), `git_diff` (*parses* git diffs — only relevant if we ever accept
  unified-diff input, which we don't), `ex_diff` (redundant). **No maintained Elixir lib
  robustly *applies* fuzzy search/replace** — the actual hard part. So the apply engine is
  hand-rolled regardless; a dep wouldn't remove the work.

## Decision for geex (to implement post-reconcile)

- **Accept search/replace blocks** (a JSON array of `{search, replace}`), not unified diffs.
- **New `Geex.Commands.Edit`** (MCP tool `edit`): one `edits` arg (array) + optional
  `description`. Needs **one new arg type** (`:edits`/`:json`) added in exactly two places —
  `Geex.Command.Type.cast/2` and `Geex.MCP.Schema.json_type/1` (the only spine touch).
- **New pure `Geex.Edit.Resolve`** — `resolve_block(text, search, replace) ::
  {:ok, {{r1,c1},{r2,c2}}, text} | {:error, :stale | :ambiguous | :not_found}` porting
  Moby's tiers (but **stricter**: refuse on >1 match rather than first-match-wins, counting
  *overlapping* occurrences). **As built**, only two tiers *apply* — `exact` (unique
  substring; positions via string-prefix splitting, so grapheme-correct without byte math)
  and `normalized` (whitespace-normalized window + `reindent`, line-ending-preserving). The
  staleness/anchor reasoning is **not** an applying tier; a line-presence `classify/2` only
  shapes the refusal message. (Moby's jsdiff `applyPatch` tier is dropped — it existed only
  because jsdiff was already a dep.)
- **Compiles to the `Doc.replace` primitive as one atomic command:** `Geex.Commands.Edit`
  is a single `%Command{}` whose `run/2` resolves+applies each block **sequentially** against
  the post-edit doc (re-resolved each time → no drift) via `Doc.replace`. `Geex.Buffer`'s
  untouched-on-`{:error}` semantics give all-or-nothing rollback for free; one `%Edit{}`
  lands in history (recording the search/replace intent, so replay re-resolves
  deterministically). `Replace` stays the human/coordinate tool, not the `edit` apply path.
- **Failures → MCP `isError: true`** with a self-correction message (`:stale` →
  "re-read"; `:ambiguous` → "add context"; `:not_found` → "quote exact text"). Never crash,
  never guess, never merge.
- **No hex dependency.** ~200-300 lines of pure Elixir.

### Riskiest assumptions

1. **grapheme offset ↔ `{row,col}` conversion** — geex's value-add is the coordinate span,
   and `Doc.replace` is grapheme-indexed; an off-by-one silently corrupts edits. Mitigate
   with property tests: `resolve_block` + `Doc.replace` == naive string replace.
2. **multi-block coordinate stability** — resolve-then-apply invalidates later spans; apply
   sequentially (re-resolve per block) or bottom-up.
3. **`isError`-driven self-correction** depends on the MCP host surfacing tool errors as an
   actionable turn; the message text must stand alone ("re-read then resend").
