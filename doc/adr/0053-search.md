# ADR-0053: Search: Alt+Q in the file, Alt+Shift+Q in the project, Alt+N the next match

- **Status:** Accepted 2026-11-12 (the maintainer's design, "all good"; not built yet)
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

## See

- `lib/geex/minibuffer.ex` (the `:search` mode), `lib/geex/loop.ex`, `lib/geex/shell.ex`,
  `lib/geex/loop/bindings.ex`, `lib/geex/command/catalog.ex`
