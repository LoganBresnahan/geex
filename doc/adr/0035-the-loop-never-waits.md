# ADR-0035: The key loop never waits on slow work

- **Status:** Accepted 2026-10-16 (proposed by the coordinator session; the maintainer took
  "adopt the rule, park the rest"); amended 2026-10-18 (a frame costs the screen, not the
  file). First instance built: the file tree's reader (`6a6e3df`,
  [ADR-0034](0034-panes-tree-edits-hold.md)'s 2026-10-16 amendment).
- **Date:** 2026-10-16
- **Relates to:** [ADR-0028](0028-editor-shell-and-minibuffer.md) (the shell and its loop),
  [ADR-0034](0034-panes-tree-edits-hold.md) (the tree, read in the background),
  [ADR-0014](0014-editor-state-and-dispatch-ownership.md) and
  [ADR-0033](0033-durable-ledger.md) (the buffer owns the one history), and the sacred invariant
  "the terminal belongs to the renderer"

## Context

`Geex.Loop` is one process. It takes every key and builds every frame, so anything it calls and
waits on stalls typing. `6a6e3df` showed how badly: with the tree's 10,000-file cap gone, geex
opened in the home directory (937,594 files) froze the loop for 18–60 s while the tree was read.
Reading it in a monitored process fixed that: the editor took keys 0.8 s after launch while the
tree filled in.

The maintainer asked what else in geex could use more than one process. The coordinator session
read the code. Already concurrent: one process per buffer, the highlight reactor (asynchronous,
newest result wins, crash-isolated), the renderer, the reconcile watcher, a Bandit process per
attestation, and now the tree's reader. It proposed a rule and four places still inline in the
loop; this session measured them first.

## Decision

### 1. The rule

`Geex.Loop` does no slow work inline. **Slow** means work whose cost grows with something the
person at the keyboard doesn't control: a file's size, the number of files, a history's length, an
external program. Such work runs in a process of its own:

- **Monitored, not linked.** If it crashes, the loop logs it, says so in a notice, and carries on.
  It doesn't retry by itself in a way that crashes again on the next frame.
- **The loop keeps going.** It keeps taking keys and shows what it has, such as "reading…" or the
  rows from the last read, then draws the result when it arrives.
- **One answer counts.** An answer from a process the loop no longer waits on (a superseded read
  or search) is ignored.

### 2. Applied when a real case measures slow

This is not a rewrite of the loop. A place moves off the loop when a real file or repository
makes it measurably slow (the named-consumer rule). New features that are slow by nature, like
search across files, start that way.

### 3. Limits

- **One history per buffer.** Edits to one buffer stay serialized through its history. Background
  work that changes a buffer goes through the buffer, and edits to that buffer wait or queue
  while it runs.
- **Only the renderer writes to the terminal.** Workers send results to the loop; they never draw.

### 4. Measured and parked

Measured on 2026-10-16 with `MIX_ENV=test` in a scratch directory, with a real `git merge-file`.
Each is parked in the roadmap until a real case hits it:

- **Save and fast-forward** run in the loop: they read the file, and a save with changes on both
  sides runs `git merge-file`. A clean merge and save took 93 ms on a 1 MB file and 759 ms on
  10 MB; a fast-forward took 29 ms and 445 ms. Source-sized files take a few milliseconds. Moving
  them needs a "saving…" status, and edits to that buffer queue meanwhile (§3).
- **Opening a file** replays its ledger in `Buffer.init/1` while the loop waits: 9 ms with
  1,000 entries, 137 ms with 10,000 (`mix geex.ledger compact` shortens one). Opening runs no
  git; `git rev-parse` runs once at launch (`Session.set_start/1`). `geex a b c` could also start
  its buffers in parallel.
- **Reconcile** handles disk changes one file at a time, in its own process, so it never blocks
  typing. Handling each file in parallel (each buffer reading its own file) would only make the
  "behind" marks of a 50-file rewrite land sooner.

### 5. New work it makes cheap (not decided)

- **Project search:** files searched in parallel (`Task.async_stream`), results streamed into a
  pane as they're found; a new query kills the old search.
- **Git status marks on tree rows**, from a background process refreshed by the watcher's events.
  This is groundwork for the diff view.
- **Idle housekeeping:** `Ledger.compact`, and highlighting buffers that aren't shown.

## Consequences

- A huge root, file or history costs time or memory, never the editor's responsiveness. The tree
  shows the trade: about 500–900 MB of memory with the home directory loaded, and keys live
  throughout.
- Each place moved off the loop gains a waiting state ("reading…", "saving…") and a message
  protocol, which tests can drive without a terminal (deliver the worker's answer to
  `Loop.handle_info/2`, as `panes_test` does).
- Until a place is moved, it still blocks; §4 lists the known ones and their costs.

## See

- `6a6e3df` (the tree's reader); `lib/geex/loop.ex` `reload_tree/1` and the `{:geex_tree, …}` and
  `DOWN` clauses; `test/geex/loop/panes_test.exs`.
- [roadmap.md](../roadmap.md), command surface item 9 (the parked candidates).
- [testing.md](../testing.md), 2026-10-16 entries (the measurements and the coordinator's live check).

## Amendment (2026-10-18): a frame costs the screen, not the file

**Context.** The maintainer found every key slow in `lib/geex/loop.ex` (141 KB, about 28,000
highlight spans). The loop did work in proportion to the whole file on every frame, inline:

- `Paint.to_screen` walked every grapheme of the file (686,000 of them) to reach the visible
  rows;
- it built a byte → style map over every span in the file, not just the visible ones;
- `Loop.max_line_width/1` split the whole text and measured every line;
- `Loop.line_count/1` split the whole text;
- `Reactor.render/1` copied all 28,000 spans into the loop's mailbox.

Measured in-process (no terminal), one frame took 323 ms, and Down plus its frame took 1,388 ms.

**Decision.** This is the rule's other half. Work that grows with the file doesn't move to another
process here: it stops happening. A frame does work in proportion to what the screen shows.

- **Paint walks only the visible rows.** `Paint.visible_lines/3` takes their bytes out of the text
  using the newline offsets from one native scan (`:binary.matches/2`). Styles are resolved only
  for spans overlapping those bytes.
- **The reactor sends only the visible spans.** `Reactor.render/3` takes a byte window. The
  reactor indexes each overlay once, off the loop (`Geex.Highlight.SpanIndex`: spans sorted by
  start, plus the longest span's length), and answers with a binary search. The loop asks for the
  rows it shows, after it has decided where they scroll to.
- **The loop's whole-text measures get cheaper.** `line_count/1` counts newline offsets.
  `max_line_width/1` measures lines longest-in-bytes first and stops once no line left can be
  wider (a line's width is at most its byte length: a two-column glyph takes three or four bytes).

**Measured** on loop.ex, highlighted, at 120 × 40, in-process:

| | Before | After |
|---|---|---|
| a frame | 323 ms | 9 ms |
| Down and its frame | 1,388 ms | 10 ms |
| a typed character and its frame | — | 14 ms |
| a tab switch and its frame | — | 9 ms |

A typed character alone costs 0.2 ms, and `render/3` 0.01 ms. What's left is the frame's own
`Screen` building and diffing, in proportion to the screen.

**The guard.** `test/geex/loop/frame_cost_test.exs` paints a highlighted ~420 KB file (loop.ex
three times, about 84,000 spans) from its middle, through `Loop.handle_info/2`. It times a frame,
Down plus a frame, and a typed character plus a frame. The best of five runs must be under 150 ms.
The old code took 1,264 ms there, and the new code about 10 ms, so the bound has room for a loaded
machine and still catches a regression.

**Not done** (only if a real file needs it):

- The `max_line_width/1` scan still runs over the whole text on every frame. It is native and
  stops early, but a single very long line still makes it measure that line.
- Tree-sitter reparses the whole file on each edit, off the loop. Incremental reparse and a
  query restricted to a byte range would need changes to the NIF.
