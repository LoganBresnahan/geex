# Changelog

What each release of geex changed, for someone using it. Newest first. Each entry names the
decision record (`doc/adr/`) or the bug (`doc/bugs.md`) behind it. Install or upgrade with
`geex self update`, or see [doc/install.md](doc/install.md).

## 0.8.0 — 2026-11-23

### Added

- **Clickable output.** In the output pane, a `path:line` or `path:line:col` that names a file
  is underlined as a link: a click opens the file there, and `Alt+N` steps through the links,
  wrapping. The files are checked in the background as the output arrives, so drawing and
  stepping through the links never waits on a slow disk; opening one looks only at its file
  (ADR-0042's 2026-11-23 amendment).
- **Enter opens tsc's errors.** Enter (or a click) on `src/a.ts(3,5): error TS2322: …`, the form
  `tsc` prints without a terminal, opens the file at line 3, column 5 (ADR-0042's 2026-11-13
  amendment).
- **Replace.** `replace TEXT` replaces the file search's matches in this file, and `replace-all
  TEXT` the project search's matches in every file it listed, each after a y/n and as one undo
  step per file; `save-all` writes every file with unsaved changes (ADR-0053's amendment).
- **Each agent in its own colour.** Each agent session's edits get a colour of their own in the
  gutter and the edits pane (ADR-0032's amendment).
- **An agent's shell commands credited.** With the captAInHook payload registered on
  `pre-tool-use` too, a file an agent's Bash command changed is credited "changed while" that
  command ran, never "by" it; and every revert shows what it will take back before it does
  (ADR-0032's and ADR-0033's 2026-11-18 amendments).
- **Symlinks and dot folders in the file tree.** A symlinked folder is listed one level at a time
  as you open it, and folders such as `.github` show outside a git repository too (BUG-24, BUG-25,
  ADR-0034's amendment).
- **Saving off the key loop.** A save writes in the background: you can keep typing, and what you
  type during the save stays unsaved. Quitting waits for a save under way (ADR-0035's
  amendments).
- **Quitting with unsaved edits.** The first quit names the unsaved files, and a second leaves
  (ADR-0035's 2026-11-15 amendment).
- **Home and End** go to the top and the bottom of the file; the motion keys and Delete work in
  the command line (ADR-0049's amendment).

### Fixed

- One file that hung (a stalled network disk, a FIFO in a file's place) could stall every file
  call in geex and leave no key working; geex no longer goes through OTP's file server for your
  files, and never opens a FIFO (BUG-22).
- Stopping geex on a disk that hung could take 22 s, or forever; it now ends within 10 s
  (BUG-21).
- Closing the terminal ended geex at once and could cut a save's write; a save now finishes
  (BUG-20).
- A rename into a directory that isn't there reported success and left the file where it was
  (BUG-19).
- A first save that trimmed every line's trailing whitespace stalled for seconds (BUG-18).
- The markdown preview couldn't render a file holding a byte that isn't UTF-8 (BUG-16).
- `search-project` crashed through a link to a name past Latin-1 (BUG-23).
- One `Alt+N` over a project search's results could look at the disk once per result line,
  holding the keys on a slow disk (BUG-26).

### Known

- Stopping a `!` command on a busy machine can end it with KILL rather than TERM (BUG-27), and
  keys typed while the screen is stalled can arrive together, so Esc then a letter reads as
  Alt+letter (BUG-28). Both are open.

## 0.7.0 — 2026-11-13

- **Search.** `Alt+Q` searches the file, selecting the match as you type; `Alt+Shift+Q` searches
  the project into the output pane (`search-all` searches everything, a setting choosing which
  one `Alt+Shift+Q` runs); `Alt+N` goes to the next match or opens the next result (ADR-0053).
- Command names of more than one word are hyphenated, with an argument after a space
  (`search-all needle`, `select-all`) (ADR-0047's amendment).
- `!!` after a restart runs the last `!` command kept in the history (ADR-0042's amendment).
- Fixed: a long line holding an emoji or © before an invalid byte froze every key on it (BUG-17).

## 0.6.0 — 2026-11-12

- **Keys you can move:** every key runs a named command, listed in the Keys tab of `Alt+Y`
  (ADR-0047). **The default keys changed** to an IJKL motion cluster (ADR-0049); the palette ranks
  name matches first (ADR-0048).
- Tab indents a selection and Shift+Tab un-indents (ADR-0050); the panes on `Alt+<` and `Alt+>`
  (ADR-0051); editing keys: duplicate, select a character, word or line, the matching bracket,
  comments, moving lines and text (ADR-0052).
- Undo and redo by what one action did (ADR-0031's amendment); trailing whitespace trimmed on
  save, on by default (ADR-0054).
- Fixed: long lines cost the whole line on every key and frame (BUG-12, BUG-13); an invalid byte
  on screen, or undoing an agent's MCP edit, could crash (BUG-14, BUG-15).

## 0.5.0 — 2026-11-09

- **Editor comfort:** typing over a selection, `[+]` that follows the text, a resizable output
  pane, an optional final newline on save, a scrolling tab bar, `Alt+Y`'s Commands tab, resizing
  panes from the keyboard, and the last session brought back.
- **Typing assists:** brackets and quotes closed as you type them, Enter keeping the indent, an
  "Indent with" setting, bracketed paste (ADR-0045).
- Fixed: a tab drew zero columns wide (BUG-10); input went deaf after a byte that isn't UTF-8
  (BUG-11); an attestation missed undone edits, or a compacted ledger's blame (BUG-8, BUG-9).

## 0.4.0 — 2026-11-06

- **Markdown preview:** a read-only rendered preview of a markdown file beside it, redrawn when
  the file changes (ADR-0043). It needs the `markdown_inline` grammar from the catalog.
- From 0.4.0 the Apple silicon build may need macOS 15 (ADR-0041's amendment).
- Fixed: stale text after a terminal resize (BUG-7).

## 0.3.0 — 2026-10-19

The first geex you can install: a tarball per platform with its own Erlang, installed by
`curl … | sh` (Linux x64 and arm64 with glibc 2.35+, macOS on Apple silicon), no Erlang needed
(ADR-0041). geex ships with no grammar and no theme; `geex install` and `Alt+Y` add them from the
catalog (ADR-0040).

- 0.3.1: a build for Intel Macs.
- 0.3.2: `geex self update`, `rollback`, `prune` and `uninstall`.
- 0.3.3: install.sh points Windows users at WSL; stale attestation files are removed.
- 0.3.4: files created, deleted and renamed from the editor and the file tree (ADR-0019's
  amendment); `open PATH` from the project root; shell commands from the command line: `!`, `!!`,
  `|`, with a history (ADR-0042).
- 0.3.5: each release carries the captAInHook payload, linked at
  `~/.local/share/geex/integrations/geex-attest.sh` (ADR-0041's amendment).
- 0.3.6: a `!` command flooding output no longer swamps geex (ADR-0042's amendment).

## 0.2.0 and 0.1.0 — 2026-10-18

No geex was published at these versions: the v0.2.0 and v0.1.0 tags hold the first catalogs of
grammars and themes (v0.2.0 added fourteen themes), and geex was built from source. Catalog
releases are tagged `catalog-v<N>` since (ADR-0040, ADR-0041).
