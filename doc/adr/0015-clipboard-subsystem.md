# ADR-0015: Clipboard as a sibling subsystem (registers + ring history)

- **Status:** Accepted
- **Date:** 2026-06-03

## Context

copy / cut / paste need a clipboard. The design doc's §4 sketch had `copy` write
`state.clipboard` — i.e. the clipboard *inside* the dispatch state — which would force
cross-process gather/scatter for a global clipboard and muddy "which history does a
copy belong to?". The author wants **both** buffer-local and global clipboards, **each
with history**.

## Decision

The clipboard is **not** part of the replayable `EditorState`
([ADR-0014](0014-editor-state-and-dispatch-ownership.md)). It is a separate
`Geex.Clipboard` subsystem — a **selection source**, exactly like the cursor:

- **paste** resolves the chosen register and **bakes the literal text into an edit
  command** (an insert carrying its text), so paste replays deterministically
  *regardless of clipboard state* (the same resolve-and-snapshot discipline as the
  cursor, ADR-0014).
- **cut** = a recorded `delete` command (the undoable doc edit) **+** a push onto the
  clipboard ring.
- **copy** = a push onto the clipboard ring **only** — no doc mutation, **not in the
  undo history** (matches every editor; Ctrl-Z doesn't un-copy).
- Each register is a **ring** with its own history (emacs kill-ring / vim registers),
  browsable via yank-pop — the clipboard's *own* history, distinct from the document's.
- **Scope is a feature dial**, not an architecture constraint: global registers (the
  default), buffer-local registers, each a ring. Ring entries may carry provenance for
  "who copied what" auditability without polluting the document history.

## Consequences

- The document undo history stays pure edits; the clipboard keeps its own ring history.
  **Two stores, two histories — by design.**
- Both buffer-local and global clipboards are supported with **no impact on the
  one-path spine**, because clipboard ops resolve into edit commands (paste) or are
  non-recorded ring pushes (copy / cut-push).
- Refines [mcp-ai-integration.md](../mcp-ai-integration.md) §4: `copy` is a
  clipboard-subsystem op, not a `state.clipboard` mutation.
- v0.1 can ship a minimal global default register + ring and grow to named / local
  registers without rework.

## See

[vision.md](../vision.md) §1, [mcp-ai-integration.md](../mcp-ai-integration.md) §4,
[ADR-0002](0002-commands-as-values.md),
[ADR-0014](0014-editor-state-and-dispatch-ownership.md).
