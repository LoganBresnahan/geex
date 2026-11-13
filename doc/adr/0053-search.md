# ADR-0053: Search: Alt+Q in the file, Alt+Shift+Q in the project, Alt+N the next match

- **Status:** Accepted 2026-11-12 (the maintainer's design, "all good"; not built yet). **Amended
  2026-11-13:** the maintainer's answers before building (`search all`, a setting, the highlights,
  the prompt, project search's scope), and mod-verify's design notes
- **Date:** 2026-11-12
- **Amends:** [ADR-0028](0028-editor-shell-and-minibuffer.md) (the minibuffer's search mode,
  "incremental search is the next mode"), [ADR-0042](0042-shell-commands.md) (the output pane
  holds a project search)
- **Relates to:** [ADR-0049](0049-ijkl-default-keys.md) (`Alt+Q` and `Alt+N` kept for find),
  [ADR-0029](0029-selection-primitive.md) (the match is the selection),
  [ADR-0035](0035-the-loop-never-waits.md) (the loop never waits on slow work)

## Context

ADR-0049 kept `Alt+Q`, `Alt+Shift+Q` and `Alt+N` unbound for finding text. The maintainer,
2026-11-12: "alt+q should goto and highlight the found match and then alt+n moves the cursor to
the next occurance and keeps the new occurance highlighted but not the old (b/c we don't have
multi cursor atm)", "alt+shift+q for whole repo search could probably run a commandline find (or
whatever) and the results pop up in our terminal output pane", and "alt+q can just use the
minibuffer to type in … same with alt+shift+q". Multiple cursors (and `Alt+Shift+N`, which would
add the next match to them) wait for their own ADR.

## Decision

**1. `Alt+Q`: `search`.** Opens the minibuffer with the prompt `search:`. As the query is typed,
the first match at or after where the search started (wrapping past the end) becomes the
selection, and the view follows it. Enter closes the minibuffer and keeps the match selected; Esc
puts the cursor and the selection back as they were. With no match the selection clears and the
prompt says `no match`. Opened with a selection on one line, the query starts as its text.

**2. The match is the selection.** So typing replaces it, `Alt+C` copies it, Tab indents its line:
nothing else is needed to change what was found.

**3. `Alt+N`: `next match`.** The next match after the cursor, wrapping at the end of the file
with a notice (`wrapped to the top`), becomes the selection; the old one is no longer selected.
It finds the last search's query; with none, a selection's text; with neither, a notice names
`Alt+Q`. There is no previous match key: `Alt+N` wraps.

**4. The query.** Plain text, compared grapheme by grapheme, so a match always starts and ends
on a grapheme boundary. Smart case: a query with no capital letter matches either case; one with
a capital matches exactly. A match may not cross a line end. The minibuffer keeps the queries, as
it keeps commands (ADR-0042 §5), in their own list.

**5. What else shows.** The other matches on screen are drawn in a dim highlight, and the status
line says `3 of 12`. Searching runs in a monitored process (ADR-0035): the loop draws the match
and the count when they arrive, and drops an answer for a query or a text that has since changed.

**6. `Alt+Shift+Q`: `search project`.** Opens the minibuffer with the prompt `search project:`.
Enter runs `git grep -n -I -F` (with `-i` by §4's smart case) for the query in the project root,
through `Geex.Shell`, as `!` runs a command (ADR-0042): the results fill the output pane, Enter on
a line opens the file at it, and Ctrl+G stops it. The query is quoted for the shell. Outside a git
repository it runs `grep -rnI -F` instead.

**7. `Alt+N` after a project search** goes to the output pane's next result: it opens that file
at the line and selects the match there. `Alt+N` follows whichever search ran last; `Alt+Q` makes
it the file's again.

**8. Named.** `search`, `search project` and `next match`, typed in `Alt+M` and listed in the
palette. `open` keeps its alias `find`.

## Consequences

- A project search's line numbers are the files' on disk; a buffer edited since may have moved
  its lines, as a compiler's output can.
- No regular expressions and no replace-all yet; a match being the selection covers replacing one
  at a time.
- `Alt+Shift+N` stays unbound until multiple cursors have an ADR.

## Amendment — 2026-11-13: decided before building

**Context.** Before building, the plan went to mod-verify, whose sixteen questions the maintainer
answered ("accept all, document 15"), with the maintainer's own four: may a slice be committed on
the branch (yes, merging waits for the maintainer), the other matches' colour, `Alt+N` in the
prompt, and project search's scope ("the default should skip common dirs but we should allow the
user to search all as well … perhaps another setting"). mod-verify's seventeen design notes (R1–R17)
are written in where they decide behaviour.

**Decision.**

1. **The highlights and the count stay until Esc or a new search**, as Vim's `hlsearch`, and
   follow edits: a change searches again off the loop, the superseded search stopped, not only its
   answer dropped (R6). While the prompt is open, the count shows at its end
   (`search: foo   3 of 12`), since the prompt covers the status row.
2. **Enter on an empty prompt repeats the last query**; an empty query is no search: the start is
   restored, nothing is "no match" (R4). **Esc puts back the scroll too**, not only the cursor and
   the selection. **`Alt+N` in the prompt goes to the next match and keeps the prompt open.**
3. **One last query, for every file**: `Alt+N` in another file finds it there. **`Alt+Q` from the
   tree, a pane or a preview searches the last file pane.**
4. **One history list**, `"search"`, for both prompts (ADR-0042 §5's file); a query that isn't
   valid UTF-8 isn't kept in it (the file is JSON; R2), though it is searched for.
5. **A one-line selection pre-fills both prompts**, project search too, byte for byte: a Latin-1
   file's bytes are searched for as they are, drawn `�` (BUG-15). The minibuffer addresses its
   input through `Geex.Text` and keeps at most 4,096 graphemes of a pre-fill (R1).
6. **Where matches are and where `Alt+N` goes** (R3, R4): the matches are each line's leftmost
   non-overlapping occurrences from the line's start (`aa` in `aaaa` is at 0 and 2), never across
   a line end; the text is split into lines before it is segmented, so a CRLF line's `\r` is no
   part of a match (R5). The count, `Alt+N` and the highlights use that one set. `Alt+N` goes to
   the first match at or after the selection's end (in document order) or the cursor; the search
   as it is typed starts from the selection's start, so the pre-filled occurrence is match 1.
7. **Smart case** (R11): a capital is a grapheme that lowercasing changes (so `ǅ` and the Kelvin
   sign count); folding lowercases each grapheme, never uppercases (`ß` would become `SS`), and
   offsets are never carried from a lowercased line back to the original (lowercasing can change a
   grapheme's bytes). `é` precomposed and `é` as `e` plus a combining accent don't match each other
   (graphemes are compared as they are; `git grep` agrees).
8. **The other matches** are drawn in a theme's `search` style, an overlay like the selection's so
   no syntax colour beats it; a theme without one gets a dim form of its selection colour, and the
   terminal's own colours (where the selection is reverse video) get underline (R16).
9. **Project search's scope.** `search project` searches the files git tracks and the untracked
   ones it doesn't ignore (`git grep --untracked`, as the tree lists them), and outside git
   `grep -r` leaving out `.git`, `_build`, `deps`, `node_modules`, `target`, `dist` and `.venv`.
   **`search all`** searches everything: ignored files and those directories too. A General setting
   chooses which one `Alt+Shift+Q` runs (`search project` by default) until remapping (roadmap 20.3)
   binds any key to either. Outside git, a project root of `~` or `/` is refused with a notice,
   not walked.
10. **Project results.** `git grep` runs with `-c core.quotePath=false`, and its lines are read by a
    parser of their own (a path with spaces or non-ASCII letters), not the output pane's general
    one (R13); its `--column` is a byte offset and isn't used. The output pane keeps the first
    5,000 result lines and says so (it keeps a command's newest lines otherwise). `Alt+N` stops
    once per result line, selecting its first match, and puts the cursor at the line's start with a
    notice when the line has none in the buffer (an unsaved edit, a decomposed accent `git grep`
    matched by bytes: R14). When a later `!` command replaces the results, `Alt+N` searches the file
    again. The query is quoted for the shell (`'…'\''…'`); one holding a NUL byte is refused; exit
    status 1 is "no match" (R15).
11. **Case folding in project search follows the system's locale** (Q15): under a UTF-8 locale `-i`
    folds every letter, under the bare `C`/`POSIX` locale only A–Z, so `café` misses `CAFÉ` there.
    It isn't forced: not every system has `C.UTF-8`.
12. **Caps Lock with `Alt+q` runs `search project`** (`Alt+Shift+Q`), as Caps Lock turns the motions
   into the moves (ADR-0052 §8): an `Alt+Shift` letter with its own command no longer falls back to
   the plain letter (R17).

**Consequences.** Search answers arrive from a monitored task keyed by the buffer, the text's
sequence and the query (ADR-0035), the first match before the count on a big file (R7); presses of
`Alt+N` while an answer is pending are counted and applied when it comes (R8); a buffer changed
under an open prompt is searched again (R9). These are slice B's; slice A is the pure core
(`Geex.Search`) and the minibuffer and history fixes above.

**As built, slice B (2026-11-13, search in the file).**
- `Alt+Q` and `Alt+N` are bound (`search`, `next match`); `Alt+Shift+Q` falls back to `Alt+Q`
  until slice C binds it, and `Alt+Shift+N` to `Alt+N` until multiple cursors take it.
- The loop keeps one search: the last query (every file's), whether its matches show, the
  matches of `{buffer, seq, query}` (`Geex.Search`'s packed set), the task running and what its
  answer selects: the n-th match at or after a place, with the buffer, the cursor and the selection
  as the key left them. A text up to 16 KB with a query of up to 64 graphemes is searched in the key
  itself (measured for short queries: at most 1.4 ms on the slowest text; the scan compares every
  grapheme of the query, so a 4,000-grapheme query took 217 ms on 16 KB, hence the query limit); a
  bigger one in a monitored process that sends the first match, then every match. A newer search
  stops the one it replaces.
- An answer still to come selects only if the same buffer is in view and the cursor and the
  selection are as the key left them; after Esc, a motion or another file it is kept (for the
  count, the highlights and the next `Alt+N`) and selects nothing (mod-verify's review).
- A selected match puts the cursor at its end. An emptied query puts back what was there; no match
  clears the selection and puts the cursor back where the search started.
- The matches follow the text and the file in view: before each frame, a search whose key no longer
  fits (an edit, another tab) starts again; with the prompt open it selects again from where it
  started.
- The other matches take the palette's `search` colour (a theme's `"search"`, else halfway from
  its background to its selection; the terminal theme with a known background half its selection
  shade), underlined where there is none. The cursor's line tints only cells on the editor's
  background, so a match on it still shows.
- `Esc` in the editor also stops showing the matches. The status line shows the count while they
  show; the prompt shows it at its end with "wrapped to the top".
- From a panel, `Alt+Q` searches the current file pane; from a preview, the pane it was opened
  from.

**As built, slice C (2026-11-13, project search).**
- `Alt+Shift+Q` runs `search project`, or `search all` when the General setting ("Alt+Shift+Q")
  says so; the setting is kept as `search_key` and rebinds the chord, so the help shows it. Both
  are minibuffer modes (`search project:`, `search all:`), pre-filled from a one-line selection
  (Q9), keeping their queries in the file search's history list (Q8); an empty prompt runs the
  last project query again.
- The command (`Geex.Search.Project`): in git, `git -c core.quotePath=false grep -n -I -F [-i]
  --untracked -e QUERY -- .` with `:(exclude,glob)**/DIR/**` for `.git _build deps node_modules
  target dist .venv` (tracked or not, at any depth); `search all` adds `--no-exclude-standard` and
  excludes nothing. Outside git, `grep -rnI -F [-i] --exclude-dir=DIR … -e QUERY .`, or plain
  `grep -rnI` for `search all`; both refused from the home directory or `/` (Q16). The query is
  quoted `'…'\''…'`, always after `-e` (so `-n` is a query, not an option); one holding a NUL byte
  is refused (R15). A query that isn't UTF-8 (a Latin-1 selection) gets no `-i`: git refuses such a
  pattern under it, and an invalid byte matches only itself, as in the file's search.
- **Case folding follows the locale** (Q15): `-i` folds every letter under a UTF-8 locale, only
  A–Z under the bare `C`/`POSIX` one (`café` misses `CAFÉ` there); not forced.
- It runs through `Geex.Shell` into the output pane, as `!` does (Ctrl+G stops it), with a new
  `:first` option: the first 5,000 lines are kept, none passed over, and the command is stopped
  once they came (Q12); the pane's title and a notice say "the first 5000 lines". Exit status 1
  with no lines is "no matches", said so, not a failure.
- Results are read by a parser of their own (`locations/1`): every `path:line` a result line could
  name, the first naming a file under the root taken, so a space, an `é` or a colon in a path
  reads right (R13). `--column` isn't used (it counts bytes).
- `Alt+N` after a project search opens the next result line (one stop per line, Q13), from the
  top the first time (or from the highlight when it was moved), wrapping with "wrapped to the
  first result"; it selects the line's first match by the same smart case, or puts the cursor at
  the line's start with a notice when the line has none in the buffer (an unsaved edit, bytes git
  matched, R14). Enter on a result line in the output pane does the same. When a `!` has replaced
  the results, `Alt+N` is the file's search again (Q14); `Alt+Q` makes it so too.
- **Caps Lock with `Alt+q` runs `Alt+Shift+Q`'s command** (R17), as with the moves (ADR-0052 §8).
- The title says "1 line" for one result.
- **Decided overnight, pending the maintainer** (mod-verify's review of slice C, the
  coordinator's call):
  - **Outside git, grep runs in the C locale** (`LC_ALL=C`): under a UTF-8 locale GNU grep takes a
    file holding a byte that isn't UTF-8 for binary, and `-I` skips it without a word, so a Latin-1
    file was never searched. The cost: outside git `-i` folds only A–Z, so `café` misses `CAFÉ`
    there, as under a `C` locale in git (Q15).
  - **The refusal follows symlinks** (a link to the home directory is the home directory) and
    covers any directory above the home directory too (`/home`). **A home directory kept in git**
    (a dotfiles repository) isn't refused: it is searched without `--untracked`, its tracked files
    only (untracked there is everything else in the home directory), and a notice says so.

## Amendment — 2026-11-13: a result goes to the pane that has its file

The maintainer, trying the merged build with two file panes side by side, each showing a file
with a match: `Alt+N` opened the other pane's file again as a tab in the current pane, instead of
going over to the pane that showed it.

**A result's file opens where a file pane already has it** (`Panes.holding/2`): the current pane
when it has a tab of the file, else the first pane, in reading order, that shows it, else the
first that has it in a tab behind another, whose tab is then shown. That pane becomes the current
one, and nothing is opened again. A file no pane has opens in the current pane, as before. This is
`Alt+N` through the results and Enter on a result line alike; other opens (`Alt+F`, `open PATH`,
the tree, a markdown link) still open in the current pane. A preview tab doesn't count as having
the file.

## See

- `lib/geex/search.ex` (the pure matching core), `lib/geex/minibuffer.ex` (the `:search` mode), `lib/geex/loop.ex`, `lib/geex/shell.ex`,
  `lib/geex/loop/bindings.ex`, `lib/geex/command/catalog.ex`
