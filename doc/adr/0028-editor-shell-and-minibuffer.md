# ADR-0028: The editor shell — screen regions, the minibuffer, and the buffer/view/pane model

- **Status:** Accepted
- **Date:** 2026-06-08
- **Relates to:** [ADR-0027](0027-grid-command-addressing.md) (grid commands — the minibuffer's
  marquee mode), [ADR-0019](0019-file-lifecycle-and-operation-tools.md) (multi-buffer / `max_children`),
  [ADR-0009](0009-three-tier-extension-model.md) (extension / panel tiers), [ADR-0026](0026-terminal-input-model.md)
  (keymap — `Alt+M`, `Alt+WASD`), [ADR-0014](0014-editor-state-and-dispatch-ownership.md) (Session owns the
  `:minibuffer` / `:layout` placeholders), [ADR-0002](0002-commands-as-values.md) / [ADR-0003](0003-one-shared-path.md)
  (commands-as-values, the one shared path)

## Context

geex renders a **single full-screen buffer view** today: `Geex.Loop` composes the chrome we built
incrementally — a left-inset line-number gutter, the text area, a right-inset vertical scroll bar, and
two reserved bottom rows (a horizontal scroll bar + the status line). That was built ad hoc, but a
pattern emerged: **the frame is composed of regions reserved from its edges**, and the buffer renders
into what's left. That implicit model now wants a name, because the next features all add regions.

The open shell questions: **where does the user type commands** (`copy x5 y7`, [ADR-0027](0027-grid-command-addressing.md);
also search, ex-style commands)? **How many files open** — 4, more, unbounded? **Tabs** for open files?
A **menu bar** (File/Edit/Selection)? A **file tree**? `Geex.Session` already reserves two placeholders
for this future — `:minibuffer` (`%{mode, input, cursor}`) and `:layout` ("meaningful in v0.3 when panes
split"). And geex is LLM-native on **one shared command path** ([ADR-0003](0003-one-shared-path.md)): the
human's command surface should reach the *same* path an agent does.

## Decision

**1. The model & vocabulary — and regions are reservations.** Pin the terms: a **buffer** is a file's
content + history (`Geex.Buffer`); a **view** is a cursor/scroll/selection onto one buffer (`Geex.View`);
a **pane** is a frame *region* showing one view; a **tab** is a per-pane affordance to switch *which
buffer* a pane shows; the **frame** is the whole terminal. The frame is composed of **regions reserved
from its edges** — gutter = left inset, vertical bar = right inset, status + horizontal bar = bottom
rows, the minibuffer = a bottom row when active, panes = sub-rectangles of the remainder. Formalize the
"viewport-region math" already built into a small layout notion the loop carves; every new piece of
chrome is *additive* on it.

**2. The minibuffer is the next build, and it is the command surface.** A bottom-of-frame input line
that shares the status row (the status reverts when it closes). It is **modal**: grid commands
([ADR-0027](0027-grid-command-addressing.md)), incremental **search**, a **command palette**, and a
**fuzzy file/buffer finder**. Opened by **`Alt+M`** (primary) plus mode triggers (e.g. `/` for search, the
grid trigger). It is the human's door onto the **one shared path**: a `copy x5 y7` typed here becomes the
same `%Command{}` an agent emits over MCP/ACP ([ADR-0002](0002-commands-as-values.md) /
[ADR-0003](0003-one-shared-path.md)), and the palette and finder are just *command/target pickers* — free
because commands are values.

**3. No menu bar — a command palette instead.** Reject a File/Edit/Selection menu bar: it is
mouse-centric GUI convention (no serious TUI editor ships one) and redundant with the command surface.
Discoverability comes from the **command palette** — a minibuffer mode that fuzzy-lists and dispatches the
registered commands — keyboard-native and almost free given commands-as-values.

**4. File navigation: no small cap — navigate, don't limit.** Open as many buffers as you like; they are
cheap BEAM processes. The `max_children: 1024` of [ADR-0019](0019-file-lifecycle-and-operation-tools.md)
is a *safety ceiling*, **not** a UX number (and **not** 4). Scale by a **fuzzy switcher** over open
buffers + workspace files — not a hard limit, and not (initially) tabs.

**5. Tabs and the file tree are pane-level, deferred behind the pane system.** A tab switches a pane's
buffer; a file tree is a sidebar **panel**. Both need the **pane / layout system** (`Session`'s `:layout`
placeholder — the ~v0.3 milestone); until panes exist they have nowhere to live, and the fuzzy finder
covers the need. When they land: **tabs** as an *optional* per-pane affordance (the finder stays primary
when many files are open, e.g. agent-opened); the **file tree** as a **built-in panel** that the
extension/panel API may later also expose ([ADR-0009](0009-three-tier-extension-model.md)) — **not** an
extension *before* that panel API is mature (that would be backwards).

**6. The status bar is composable segments.** Left / center / right segment groups so features slot in
without redesign: filetype, encoding + line-ending (`LF`/`CRLF`), an LSP diagnostics count (when pharos
lands), search-match / selection-size counts, and a distinctly LLM-native **provenance / "agent editing"
indicator** — the one shared path made visible.

## Consequences

- **A coherent shell roadmap:** minibuffer **next** (unlocks the [ADR-0027](0027-grid-command-addressing.md)
  differentiator *and* the palette *and* the finder — i.e. it answers command-entry, file-navigation, and
  command-discovery at once), then the **pane/layout system** (unlocks file tree, tabs, splits), with
  **status segments** incremental as capabilities arrive.
- The region-composition we built ad hoc gets a name; the minibuffer and panes are additive on it.
- The human command surface and the agent command surface **converge on one path** — distinctive to geex,
  and the reason the minibuffer is high-leverage rather than just chrome.
- **Costs:** the pane/layout system is real deferred work; the minibuffer needs its modes plus the
  command-palette and finder indices.
- **Keymap:** **`Alt+M`** opens the minibuffer; movement is *also* bound to **`Alt+WASD`** as an
  arrow-key alternative (arrows aren't on every keyboard) — both per [ADR-0026](0026-terminal-input-model.md)
  (Alt is the secondary namespace; on tiling WMs Alt is often the mod key, so these stay remappable).

## Amendment (2026-06-08): the exit convention & keybinding↔typed-command parity

**1. Closing the minibuffer: `Esc`, `Alt+N`, and the typed `no`.** Three ways to back out,
all reaching `close/1`: `Esc` (conventional), `Alt+N` (the no/op chord, ADR-0026), and
**typing `no` + Enter** — the *typed twin* of `Alt+N`, same no/op mnemonic, for a user
whose hands are already on the keys. (`no` is reserved as a minibuffer cancel verb; it is
not a buffer-name or coordinate, so there's no clash.) Submitting any unrecognized empty
intent is a no-op close, not an error.

**2. The parity principle — capability parity, not literal per-key twins.** Every
*capability* reachable from the keyboard should also be reachable as a typed command on the
one shared path (§2), so a human and an agent drive the same verbs. But "twin" is at the
**capability** level, not a literal "every chord ⇒ a same-named command": the canonical
*typed* form of a capability may differ from its chord. The parity map (2026-06-08) shows
where this stands:

- **Edits already have parity** — typing / Enter / Tab / Backspace resolve to
  `insert`/`delete`/`replace`, the exact `%Command{}`s an agent emits (`keymap.ex`); the
  pair differs only in `Meta` provenance (`human` vs `llm`). This is the model to extend.
- **Motion's typed form is *addressing*, not "move-left".** Arrow / `Alt+WASD` / word /
  line-start-end chords are interactive *relative* motion; their typed twin is the
  **grid/`goto` absolute coordinate** ([ADR-0027](0027-grid-command-addressing.md)) and the
  `line N` view-action — you don't type "move left one", you type where to go. So parity
  here means "a typed way to position the cursor exists," satisfied by grid + `line`, not a
  literal twin per motion chord.
- **Gaps to close (the parity backlog):** **quit** has no typed verb (chords call
  `System.stop` directly — add a `quit`/`exit` command); the six **operation tools**
  (`save`/`open`/`close`/…) have no chords yet (`save` is already slated for **Ctrl-O** in
  [ADR-0026](0026-terminal-input-model.md) §1 — just unbuilt); and **go-to-line** is still a
  hardcoded hack in `loop.ex` rather than a registered view-action (see §4).

**3. Palette & highlight modes — the new minibuffer modes and their twins.** The palette
(§3) is opened by **`Alt+P`** *or* by typing **`palette`** / **`catalog`** at the `Alt+M`
prompt — the same widget in browse mode over the command catalog (the `tools/list` union),
not a new component. **Highlight mode** is entered by **`Alt+H`** or the typed
**`highlight`** / **`select`**, and exited the same way every mode is — `Esc` / `Alt+N` /
`no`. The **grid-line overlay** (the ADR-0027-amendment column-following aid) is a toggle
with both a chord and a typed twin (e.g. `grid`/`lines`), contextual to grid-command
composition. **`undo`/`redo`** are history-navigation verbs (not recorded `%Command{}`s) on
the keys **`Alt+B`** / **`Alt+Shift+B`** — `Alt+Shift+letter` is byte-distinct from
`Alt+letter` (ESC `B` vs ESC `b`), so it is deliverable on legacy terminals, unlike
`Ctrl+Shift+letter` (see [notes.md](../notes.md) "Editing & selection bindings").

**4. The view-action tool category — the mechanism for all of the above.** The typed twins
for motion/scroll/select/undo/`line N` need a home: a **fourth tool category** — *view
actions* — registered with field-specs like the operation tools, so they render into
`tools/list` (discoverable in the palette, callable by an agent) **without** being recorded
edits. Building it is what turns the `line N` hack into a real `line` command and gives the
palette its non-edit entries. This is a roadmap item ([roadmap.md](../roadmap.md), the
command-surface track), gated on the catalog/palette build; the parity backlog in §2 is
discharged as each verb lands in this category.

## See

[ADR-0027](0027-grid-command-addressing.md) (the grid commands the minibuffer hosts),
[ADR-0019](0019-file-lifecycle-and-operation-tools.md) (multi-buffer + the `max_children` ceiling),
[ADR-0009](0009-three-tier-extension-model.md) (the panel/extension tiers a file tree would use),
[ADR-0026](0026-terminal-input-model.md) (`Alt+M` / `Alt+WASD`), [ADR-0014](0014-editor-state-and-dispatch-ownership.md)
(`Session` `:minibuffer` / `:layout`), [ADR-0002](0002-commands-as-values.md) / [ADR-0003](0003-one-shared-path.md)
(why the palette/finder/grid all reduce to dispatching one kind of value), `lib/geex/session.ex`,
`lib/geex/loop.ex` (where the regions are composed today).
