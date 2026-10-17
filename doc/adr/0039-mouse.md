# ADR-0039: The mouse

- **Status:** Accepted 2026-10-17 (the maintainer's asks, with the coordinator session's
  additions, relayed by the coordinator session and built autonomously at the maintainer's word).
  Step 1 of 3: the foundation, in the file panes. **Amended 2026-10-17, step 2:** the rest of
  the screen clickable (§6), and Alt+click extends a selection (§3). Step 3 (resizing) amends
  [ADR-0038](0038-split-panes-and-tabs.md).
- **Date:** 2026-10-17
- **Relates to:** [ADR-0026](0026-terminal-input-model.md) (the terminal input model),
  [ADR-0027](0027-grid-command-addressing.md) (width never addresses), [ADR-0029](0029-selection-primitive.md)
  (the selection), [ADR-0015](0015-clipboard-subsystem.md) (the clipboard), [ADR-0034](0034-panes-tree-edits-hold.md)
  and [ADR-0038](0038-split-panes-and-tabs.md) (the panes, which deferred the mouse),
  [ADR-0035](0035-the-loop-never-waits.md) (the key loop never waits), [ADR-0036](0036-installed-binary.md)
  (restoring the terminal on every way out)

## Context

geex was keyboard-only: `Geex.Input.Parser` dropped mouse reports. With split panes, tabs, the
tree and the edits pane on screen, the maintainer wanted to use them with the mouse as well:
click to place the cursor, drag to select, scroll with the wheel, click the tree and the tabs,
and drag pane borders.

Taking the mouse has a cost: while an app has it, the terminal's own click-and-drag selection
(and so its copy) stops working.

## Decision

### 1. The terminal reports the mouse

- `Geex.TerminalIO` turns on mouse reporting when it starts: modes 1000 (presses and releases),
  1002 (moves with a button held) and 1006 (the SGR form). Not 1003 (every move): geex has no use
  for hover yet.
- It turns them off on every orderly way out, in `terminate/2`: Ctrl-X, `quit`, SIGTERM,
  `Geex.stop/0`, the installed binary's orderly stop. After SIGCONT it turns them on again, if
  they were on: a shell that took the terminal back while geex was stopped may have reset them.
  That matches the stty flags (BUG-3). It also turns off modes 1005 and 1015 (other encodings)
  when it starts, in case something left them on.
- A `kill -9`, or a halt that skips `terminate/2` (an `at_exit` hook doesn't run on a halt),
  leaves them on, as it leaves the alternate screen; `reset` clears both.
- **The `mouse` verb** (and the palette entry) turns reporting off, so the terminal selects and
  copies text itself again, and on. It is off until the next start; there is no setting to start
  with it off yet (ADR-0025's config layer).

### 2. The parser reads the reports

The SGR form `ESC [ < b ; x ; y M` (`m` for a release) is decimal, so coordinates past 223 (the old
form's limit) arrive whole. `Geex.Input.Parser` turns it into
`{:mouse, %{action, button, x, y, mods}}`: `action` is `:press`, `:release`, `:drag`, `:wheel` or `:move`;
`button` is `:left`, `:middle`, `:right`, the wheel's `:up`/`:down`/`:wheel_left`/`:wheel_right`,
or a number for buttons 8 to 11; `x` and `y` are 0-based; `mods` lists `:shift`, `:alt`, `:ctrl`. A
terminal that doesn't know mode 1006 sends the old `ESC [ M` and three bytes; those are read
too, so they never land in the buffer as text. A report whose rest is late (a slow link) is
waited for, not flushed as typed keys after the Esc timeout: nobody types `ESC [ <` or `ESC [ M`
(`Parser.mouse_report?/1`). Split right after `ESC [`, it can still be typed; a terminal writes a
report whole, so that needs a split in the middle of one write. A move with no button (mode
1003, not asked for) is `:move`.

### 3. In a file pane

- **A press** focuses the pane (from the tree or the edits pane too) and places the cursor. A
  screen column becomes a grapheme by the drawing's own width walk (`Geex.Width.col_at_display/2`,
  after the gutter and the horizontal scroll): both columns of a wide character land on it, a
  click past a line's end lands at the end, and below the text at the end of the last line.
  Commands still address graphemes (ADR-0027). The tab bar's row is §6.
- **A drag** selects from the press to the pointer, through the selection the keys use
  (ADR-0029), so `Alt+C`, `Alt+X`, `Alt+V` and typing over it work as they do with `Alt+H`. Held
  past the text's edge (above, below, or past the side), it scrolls a line or a column every 50
  ms until the pointer comes back or the button is let go.
- **Shift+press or Alt+press** extends the selection (or starts one at the cursor) to the pointer.
  Alt as well, since Windows Terminal keeps Shift+click for its own selection (§5); the
  coordinator session decided this for the maintainer.
- **A double-click** (the same cell within 400 ms) selects the word: a run of letters, digits and
  `_`, of spaces, or of other characters.
- **The wheel** scrolls the pane under the pointer, focused or not, 3 lines a notch; Shift+wheel
  or a sideways wheel scrolls 6 columns. It doesn't move the cursor, and the cursor may leave the
  view.
- **The scroll the mouse sets is kept** while the cursor stays where the mouse left it (a tab's
  `hold`, `Geex.Loop.Panes`). So a click near the bottom doesn't scroll the text by the
  scroll-off margin from under the pointer, and a wheel's scroll isn't undone on the next frame.
  The first key that moves the cursor brings it back into view.
- While the minibuffer is open, only its pickers take the mouse (§6); a release still ends a
  drag.
- Where an event lands is `Geex.Loop.Mouse`, pure. Nothing here waits on slow work (ADR-0035): a
  mouse event reads the tab's buffer snapshot, as a frame does.

### 4. Copying reaches the system clipboard

With the mouse taken, the terminal can't copy a selection, so `Alt+C` and `Alt+X` (and grid mode's
`copy` and `cut`) now also put the text on the system clipboard with **OSC 52**
(`ESC ] 52 ; c ; <base64> BEL`, `Geex.TerminalIO.copy/1`), as well as geex's own clipboard
(ADR-0015, unchanged). Nothing comes back: a terminal that doesn't support it, or refuses it,
ignores it. Text over 100 KB goes to geex's clipboard only, since terminals cap what they take.
geex doesn't read the system clipboard. Pasting with the terminal's own paste key still types the
text in.

### 5. Terminals

- **Windows Terminal** (the maintainer's) supports modes 1000/1002/1006 and OSC 52. With an app
  holding the mouse, **Shift+drag selects text in the terminal itself**, bypassing geex. So
  there, Shift+click may never reach geex: the terminal selects instead. Alt+click extends a
  selection in geex there. The `mouse` verb is the other way back to the terminal's own
  selection.
- **tmux** passes the mouse to geex whether its own `mouse` option is on or off, since geex asks
  for it. It takes OSC 52 only with `set -g set-clipboard on`; the default, `external`, ignores
  an app's.

### 6. Everything else clickable (step 2)

- **The tab bar** (`Geex.Loop.TabBar`, pure, so drawing and a click read one layout). A tab now
  reads ` N name × `. A click on a tab focuses its pane and shows it (the tab already shown keeps
  its selection). A click on its `×` closes it by `Alt+K`'s rules: refused while its buffer has
  unsaved edits and no other pane has it, without switching to it. A pane that isn't the only
  one shows its own ` × ` in the bar's last three columns. A click there closes the pane and its
  tabs, and a buffer no other pane has closes with it. That is refused while one of those buffers
  has unsaved edits; the pane's tabs stay as they were. The pane you were in stays current
  unless it is the one closing. The only pane has no `×` and never closes. A pane too small to
  draw takes no click.
- **The tree**: a click on a row highlights it and does what Enter does: a folder opens or
  closes, and a file opens in the current file pane, which gets focus. The second press of a
  double-click on a folder does nothing, so the folder stays open. Its title focuses it. The
  wheel scrolls it, 3 rows a notch, and leaves the highlighted row. The scroll holds until a key
  acts on the list or the list is focused (`Alt+P`); then it shows the highlight again
  (`list_view/4`). A click on a folder keeps the scroll. Keys now scroll the list only as far as
  keeps the highlight in view; before, Up from the bottom row scrolled at once.
- **The edits list**: a click on an entry opens it, as Enter does: the entry drawn there, even
  if a newer edit arrived since. Its title focuses it; the wheel scrolls it, as the tree's
  does.
- **The pickers** (the palette, the buffers, the finder): the wheel moves the highlight a row a
  notch, not wrapping. A click on a row runs that row: it is the row you saw, even while the
  finder's newer search is still running. A click off the list closes the picker. The other
  minibuffer modes (typed commands, grid) take no mouse.
- **The status line**: a click on "behind disk (Alt+J)" fast-forwards.
- The dividers take no click yet; step 3 makes them handles.

### Out of scope (deferred)

- Step 3: resizing panes by dragging.
- Middle-click paste, a right-click menu, triple-click, dragging by words after a double-click,
  dragging the scroll bars.
- Starting with the mouse off (a setting).

## Consequences

- The terminal's own click-and-drag selection needs Shift (Windows Terminal, most others) or
  `mouse`.
- Every tab carries `hold`; a frame keeps a tab's scroll while its cursor equals it.
- A `kill -9` leaves the terminal reporting the mouse: a shell then shows the reports as text
  until `reset`.

## See

- `lib/geex/terminal_io.ex` (`set_mouse/1`, `copy/1`, `osc52/1`), `lib/geex/input/parser.ex`,
  `lib/geex/loop/mouse.ex`, `lib/geex/loop.ex` (`apply_mouse/2`, `press/4`, `drag_to/1`,
  `drag_scroll/1`, `wheel/4`, `draw_pane/6`), `lib/geex/loop/panes.ex` (`hold`).
- `lib/geex/loop/tab_bar.ex`, `lib/geex/loop/panes.ex` (`close_pane/2`), `lib/geex/loop.ex`
  (`region/3`, `tab_bar_press/4`, `close_pane/2`, `tree_press/3`, `edits_press/3`,
  `status_press/2`, `picker_mouse/2`, `pick/2`, `settle_lists/3`).
- `test/geex/loop/mouse_test.exs`, `test/geex/loop/mouse_click_test.exs`,
  `test/geex/input/parser_test.exs` ("mouse reports").
