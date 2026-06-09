# ADR-0030: View actions — a fourth tool category for view-local commands

- **Status:** Proposed
- **Date:** 2026-06-09
- **Relates to:** [ADR-0019](0019-file-lifecycle-and-operation-tools.md) (the third category — operation
  tools — and the field-spec→`tools/list` projection this reuses), [ADR-0028](0028-editor-shell-and-minibuffer.md)
  (the parity principle + "the view-action category as the mechanism", amendment §4), [ADR-0027](0027-grid-command-addressing.md)
  (grid `goto`/coordinates; the `:N/` pane prefix), [ADR-0014](0014-editor-state-and-dispatch-ownership.md)
  (the view-local cursor, *out* of `EditorState`/history), [ADR-0003](0003-one-shared-path.md) (one shared path),
  [ADR-0029](0029-selection-primitive.md) (the selection a `select` view-action sets)

## Context

geex's MCP surface has **three** tool categories ([ADR-0019](0019-file-lifecycle-and-operation-tools.md)):
**edit tools** (`insert`/`delete`/`replace`/`edit` — recorded `%Command{}`s, undoable), **read tools**
(the query surface), and **operation tools** (`open`/`save`/`create`/`delete`/`rename`/`close` — act on
disk/the buffer set, *not* recorded). But three view-local actions have no honest home:

- **go-to-line** is a **hardcoded hack** — `Geex.Loop.run_command/1` `Integer.parse`s the minibuffer
  value and calls `Session.set_cursor/1` directly, bypassing the catalog entirely. It is neither a
  command nor a registered tool, so it can't appear in the palette and an agent can't call it.
- **scroll** and **select** (set a [selection](0029-selection-primitive.md) from coordinates) are the
  same shape: they mutate *view-local* state, will want both a keybinding and a typed twin, and must be
  discoverable.

[ADR-0028](0028-editor-shell-and-minibuffer.md)'s parity principle (every keyboard capability also a
typed command) and its amendment §4 already named the fix: **a fourth category — view actions.** This
ADR pins it, with **go-to-line as the first member** (retiring the hack).

## Decision

**1. A fourth tool category: *view actions*.** Tools that mutate **view-local, ephemeral** state —
the cursor, scroll, and selection ([ADR-0014](0014-editor-state-and-dispatch-ownership.md) /
[ADR-0029](0029-selection-primitive.md)) — registered with a **field-spec** exactly like operation
tools, so the same `Geex.MCP.Schema` projects their `inputSchema` into `tools/list` and the same
`Geex.Command.cast_args/2` validates their arguments (no drift, no hand-synced JSON). They live in a new
`Geex.MCP.ViewActions` mirroring `Geex.MCP.Operations`; `tools/call` gains a fourth routing branch and
`tools/list` merges all four categories.

**2. The four-category discriminator (the complete taxonomy).** What a tool touches decides its category
and whether it is recorded:

| category | touches | recorded `%Command{}`? | in undo history? |
|---|---|---|---|
| **edit** | buffer *text* | ✅ yes | ✅ (replay rebuilds the text) |
| **read** | nothing (query) | — | — |
| **operation** | disk / the buffer set | ❌ | ❌ |
| **view action** | view-local cursor / scroll / selection | ❌ | ❌ |

The test stays "**does replaying it rebuild buffer text?**" — only edits. Operations vs view actions
split on *world* effect (disk/buffer-lifecycle) vs *view-local* ephemeral effect. A view action never
reaches `Geex.Dispatch`, never enters a buffer's history, and produces no `%Command{}` — moving the
cursor is not an edit ([ADR-0014](0014-editor-state-and-dispatch-ownership.md)).

**3. First member: `line` (go-to-line), retiring the hack.** Field-spec `{line: integer}`, 1-based,
preserving the current convention that **`0` jumps to the last line**; out-of-range **clamps** (the
existing behaviour). Its handler resolves against the active view's buffer text and calls
`Session.set_cursor/1`. The bare-number minibuffer shortcut (`:42`) becomes **sugar** that parses to the
`line` view-action and dispatches it through the *same* path an agent's `tools/call line` takes — so
`Geex.Loop.run_command/1` stops calling `set_cursor` directly and instead routes to `ViewActions`. The
typed `line 42` and the bare `42` and the agent call all converge ([ADR-0003](0003-one-shared-path.md)).

**4. Targets the active view; multi-view targeting deferred.** Today `Geex.Session` owns one active
buffer + one view-local cursor, so "the view" is unambiguous — a view action targets the active view.
When panes/multiple frontends exist ([ADR-0028](0028-editor-shell-and-minibuffer.md) layout system,
~v0.3), view actions will need to name a target view; that reuses [ADR-0027](0027-grid-command-addressing.md)'s
`:N/` pane prefix. Deferred until panes exist — single active view now.

**5. Not recorded, and (for now) not journalled.** View actions carry no `%Command.Meta{}` and are not
recorded anywhere — they are fire-and-forget view mutations. If a session-level audit journal of *all*
invocations (including agent-issued view actions and operations) is later wanted, it is a **separate**
append-only log from per-buffer undo history (the persistence open question, [notes.md](../notes.md)
"Persistence & durable state") — not bolted onto undo. Flagged, not decided here.

## Consequences

- **The go-to-line hack becomes a real, discoverable, agent-callable command** — the first concrete win,
  and the model for `scroll` / `select` / a grid `goto x y` ([ADR-0027](0027-grid-command-addressing.md)).
- **The palette gets its non-edit navigation entries** ([ADR-0028](0028-editor-shell-and-minibuffer.md)):
  view actions render into `tools/list`, which the palette is a view onto.
- **The parity backlog shrinks** ([ADR-0028](0028-editor-shell-and-minibuffer.md) amendment §2): motion's
  *typed* form is now real (`line N` today; `goto`/`scroll` next), so cursor positioning exists on the
  typed surface without a literal per-chord twin.
- **The taxonomy is closed at four** — edit / read / operation / view-action cover text, query, world,
  and view; a new tool picks one by what it touches.
- **Costs / deferred:** `Geex.MCP.ViewActions` + the fourth `tools/call` branch + the `run_command`
  refactor are the build; multi-view targeting (the `:N/` prefix) waits for panes; a session journal is a
  separate, unresolved question; an agent moving the human's cursor is acceptable single-view but wants
  thought once multiple frontends share a session.
- **Status is Proposed** — the category and `line`-first are settled in direction by
  [ADR-0028](0028-editor-shell-and-minibuffer.md) §4, but the not-journalled call and the single-active-view
  targeting are open for review before this is Accepted and built.

## See

[ADR-0019](0019-file-lifecycle-and-operation-tools.md) (the operation-tool pattern this mirrors),
[ADR-0028](0028-editor-shell-and-minibuffer.md) (parity + the category's role in the palette),
[ADR-0027](0027-grid-command-addressing.md) (grid `goto`; the `:N/` pane prefix for multi-view),
[ADR-0029](0029-selection-primitive.md) (what `select` sets), [ADR-0014](0014-editor-state-and-dispatch-ownership.md)
(the view-local cursor), `lib/geex/loop.ex` (`run_command/1`, the hack to retire),
`lib/geex/mcp/operations.ex` (the sibling category), `lib/geex/session.ex` (`set_cursor/1`).
