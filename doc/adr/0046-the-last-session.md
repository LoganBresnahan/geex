# ADR-0046: The last session — a project's panes, tabs and sizes kept across restarts

- **Status:** Accepted 2026-11-09 (the maintainer's ask, roadmap item 18.9; built and reviewed
  then, recorded as an amendment to [ADR-0038](0038-split-panes-and-tabs.md)). Recorded as an
  ADR of its own 2026-11-10, at the maintainer's word: it is a subsystem with its own module,
  state file and startup behaviour, not a detail of split panes. Nothing here changes what was
  built; ADR-0038's amendment points here.
- **Date:** 2026-11-10
- **Relates to:** [ADR-0038](0038-split-panes-and-tabs.md) (the panes and tabs kept; it deferred
  "keeping the layout across restarts"), [ADR-0034](0034-panes-tree-edits-hold.md) (held buffers:
  unsaved edits come back with their ledgers), [ADR-0033](0033-durable-ledger.md) (the file-key
  scheme, the state directory), [ADR-0035](0035-the-loop-never-waits.md) (writes off the key loop),
  [ADR-0036](0036-installed-binary.md) / [ADR-0041](0041-release-without-burrito.md) (how `geex`
  starts, `Geex.CLI`, `Geex.stop/0`), [ADR-0040](0040-bare-geex-and-the-catalog.md) §7 (settings,
  which this is not)

## Context

The maintainer opens geex with `geex .` and wanted it to come back as it was left: the files
open, the panes and their sizes. ADR-0038 had deferred that. It is state geex writes on its own
(not settings the user chooses, ADR-0040 §7), it changes what starting geex does, and it has to
be written without stalling the key loop and without being lost on a quit.

## Decision

1. **What is kept** (`Geex.LastSession`, pure `encode/4`, `decode/1`, `panes/2`): the file
   panes, each one's source tabs (the file's absolute path, its cursor and its scroll) and which
   is shown, the current pane, the split with its ratios, and the tree's width and the band's
   (edits or output pane) height. Not kept: markdown preview tabs, buffers with no file (scratch),
   the tree's and edits pane's shown state (settings own those), the selection, the undo history
   (the ledger owns it).
2. **Where:** `$XDG_STATE_HOME/geex/sessions/<key>.json`, `<key>` the first 16 hex digits of the
   sha256 of the project root (as ADR-0033 names ledgers), `0600` in a `0700` directory, written
   whole (a temp file, fsynced, renamed). A file that doesn't decode (another version, a hand edit,
   a relative path) is no session. App gate `session_memory` (off under test), `sessions_dir`
   overrides.
3. **Starting** (`Geex.open_paths/1`):
   - a bare `geex`, or `geex DIR`, brings the project's last session back when one was kept: its
     files are opened (one after another, as `geex a b c` opens its files), and the loop is handed
     the panes they rebuild (`{:geex_restore, …}`). A file gone since, or that won't open, is left
     out, and a pane left empty gives its room to its sibling. With none kept, a bare `geex` is a
     scratch buffer as before, and `geex DIR` starts keeping one;
   - `geex FILE …` opens just those files, takes the remembered sizes, and keeps only sizes: it
     never replaces the files a project session kept, nor a session file it can't read.
4. **Keeping** (the loop): one writer process per loop (`LastSession.writer/1`, monitoring the
   loop) writes in the order it is sent. Every 2 s, if the session changed (for a `geex FILE`
   session, only its sizes) and no write is on its way, it is sent; it counts as kept only when
   the writer says it was written, so a failed write is tried again, and a failure is logged once
   (`geex session: …`). On a quit the loop always writes and waits (at most 2 s) for it, after any
   write still on its way.
5. **Restoring** reopens each file through `Session.open_file/1`, so its ledger replays and unsaved
   edits come back as ADR-0034 holds them.

## Consequences

- A project opened with `geex .` comes back as it was left; geex has one more state file.
- **Known limits:** a `geex FILE` instance writes the sizes by reading the file and writing it
  back, unlocked, so with a project instance open at once one's write can be lost until its next
  change; SIGTERM stops without asking the loop (`Geex.CLI.Signals`), so the session is as last
  kept, at most 2 s old while writes succeed (older after a failed one, retried each tick); restored files open one after another at startup, so a very large file
  slows every bare `geex` until it is closed; a file that can't be opened at start is forgotten
  at the next keep.

## See

- `lib/geex/last_session.ex`, `lib/geex.ex` (`open_paths/1`, `last_session/1`, `restore/1`,
  `remember/1`), `lib/geex/loop.ex` (`handle_info({:geex_restore, …})`, `keep_session/2`,
  `quit/1`), `lib/geex/session.ex` (`root_of/1`).
- `test/geex/last_session_test.exs` (encode, JSON and decode give back the panes, as a property).
