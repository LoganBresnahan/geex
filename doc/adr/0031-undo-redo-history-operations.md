# ADR-0031: Undo/redo — history operations (replay-from-base)

- **Status:** Accepted. **Amended 2026-11-06 ([ADR-0043](0043-markdown-preview.md)):** `Alt+Shift+P` is the second case-sensitive chord. **Amended 2026-11-09:** every edit recomputes `dirty`. **Amended 2026-11-12 by [ADR-0051](0051-panes-on-alt-angle-brackets-digits-free.md):** `Alt+P` is the preview now, and `Alt+Shift+R` (`revert-call`) the second case-sensitive chord. **Amended 2026-11-12:** undo and redo take back what one action applied together (§3).
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

**5. Overlays: undo/redo are ordinary byte-footprint changes on a monotonic `seq`.** An undo/redo step
reverts *exactly one contiguous command*, so its effect on the text is a single byte splice — computed by
diffing the pre- and post-revert text (`Geex.Edit.Footprint.between/2`, the longest common prefix + suffix).
Undo/redo emit *that* footprint, so the highlight reactor ([ADR-0022](0022-capability-reactor.md)) **shifts
its optimistic overlay** across the revert exactly as it does for forward typing — no re-highlight flash.

The one obstacle is that undo makes `version` (= `length(history)`) go **backwards**, and the reactor's
`keep_optimistic` (`ov > version`) assumes "newer = higher version" — so a backwards jump would make it drop
the freshest optimistic overlay across a run of undos. The buffer therefore carries a **monotonic `seq`**
(incremented on every dispatch/undo/redo, *distinct* from `version`), and the reactor orders overlays by
`seq`. With the byte-footprint shift + the monotonic `seq`, undo/redo need **no special reactor case at all** —
they *are* forward changes to the overlay machinery.

> *Revised from the first cut.* The initial implementation emitted a `:reset` footprint that made the reactor
> drop its overlay and re-highlight from scratch. It was correct but **flashed** the reverted region unstyled
> for the whole async re-highlight window (a more visible flicker than the near-aligned stale frame it
> replaced). Riding the normal byte-shift path removes the flash; the `:reset` clause and the interim
> render-time guard are gone.

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
- **Undo/redo are flicker-free** because they reuse the forward-edit overlay path (the byte-footprint shift
  + the monotonic `seq`), and that path also gained a reusable primitive (`Footprint.between/2`) and a clean
  monotonic change clock that future overlay consumers (LSP) can order by.
- **Deferred:** insert coalescing (per-keystroke undo for now); the `O(n)` replay (snapshot-stack if it
  bites); an undo *tree* that preserves the redo branch across a new edit (we discard it — the
  conventional choice).


## Amendment — 2026-11-06: not the one case-sensitive chord ([ADR-0043](0043-markdown-preview.md))

`Alt+Shift+Z` is no longer the one case-sensitive Alt chord: `Alt+Shift+P` toggles the markdown
preview while `Alt+P` stays the next pane. As here, Caps Lock with the plain chord gives the
shifted one.


## Amendment — 2026-11-09: dirty follows the text (roadmap item 18.2)

Every transition recomputes `dirty` against the synced text, a forward edit included: typing a
space and deleting it by hand leaves the buffer clean, not only an undo back to the baseline.
`History.differs?/2` compares sizes first, without a copy, and joins the text only when they are
equal. A property pins the law: after any generated transition, `dirty` is whether the text
differs from `synced`.

## Amendment — 2026-11-12: undo and redo by what one action applied together

**Context.** §3 made every command its own undo step. Some actions apply several commands at once,
as one atomic group (`History.group/3`): an outside writer's change taken in by a fast-forward or a
save (one command per hunk, ADR-0034), and a revert (`Alt+R`, `Alt+Shift+R`, ADR-0033 §7). One
`Alt+Z` after a `revert-call` of three hunks gave back one of them, leaving the call half reverted,
the partial state ADR-0033 refuses to create (mod-verify's review of ADR-0051). The maintainer,
2026-11-12: "yes", undoing "per group … rather than per edit" where an action made the group.

**Decision.**

1. **A step is what one action applied.** Undo takes back every command one `History.group/3` call
   applied, newest first, as one step; redo puts them all back. A command applied alone (a key, a
   typed verb, an agent's MCP edit) is a step of one, as before: typing is unchanged.
2. **The history marks the step.** `History.group/3` stamps each command it applies with the same
   step id (`meta.step`, from a counter in the history); `History.dispatch/2` leaves it `nil`, a
   step of one. Like the rest of `meta` it never feeds `run/2`, so replay and the §15c cassette are
   unaffected.
3. **The ledger replays as before.** A step of three is written as three `undo` (or `redo`)
   entries, one per command, as before, so every ledger, old or new, replays to the same history
   (`Geex.Ledger.Restore` steps one command per entry, and a step advances the change clock once
   per command, as those single undos do). The codec writes a command's `step` when it has one,
   and restore keeps it (`History.group/4`'s `keep_steps:`), so a reopened file undoes by step and
   a compaction's kept commands keep theirs; a group recorded before steps existed gets a fresh
   id as it is replayed. Later ids pass any id a replayed command carries. Restore folds a run
   of `undo` entries into one replay (`History.undo_many/2`, the value that many single undos
   give): one replay per entry made a reopen after undoing a step of 1,000 take over 12 s
   (mod-verify's review). Compaction moves its cut back to a step boundary, keeping a step it
   would split whole (a few more commands than asked).
4. **Never half a step.** Undo and redo move a whole step or nothing. An attestation (ADR-0032)
   relabels a group's commands wherever they are; it doesn't change their step.
5. **The view.** After an undo the cursor goes to the start of the step's topmost command (a
   group's hunks run bottom up, so a line above the others keeps its coordinates in the text the
   undo left); after a redo, where its newest command left off; for one command, as before (§4).
   A step of several says so in a notice ("undid 3 edits").

**Consequences.** A fast-forward or revert of several hunks is one `Alt+Z`, as it was one key. An
`Alt+Z` that used to take back one hunk of an outside change now takes back the whole change; to
keep part of it, revert hunks one at a time with `Alt+R`. A save that trims trailing whitespace
(ADR-0054) is one step for the same reason.

## See

[ADR-0014](0014-editor-state-and-dispatch-ownership.md) (history ownership; view-local cursor),
[ADR-0003](0003-one-shared-path.md) (`replay/2`), [ADR-0030](0030-view-action-tool-category.md) (the
taxonomy + the typed twin's future home), [ADR-0022](0022-capability-reactor.md) (the reactor the overlay
shift rides),
`lib/geex/buffer.ex` (`undo/1`, `redo/1`, `revert/4`, `base`/`redo`/`seq` state, `revert_footprint`),
`lib/geex/edit/footprint.ex` (`between/2` — the undo/redo splice),
`lib/geex/loop.ex` (`do_undo`/`do_redo`, `edit_start`/`edit_landing`, `clamp_cursor`),
`lib/geex/highlight/reactor.ex` (orders overlays by `seq`),
`lib/geex/loop/keymap.ex` (`Alt+Z`/`Alt+Shift+Z`/`Alt+B`).
