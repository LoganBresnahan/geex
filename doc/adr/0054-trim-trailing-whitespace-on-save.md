# ADR-0054: Trim trailing whitespace on save

- **Status:** Accepted 2026-11-12 (the maintainer's ask, accepted at their word); built the same
  day on the branch `save-undo`
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
only if the write succeeds, so a failed save leaves no edit behind. It is one `:human` replace from
the first changed line's start to the last's end, applied with the final line break as one group
(a step of at most two commands, one `Alt+Z`, ADR-0031's 2026-11-12 amendment), so a save costs
the document once however many lines it trims; blame marks only the lines that changed
(ADR-0032's 2026-11-12 amendment). Lines are trimmed by grapheme: a space a Prepend character
joins to (`x؀ `) is one grapheme with it, not trailing whitespace, and a line left as it was makes
no command. (Built first as one command per line, which mod-verify's review found quadratic: a
20,000-line save took 29 s.) The frozen MCP `save_file` writes the text as it is.

**5. The cursor.** A cursor past a trimmed line's new end goes to that end.

**As built.** The loop decides whether a save trims: the setting, and the file kind by
`Keymap.trims_on_save?/1` (beside the indent table), passed as `trim_trailing_whitespace:` through
`Reconcile.save/2` to `Buffer.save/2`, which makes the edits: the trim as one replace (§4), then
the final newline worked out on the trimmed text, applied together as one `History.group/3`; a
newline with nothing to trim is dispatched alone, as before. The extension check ignores case
(`.PATCH`). The cursor needs nothing of its own: the loop's clamp puts it at a trimmed line's end.

## Consequences

- Saving a file someone else wrote with trailing whitespace changes those lines, and blame credits
  them to you. Turn the setting off for a repository that keeps trailing whitespace.
- A Markdown file's hard line breaks survive; a Markdown file's other trailing spaces stay too.
- A save of a file with nothing to trim makes no edit and records nothing.

## See

- `lib/geex/buffer.ex` (`save/2`), `lib/geex/reconcile.ex` (`save/2`), `lib/geex/loop/settings.ex`,
  `lib/geex/loop.ex`
