# ADR-0038: Split panes, each with its own tabs

- **Status:** Accepted 2026-10-17 (the defaults the maintainer accepted, relayed by the
  coordinator session; built autonomously at the maintainer's word). **Amended 2026-10-17:**
  splits keep a ratio, and the mouse resizes them (§6). **Amended 2026-10-18:** an edge dragged
  up and down shows `⠛⠛` (§6). **Builds** what
  [ADR-0034](0034-panes-tree-edits-hold.md) deferred ("splits and tabs") and
  [ADR-0028](0028-editor-shell-and-minibuffer.md) put "behind the pane system".
- **Date:** 2026-10-17
- **Relates to:** [ADR-0014](0014-editor-state-and-dispatch-ownership.md) (the cursor is
  view-local; Session holds the active buffer), [ADR-0034](0034-panes-tree-edits-hold.md) (the
  tree, the edits pane, `Geex.Layout`, more than one buffer), [ADR-0037](0037-pane-and-file-keys.md)
  (the pane and file keys), [ADR-0026](0026-terminal-input-model.md) (Alt chords and what
  terminals take), [ADR-0032](0032-listener-first-agent-integration.md) (the frozen MCP surface)

## Context

geex showed one buffer at a time: the editor rectangle beside the tree and above the edits pane,
and `buffers` to switch. The maintainer wanted to see files side by side, the way an IDE does,
and to keep several files open per pane as tabs.

## Decision

### 1. The model

- **File panes split the editor's rectangle.** A split is two halves, top and bottom (`:rows`)
  or side by side (`:cols`), each a pane or another split (`Geex.Layout.split/2`, pure). A new
  split is even; side-by-side halves keep one column for a `│` divider. (Since the amendment, a
  split carries its ratio: §6.)
- **Each pane has its own tabs** and shows one of them. A tab is a buffer seen from that pane:
  its own cursor and scroll. **The same file in two panes is one buffer**: one text, one undo
  history, one ledger. An edit from anywhere (you in another pane, an agent, reconcile) shows in
  every pane that has the file, because the loop watches every buffer in a tab.
- **The current pane** is where keys go when the editor has focus and where a file opens. It
  stays current while the tree or the edits pane has focus.
- `Geex.Loop.Panes` holds all of this as a pure value; `Geex.Loop` draws it.

### 2. "The active buffer" is the current pane's shown tab

Session keeps its one active-buffer pointer and its view cursor, and the loop keeps them pointed
at the current pane's shown tab. So the keymap, the typed verbs, saving, undo, fast-forward and
**the frozen MCP surface** act on what you are looking at, unchanged. The loop owns the other
tabs' cursors: before it makes another tab current it copies Session's cursor into the tab it
leaves, and after, it sets Session to the new tab and its cursor.

Session's active buffer can also change from outside the loop (an agent's `open_file`, the
`buffers` picker): the loop shows that buffer in the current pane, in its tab there or a new one.
An event Session has already moved past is ignored, so two quick switches can't bring the first
back. Session gained one call, `close_buffer/1`, to close a buffer without picking another.

### 3. Keys, verbs and the palette

| Key | Verb | Action |
|---|---|---|
| `Alt+-` | `split` | split the current pane top and bottom |
| `Alt+=` | `vsplit` | split it side by side |
| `Alt+,` / `Alt+.` | `tab prev` / `tab next` | the previous / next tab, wrapping |
| `Alt+1`..`Alt+9` | `tab N` | tab N, as the tab bar numbers them |
| `Alt+K` | `close` | close the tab (below) |
| `Alt+O` | `open` / `find` | open a file as a tab in the current pane, or switch to its tab there |
| `Alt+P` | — | the next pane: the tree, each file pane in reading order, the edits pane |

- The new pane from a split shows the same tab (its own cursor and scroll from then on) and
  becomes current. A split is refused ("no room to split this pane") when a half would be under
  12 columns or 4 rows, and a pane with no tabs isn't split. A pane a resize leaves under 3×3
  isn't drawn until there's room again.
- `geex a b c` opens the files as tabs a, b, c in the first pane, `a` shown
  (`Geex.Loop.open_tabs/1`).
- `split`, `vsplit`, `tab next` and `tab prev` are in the palette.
- **Not `Alt+[` or `Alt+\`**: `ESC [` starts a CSI and `ESC \` is ST. The parser now reads
  `ESC` + a digit, `-`, `=`, `,` or `.` as Alt chords. ADR-0026 lists Alt+digit as something
  some terminals take (GNOME Terminal's tab switching); the maintainer's terminal, Windows
  Terminal, binds `Ctrl+Alt+digit` and `Alt+Shift+-`/`Alt+Shift+=` by default, not these, and the
  verbs cover any terminal that does.

### 4. Closing

`Alt+K` closes the current tab, and the pane shows the tab before it:

- a buffer still in another tab or pane stays open ("closed the tab; it is still open in
  another pane");
- otherwise the buffer closes too, **refused while it has unsaved edits**;
- **a pane left with no tabs closes**, and the pane that takes its space becomes current;
- **the only pane** never closes: its last tab closes to the buffer shown before it (Session's
  `close_active/0`), or a new scratch buffer.

A buffer that ends some other way (an agent's `close_file`, a crash) leaves every tab it was in,
by the same rules: each pane shows the tab before, and if that empties the only pane, it shows
another open buffer or a new scratch one.

The loop's own opens (`Alt+O`, `open PATH`, the tree, the edits pane, the buffer picker) show the
tab in the same step as the open, not when Session's event comes back, so a key typed right after
acts on the tab you see. A notice from a buffer you aren't looking at names its file.

### 5. Drawing

Each pane is drawn on a screen of its own and copied into the frame (`Geex.Screen.blit/4`):

- **a tab bar on its top row**: each tab numbered with its file name and ` [+]` for unsaved
  edits (and, since [ADR-0039](0039-mouse.md) §6, a `×` per tab and one per pane). The shown tab is tinted, in reverse video in the focused pane. Tabs that don't fit are
  cut from the left so the shown one stays visible;
- **the text, gutter and scroll bars** as before, with grid mode's ruler (ADR-0027) in the
  current pane only;
- **the status line** (the bottom row) for the current tab, as before.

The hardware cursor is the current pane's. Another pane showing the same buffer keeps its own
cursor, clamped to the text if an edit elsewhere shortened it.

### 6. Amendment (2026-10-17): splits keep a ratio, and the mouse resizes them

Built with the mouse's step 3 ([ADR-0039](0039-mouse.md)):

- **A split is `{dir, a, b, ratio}`**: the first half takes `ratio` of the room (a side-by-side
  split's room is its width less the divider). A new split is `0.5`, which lays out as the even
  split did, except where the even split would make a pane below the least size. `Geex.Layout`
  keeps each half at least as big as the panes in it need, 12 columns and 4 rows a pane
  (`Layout.min_pane/0`); short of room for both, the least sizes shrink in proportion, so
  neither half collapses before the other. The ratio stays as it was, so a terminal resize keeps
  the proportions.
- **Handles**, drawn `⠿` at first (one column in any font; not East Asian ambiguous width). **Amended
  2026-10-18** (the maintainer's choice, relayed by the coordinator session): the same grip
  turned, 4 dots along the edge and 2 across. An edge dragged left and right (a divider, the
  tree's edge) shows `⣿` (U+28FF); one dragged up and down (a stacked split's bar, the edits
  pane's title) shows `⠛⠛` (U+281B twice), two columns, the same as the bar's hit area. Each is
  one constant (`Geex.Loop.TabBar.handle/1`), so swapping a glyph is a one-line change. The
  edits pane's title centres its two columns, as it centred one:
  - a side-by-side split: its divider column, the glyph in the middle;
  - a stacked split: the top row of its lower half, where the tab bars have no tab and no `×`.
    Each of those bars keeps the glyph and a space just before its pane's `×`
    (`Geex.Loop.TabBar`), so the handle stays there however many tabs the bar holds, and the
    glyph is drawn where the hit test takes it;
  - the tree's right edge, the glyph half way down;
  - the edits pane's title row, the glyph in the middle of its rule, between its name and its
    hint.
- **Dragging a handle** puts the edge under the pointer: a split's ratio (`Layout.ratio_at/3`,
  kept to the least sizes, `Panes.set_ratio/3`), the tree's width (at least 12, leaving the
  editor 40 columns or what its panes need, `Layout.least/1`) or the edits pane's height (at
  least 2 rows, leaving the editor 6 rows or what its panes need). A drag whose split changed
  under it (a pane closed) ends. The tree's and
  edits pane's sizes are stored as laid out, so they stay what you see across a resize, clamped
  to the terminal.
- **A double-click on a handle** puts it back: an even split, or the tree's and edits pane's
  default sizes.
- A press on the edits pane's title still focuses it, on the tree's edge the tree, and on a
  stacked split's handle the pane it is on.
- A double-click needs both presses on the same kind of thing: a handle dragged away leaves
  text, or a blank tab bar, where it was, and a press there isn't its second click.
- Closing a pane keeps the other splits' ratios; the split it was in goes.

### Out of scope (deferred)

- **The mouse**: clicking a tab or a pane, dragging a divider. (Built in
  [ADR-0039](0039-mouse.md): clicks on panes, tabs and their `×`; dragging a divider is its step 3.)
- **Resizing panes by hand**: splits stay even. (Built: §6.)
- **Keeping the layout across restarts**: geex starts with one pane (and, since §6, even, with
  the tree and the edits pane at their default sizes).
- **Moving a cursor in a pane you're not in when an edit elsewhere shifts its line**: it stays at
  its line and column, clamped to the text.

## Consequences

- A tab bar costs every file pane one row, including the only pane.
- Each frame reads one snapshot per pane (the current tab's from Session), so two panes on the
  same large file read it twice.
- `Geex.Loop`'s single-buffer fields (`buffer`, `scroll`, `hscroll`, the per-buffer scroll map)
  are gone; tabs carry scroll, and `watched` holds every tab's monitor and reactor.
- Session's model is unchanged; one pointer, read by everything that acts on "the" buffer.

## See

- `lib/geex/loop/panes.ex`, `lib/geex/layout.ex` (`split/2`, `dividers/2`), `lib/geex/loop.ex`
  (`adopt_active/2`, `leave/1`, `enter/1`, `put_panes/2`, `draw_pane/6`, `draw_tab_bar/5`,
  `do_close/1`), `lib/geex/session.ex` (`close_buffer/1`), `lib/geex/input/parser.ex`.
- `test/geex/loop/panes_model_test.exs`, `test/geex/loop/split_test.exs`.
