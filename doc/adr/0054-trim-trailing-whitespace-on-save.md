# ADR-0054: Trim trailing whitespace on save

- **Status:** Accepted 2026-11-12 (the maintainer's ask, accepted at their word; not built yet)
- **Date:** 2026-11-12
- **Amends:** [ADR-0019](0019-file-lifecycle-and-operation-tools.md) (its 2026-11-09 amendment, a
  final newline on save: a save makes one more edit), [ADR-0040](0040-bare-geex-and-the-catalog.md)
  §7 (a new General setting)
- **Relates to:** [ADR-0031](0031-undo-redo-history-operations.md) (its 2026-11-12 amendment: undo
  by step), [ADR-0045](0045-typing-assists.md) (defaults by the kind of file, as Tab's indent),
  [ADR-0050](0050-tab-indents-a-selection-shift-tab-unindents.md) (what a blank line is)

## Context

The maintainer, 2026-11-12, reviewing a move that carried a line's trailing spaces along: "we need
another setting that can be on or off, on by default, and that is when a user saves it trims ending
whitespace on all lines", with "sensible defaults kinda like how we handle tab for makefiles and go
files". geex already makes one edit as it saves: the final line break, when that setting is on
(ADR-0019's 2026-11-09 amendment).

## Decision

**1. A General setting, on by default.** "Trim trailing whitespace on save"
(`trim_trailing_whitespace` in `settings.json`, ADR-0040 §7), beside "final newline on save",
toggled in `Alt+Y`'s General tab. Missing from the file, it is on.

**2. What a save trims.** Every line's trailing spaces and tabs, edited or not, before a CRLF line's
`\r` (which stays). A line of only spaces and tabs becomes empty. A form feed or a no-break space is
text, as for Tab (ADR-0050 §1), and stays.

**3. Files left alone whatever the setting**, the way a Makefile gets tabs whatever it says
(ADR-0045): Markdown (`.md`, `.markdown`, `.mdx`), where two trailing spaces are a line break, and
diffs and patches (`.diff`, `.patch`), where trailing whitespace is content. The list is a table by
extension beside the indent table.

**4. A recorded edit, made as the save writes.** As the final line break is: made inside the buffer
in the same step as the write (`Buffer.save/2`), after the save has caught up with the disk, kept
only if the write succeeds, so a failed save leaves no edit behind. It is one `:human` command per
changed line, applied as one group, so blame marks only the lines that changed and one `Alt+Z`
gives every space back (ADR-0031's 2026-11-12 amendment). With the final line break also on, both
are the same step. The frozen MCP `save_file` writes the text as it is.

**5. The cursor.** A cursor past a trimmed line's new end goes to that end.

## Consequences

- Saving a file someone else wrote with trailing whitespace changes those lines, and blame credits
  them to you. Turn the setting off for a repository that keeps trailing whitespace.
- A Markdown file's hard line breaks survive; a Markdown file's other trailing spaces stay too.
- A save of a file with nothing to trim makes no edit and records nothing.

## See

- `lib/geex/buffer.ex` (`save/2`), `lib/geex/reconcile.ex` (`save/2`), `lib/geex/loop/settings.ex`,
  `lib/geex/loop.ex`
