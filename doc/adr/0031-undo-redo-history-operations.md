# ADR-0031: Undo/redo — history operations (replay-from-base)

- **Status:** Accepted
- **Date:** 2026-06-09 (Accepted 2026-06-09 when built + wired into `Alt+Z` / `Alt+Shift+Z`)
- **Relates to:** [ADR-0014](0014-editor-state-and-dispatch-ownership.md) (the buffer owns the
  `EditorState` + the one history; the cursor is **view-local**), [ADR-0003](0003-one-shared-path.md)
  (one shared path; `replay/2` — the §15c regression backbone this reuses),
  [ADR-0030](0030-view-action-tool-category.md) (the tool taxonomy this extends; where a typed twin
  will live), [ADR-0022](0022-capability-reactor.md) (the highlight reactor + the `:reset` overlay
  path), [ADR-0029](0029-selection-primitive.md) (the selection an undo clears),
  [ADR-0017](0017-reconcile-file-watch.md) (external edits enter history, hence are undoable)

## Context

[ADR-0014](0014-editor-state-and-dispatch-ownership.md) put the **one undo history** on the
`Geex.Buffer` process: every edit `%Command{}` is appended (newest-first), and `replay/2` folds the
recorded list back over the loaded state — the deterministic, no-LLM regression backbone (§15c). But
that history was, until now, a **record without a reverse**: "undo history" existed as an append-only
log, and *nothing reverted it*. There was no `undo` operation. The docs referenced "the undo history"
everywhere; the verb didn't exist.

The trigger is the keybinding: **`Alt+Z` = undo, `Alt+Shift+Z` = redo** (the human surface; "highlight
all" moves off `Alt+Z` to `Alt+B`). Wiring the keys means building the engine.

Where does undo/redo sit in [ADR-0030](0030-view-action-tool-category.md)'s four-category taxonomy
(edit / read / operation / view-action)? **Nowhere cleanly.** Undo changes buffer **text**, so it fails
the view-action / operation test ("touches view-local / world, not text"). Yet it is **not a recorded
`%Command{}`** — it produces no command, carries no `%Command.Meta{}`, and *manipulates the history
itself*. Undo/redo are a distinct kind: **history operations**. They act on the buffer's own recorded
state, the way `save/1` acts on disk — a buffer operation, not an edit.

## Decision

**1. Undo/redo are history operations on the active buffer, owned by `Geex.Buffer`.**
`Geex.Buffer.undo/1` and `redo/1` (the buffer owns history, ADR-0014). Not `%Command{}`s, not recorded,
no `Meta` — siblings of `save/1` / `mark_synced/1`: operations on the buffer's own state. The loop runs
them on the active view's buffer (`Session.active_buffer/0`), exactly where `Dispatch.run/1` resolves
its target — but they **bypass** `Dispatch` (they are not commands).

**2. Mechanism: replay-from-base.** The buffer keeps the loaded `EditorState` as an immutable `base`.
`history` is the newest-first list of **applied** commands, and `replay(base, reverse(history)) ==
editor` is the §15c invariant ([ADR-0003](0003-one-shared-path.md)). So:

- **undo** drops the newest command onto a `redo` stack and **replays `base` + the remainder** to
  reconstruct the document. Guaranteed consistent — it re-runs the exact recorded commands that built
  the state.
- **redo** re-applies the popped command to the current editor and moves it back onto `history`.
- a fresh `dispatch/2` **clears the redo stack** — a new edit discards the redone future (the
  conventional linear-undo choice; an undo *tree* is out of scope).

`O(n)` per undo (replay re-runs the remaining commands). Acceptable for v1 — files are small and undo is
interactive — and it reuses the audited pure `replay/2` rather than a parallel data structure. A
snapshot-stack (`O(1)`) is the optimization if profiling ever shows it bites.

**3. Granularity: one command = one undo step (v1).** Every keystroke is its own `Insert`, so undo is
per-character. Coalescing a run of single-char inserts into one step is **deferred polish** — the history
is already per-command; coalescing is a boundary-detection layer on top.

**4. Cursor restoration stays view-local.** The buffer returns `{:ok, snapshot, command}` — the
**affected command** as data. The *view* (`Geex.Loop`) maps it to a cursor: **undo → the edit's start**
(its effect is gone), **redo → where the edit originally landed** (`cursor_after_insert` for Insert/
Replace, the point for Delete), clamped to the post-op text, and clears the selection. The cursor never
enters `EditorState` / `Buffer` ([ADR-0014](0014-editor-state-and-dispatch-ownership.md) §2).

**5. Overlays: emit a `:reset` change.** Undo/redo are a **wholesale revert/replay**, not a located byte
splice, so the change notification carries footprint **`:reset`**. The highlight reactor
([ADR-0022](0022-capability-reactor.md)) **drops its optimistic overlay** on `:reset` and re-highlights.
This is load-bearing, not cosmetic: undo makes the buffer **`version` (= `length(history)`) go
backwards**, and the reactor's `keep_optimistic` retains an optimistic overlay while `ov > version` — so
a *higher-version* pre-undo overlay would **freeze**, stale, across an entire run of undos. `:reset`
forces the next exact pass to be authoritative (a one-frame fall-back to the prior exact result, then
correct). Distinct from the `edit` tool's `:unknown` (which *retains* the prefix — there version only
moves forward).

**6. `dirty` recomputed against the synced baseline.** A forward `dispatch/2` is unconditionally dirty;
an undo/redo can land **exactly on the saved content**, which is genuinely clean — so undo/redo set
`dirty = (text != synced)`.

## Consequences

- **`Alt+Z` / `Alt+Shift+Z` are live.** The one case-*sensitive* Alt chord (`M-z` vs `M-Z`), since shift
  means a *different* action, not the same one. Select-all ("highlight all") moves to `Alt+B`.
- **The §15c replay backbone earns a second consumer** — regression replay was the first; undo is the
  second use of "the recorded history reconstructs the document."
- **Reconcile/external edits are undoable** — they enter history through `dispatch/2`
  ([ADR-0017](0017-reconcile-file-watch.md) already intends "therefore undoable, never silently lost").
- **Not yet on the typed/agent surface.** Undo/redo as discoverable, agent-callable commands ride the
  catalog + view-action build ([ADR-0030](0030-view-action-tool-category.md)). **Open question:** are
  they a view-action, an operation, or a *fifth* "history-operation" category? Their text effect says
  not view-action; their not-recorded nature says not edit. Leaning toward a history-op command twin,
  decided when the catalog lands.
- **Deferred:** insert coalescing (per-keystroke undo for now); the `O(n)` replay (snapshot-stack if it
  bites); an undo *tree* that preserves the redo branch across a new edit (we discard it — the
  conventional choice).

## See

[ADR-0014](0014-editor-state-and-dispatch-ownership.md) (history ownership; view-local cursor),
[ADR-0003](0003-one-shared-path.md) (`replay/2`), [ADR-0030](0030-view-action-tool-category.md) (the
taxonomy + the typed twin's future home), [ADR-0022](0022-capability-reactor.md) (the reactor + `:reset`),
`lib/geex/buffer.ex` (`undo/1`, `redo/1`, `revert/4`, `base`/`redo` state),
`lib/geex/loop.ex` (`do_undo`/`do_redo`, `edit_start`/`edit_landing`, `clamp_cursor`),
`lib/geex/highlight/reactor.ex` (the `:reset` `shift_overlay` clause),
`lib/geex/loop/keymap.ex` (`Alt+Z`/`Alt+Shift+Z`/`Alt+B`).
