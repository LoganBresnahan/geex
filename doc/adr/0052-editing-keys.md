# ADR-0052: Editing keys: duplicate, select a word or a line, the matching bracket, comments, moving text

- **Status:** Accepted 2026-11-12 (the maintainer's keys, "all good" with `Alt+7`/`8`/`9` for
  selecting; built the same day on the branch `editing-keys`; merged to main 2026-11-12 after four
  mod-verify passes)
- **Date:** 2026-11-12
- **Amends:** [ADR-0026](0026-terminal-input-model.md) (`Alt+\` and `Alt+:` read),
  [ADR-0050](0050-tab-indents-a-selection-shift-tab-unindents.md) (its note that `\` can't be read
  as an Alt chord), [ADR-0051](0051-panes-on-alt-angle-brackets-digits-free.md) (`Alt+2`, `Alt+7`,
  `Alt+8` and `Alt+9` get commands)
- **Relates to:** [ADR-0029](0029-selection-primitive.md) (the selection),
  [ADR-0045](0045-typing-assists.md) (the bracket pairs), [ADR-0047](0047-every-key-runs-a-named-command.md)
  (every key runs a named command), [ADR-0049](0049-ijkl-default-keys.md) (the motion cluster)

## Context

geex edits text a character at a time: it has no key to duplicate a line, select a word or a
line, jump to a bracket's pair, comment a line out, or move a line. The maintainer, 2026-11-12:
"duplicate a line could be alt+2", highlighting "the whole line regardless of where the cursor
is", then "alt+7 highlights a character, alt+8 word, alt+9 line", "jump to matching bracket could
be alt+\",
"for toggling comments we can just alt+/", and for moving, "alt+shift+ijklh;uo … the ability to
move it via our navigation rules. this would also work for an entire highlighted section". On
what moves with nothing selected: "whole line" for up and down, and "alt+shift+jklh;uo should
only function for highlighted text".

## Decision

Each command below is one recorded edit on the shared path (one `Alt+Z`), or a motion, and has a
name typed in `Alt+M` (ADR-0047). Each does nothing, and records nothing, where it has nothing to
act on. In the preview each gives the read-only hint (a move is its motion there, §8); the
tree, the panes, the pickers and the settings view ignore the edits.

**1. `Alt+2`: `duplicate`.** The cursor's line, or every line the selection touches (as Tab
counts them, ADR-0050 §1), is copied below itself. The cursor or the selection moves to the copy,
at the same columns, so `Alt+2` again copies the copy.

**2. `Alt+7`, `Alt+8`, `Alt+9`: a character, a word, a line.** Three keys side by side, each
selecting a bigger piece.

- **`Alt+7`: `select character`.** Selects the character (grapheme) at the cursor; at a line's
  end, the line break. With a selection live, it takes in one more character.
- **`Alt+8`: `select word`.** Selects the word the cursor is in, or the next word on the line when
  it is between words, or, with none after it, the one before it. A word runs from space to space,
  as `Alt+U`/`Alt+O` jump, punctuation and all: in `foo(bar, baz)` the words are `foo(bar,` and
  `baz)` (the maintainer, 2026-11-12: "both should just jump from space to space"). With a
  selection live, it extends the selection to the end of the
  next word, on a later line if this one has none.

Each extends from the selection's start, whichever way it was made: the selection runs from its
start to the new end.

**3. `Alt+9`: `select line`.** Selects the cursor's whole line, from its start to the start of the
next line (the last line: to its end), wherever the cursor is in it. With a selection live, it
takes in its lines whole and the next one. A
selection of whole lines is what Tab, Shift+Tab, `duplicate` and the moves act on.

**4. `` Alt+\ ``: `matching bracket`.** On a bracket (`(`, `[`, `{` or its closer), or just after
one, the cursor goes to its pair; elsewhere, to the opening bracket of the nearest pair around it.
Brackets are counted in the plain text, one kind at a time, so one inside a string or a comment
counts too (the syntax tree can tell them apart later). It looks at most 10,000 lines or 200,000
characters each way, so a long line (minified code, a log) costs no more than many short ones
(ADR-0035); a pair farther than that isn't found. Searching backward, a long line is read from
its end: by bytes when it is ASCII, else only its last 800 KB, and the search ends there. The
cursor's own line is read from the cursor, by bytes when it is ASCII up to it (BUG-12, fixed
2026-11-12: far into a 2 MB line a press took up to 0.9 s, now a few milliseconds). With a
selection live it extends, as a motion does. The
parser reads `ESC \` as `` Alt+\ `` outside a terminal's string reply: `ESC \` ends one (ST), and
the parser reads a reply whole, so outside one nothing else sends it.

**5. `Alt+/`: `comment`.** Comments out the cursor's line or the selection's lines with the file's
line comment (`#`, `//`, `--`, `;`, `%` …), or takes it off when every non-blank one has it. Adding
puts `marker ` after the indent the lines share, so the markers line up: the smallest indent when
the lines indent alike, and where they part when they mix tabs and spaces (column 0 for one line
of spaces and one of a tab), so no marker lands inside another line's indent. Blank lines (only
spaces and tabs, as Tab has it, ADR-0050) are left alone. Taking off removes the marker and one space after it. The marker comes from a table in
geex keyed by the file's extension and name (`Makefile`, `Dockerfile`), as the typing assists
read a file's kind (ADR-0045): no grammar need be installed. A language with only block comments (HTML, CSS) or none known says so in a notice and
changes nothing. `.s` (GNU as) takes `#`, `.asm` (NASM) `;`.

**6. `Alt+Shift+I`/`Alt+Shift+K`: `move up`, `move down`.** The cursor's line, or the selection's
lines, swap with the line above or below. The cursor and the selection move with them. Each line
keeps its place's ending (a CRLF file stays CRLF). The empty line after a file's final line break
isn't one to swap with, so a moved line never takes the file's last line break with it. The one
cost: in a file with no final line break, a move that leaves an empty line last (the last line
moved up past an empty line, or a block ending in an empty line moved down past the last line)
leaves the file ending in a line break, and can't be moved straight back.

**7. `Alt+Shift+J/L/U/O/H/;`: moving selected text sideways.** With a selection on one line, the
selected text moves within its line:

| Key | Command | The selected text |
|---|---|---|
| `Alt+Shift+J` / `Alt+Shift+L` | `move left` / `move right` | moves one character; the character it passes goes to its other side |
| `Alt+Shift+U` / `Alt+Shift+O` | `move word back` / `move word forward` | swaps with the word before or after it; what lies between stays |
| `Alt+Shift+H` / `Alt+Shift+;` | `move to line start` / `move to line end` | goes to the start (after the indent) or the end of the line; the text it passes keeps its spacing, the gap between them |

The selection stays on the text, its anchor and cursor ends as they were. With no selection, or
one across lines, these do nothing. A word is as `Alt+8` has it, space to space; a selection
inside a word swaps with the word's other part. In `one two three` with `three` selected,
`Alt+Shift+U` gives `one three two`; in `  foo bar` with `foo` selected, `Alt+Shift+;` gives
`  bar foo`. Text already after the indent goes no farther. A word or line-end move takes the
selection's words, not spaces at its ends: those stay where they are, so `Alt+S`, `Alt+O` on
`bar` (which takes `bar `) and then `Alt+Shift+O` turns `foo bar baz` into `foo baz bar`, and the
selection is the words alone after. Only spaces after the text means it is at the end already. A CRLF line's `\r` is no part of the
line here: nothing takes it or passes it.

**8. Caps Lock.** A terminal sends `Alt+K` with Caps Lock on as it sends `Alt+Shift+K`. Before
this, an `Alt+Shift` letter with no binding fell back to the plain letter, so Caps Lock didn't
matter. With the moves bound, Caps Lock turns the motion cluster into the move cluster: a way to
move text without holding Shift (the maintainer: "it might [be] useful for some if they don't want
to hold down shift"). `Alt+Z` takes each move back. Where there is no text to move (the tree, the
edits and output panes, the pickers, the settings view, the command line, a preview) a move is
its motion, so Caps Lock moves the highlight there as before.

**9. Read.** `` Alt+\ `` (`ESC \`) and `Alt+Shift+;` (`ESC :`) join the parser's symbol chords.
`Alt+Shift+O` arrives as `ESC O`, how an SS3 starts; the parser already reads `ESC O` with no
final byte after it as `Alt+Shift+O` (ADR-0049's SS3 fix), and `ESC O` with a letter in the same
read stays ambiguous, as it was.

## Consequences

- The free `Alt` digits are `Alt+3`, `Alt+4`, `Alt+6` and `Alt+0`; `Alt+5` is kept for multiple
  cursors, which have no ADR yet.
- Every `Alt+Shift` letter in the motion cluster now has its own command; an accidental Caps Lock
  moves text instead of the cursor (§8).
- `comment` knows only the languages in its table; a grammar's catalog entry could carry its
  marker later.
- `matching bracket` can be fooled by a bracket inside a string or a comment.
- A word is one thing everywhere: `Alt+U`/`Alt+O`, `Alt+8` and the word moves all go from space to
  space, so `foo(bar,` is one word. Selecting `bar` alone takes `Alt+7`s or `Alt+S` and a motion.

## See

- `lib/geex/loop/keymap.ex` (the pure edits and motions), `lib/geex/loop.ex`,
  `lib/geex/loop/bindings.ex`, `lib/geex/input/parser.ex`, `lib/geex/command/catalog.ex`
