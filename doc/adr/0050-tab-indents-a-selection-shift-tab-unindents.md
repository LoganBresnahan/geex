# ADR-0050: Tab indents a selection, Shift+Tab un-indents, Alt+backtick the other kind

- **Status:** Accepted 2026-11-11 (the maintainer's ask; built on the branch `indent-keys`,
  accepted at the maintainer's word the same day)
- **Date:** 2026-11-11
- **Amends:** [ADR-0026](0026-terminal-input-model.md) (its 2026-11-10 amendment: Shift+Tab
  inserted the other kind of indent; `` Alt+` `` read), [ADR-0045](0045-typing-assists.md) §3
  (what Tab and Shift+Tab do), [ADR-0047](0047-every-key-runs-a-named-command.md) §2 (`indent
  other` is no longer Shift+Tab's own command; `unindent` is)
- **Relates to:** [ADR-0029](0029-selection-primitive.md) (the selection), roadmap item 18.1
  (typing over a selection), [ADR-0049](0049-ijkl-default-keys.md) (every Alt letter is taken)

## Context

Tab inserts one indent level at the cursor, as the file indents (ADR-0045 §3), and does the same
with a selection live: the selection is ignored, since `Keymap.over_selection/1` left Tab out
("indenting a selection is its own decision"). Shift+Tab inserts the other kind of indent, a tab
where Tab gives spaces and the reverse (ADR-0026's 2026-11-10 amendment). That amendment turned
down Shift+Tab as un-indent because geex had none, and noted that if selections got indent and
un-indent, they could have Tab and Shift+Tab.

The maintainer, 2026-11-11: "when we highlight and then hit tab it should tab over and then
shift+tab can unindent it", always, not only with a selection; the other kind moves to
`` Alt+` ``. `Alt+Tab` and `Alt+Shift+Tab` were ruled out: the desktop takes both to switch
windows (roadmap item 19: "`Alt+Tab` … never reaches a terminal on Windows or most desktops"),
and where a terminal does pass one, `ESC ESC [ Z` can't be told from Esc then Shift+Tab.

## Decision

**1. Tab with a selection indents its lines.** With a selection live (not collapsed), Tab
inserts one indent level, as the file indents, at the start of every line the selection touches,
and the selection stays, so Tab again indents again. The lines are the selection's first through
its last, except a last line the selection only reaches at column 0 (a drag down to the start of
a line, which selects the lines above it). A blank line (empty, or only spaces and tabs) is left
alone, so no trailing whitespace is added.

**2. Shift+Tab un-indents, always.** It takes one level from the start of every line the
selection touches, or of the cursor's line with no selection: a leading tab, or leading spaces
back to the previous tab stop (the tab size's spaces, or fewer to reach a stop), as Backspace in
leading spaces already does (ADR-0045). A line with no leading whitespace is left alone; when no
line has any, nothing changes and nothing is recorded. The cursor and the selection move left
with their text, never past the line's start.

**3. One edit.** Indenting or un-indenting lines is one recorded command on the shared path, one
`Alt+Z`: a replace from the first changed line's start to the last's end. Blame marks the lines
between the first and last changed, as for any hunk (`Geex.Blame`): an empty or unindented line
between them is marked too.

**4. A selection's ends follow their text.** An end on a changed line moves by what was inserted
or taken there, except an end at column 0, which stays at 0, so a selection of whole lines stays
whole lines.

**5. `` Alt+` `` inserts the other kind.** The command `indent other` (ADR-0047 §2) keeps its
name and loses Shift+Tab; `` Alt+` `` runs it, the key above Tab on most keyboards. With no
selection it inserts the other kind at the cursor, as Shift+Tab did; with one, it indents the
selection's lines with the other kind, as Tab does with its own. The parser reads `` ESC ` `` as
`` Alt+` ``, beside `Alt+;` (ADR-0049 §3): no sequence starts with it. Where `` ` `` is a dead
key (several European layouts), `` Alt+` `` may not arrive, nor on desktops that take it to
switch between one application's windows (GNOME's default, KDE's); `indent other` is still typed
in `Alt+M`, and remapping (roadmap 20.3) moves it.

**6. Named.** Shift+Tab's own command is `unindent` (aliases `outdent`, `dedent`), typed in
`Alt+M` and listed in the palette and the Commands tab; Tab's stays `indent`. Typed, each acts as
its key does in the editor (ADR-0047 §6), selection and all.

Elsewhere nothing changes: the tree, the panes, the settings view and the minibuffer ignore
Shift+Tab, as before.

## Consequences

- Tab and Shift+Tab work as in most editors: VS Code, Sublime, JetBrains.
- Un-indenting counts characters, not columns: on a line of mixed indent, spaces before a tab
  (`" \tx"`) go first, a press that moves nothing on screen though it is recorded, and a tab
  before spaces (`"\t x"`) goes whole, past the previous stop. VS Code measures the width and
  rewrites the indent; rare enough here to wait (mod-verify's review, 2026-11-11).
- Undo after Tab drops the selection, as undo always does, so a further Tab doesn't indent the
  same lines again.
- A selection no longer ignores Tab. Typing a tab over a selection, replacing it, is gone; delete
  the selection first.
- Shift+Tab with no selection used to insert; now it removes. The other kind is `` Alt+` ``.
- Every Alt letter is now taken or kept (ADR-0049), so new defaults come from the symbol keys:
  `` ` ``, `'`, `/`. `[`, `]` and `\` can't be read as Alt chords: each starts a sequence.

## See

- `lib/geex/loop/keymap.ex` (the indent and un-indent of lines, pure), `lib/geex/loop.ex` (Tab,
  Shift+Tab and `indent other` in the editor), `lib/geex/loop/bindings.ex`,
  `lib/geex/input/parser.ex`
