# ADR-0035: The key loop never waits on slow work

- **Status:** Accepted 2026-10-16 (proposed by the coordinator session; the maintainer took
  "adopt the rule, park the rest"); amended 2026-10-18 (a frame costs the screen, not the
  file); amended 2026-11-12 (a long line costs its screen, not the line: BUG-12, BUG-13); amended
  2026-11-15 (a save leaves the key loop and the buffer; a quit waits for it and names unsaved
  edits); amended 2026-11-16 (shutdown during a save: a second quit leaves within 1 s, cutting a
  write that hangs; SIGTERM, SIGHUP and the terminal closing let a save finish for up to 30 s).
  First instance built: the file tree's reader (`6a6e3df`,
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

## Amendment (2026-11-12): a long line costs its screen, not the line (BUG-12, BUG-13)

**Context.** The 2026-10-18 amendment made a frame cost its rows. A file with one 2 MB line (a
minified bundle, a log line) still cost the whole of that row: with the cursor near its end a
repaint took about 2.3 s, a word motion or `Alt+\` up to 0.9 s, a typed character about 1 s. Each
walked the line from its start a grapheme at a time: the paint placed all 2.1 million graphemes,
the cursor's display column and the widest line measured it, `Keymap` and the typing assists split
it, and `Geex.Buffer.Doc` split it into a grapheme list on every edit.

**Decision.** The same rule, along the row: a key and a frame do work in proportion to the columns
they touch.

- **`Geex.Width.seek/3`** finds a grapheme column or a display column measuring a line's ASCII up
  to its first other character by its bytes (its tabs and control characters one by one), and
  from there walking it a grapheme at a time as before, so a line that isn't ASCII costs no more
  than it did. The byte patterns the search uses are compiled once (`Geex.Ascii`): given as plain
  lists they were compiled on every call, which made the first cut of this 50× slower than main
  on French or Japanese text (mod-verify's review). The cursor's display column, the widest line and the mouse's display →
  grapheme cast use it. Width still only paints and casts a click (ADR-0027).
- **The paint draws each row's window:** from the first grapheme that draws into the horizontal
  scroll's column to the last that starts before the right edge. Styles are resolved over those
  bytes only, and the reactor is asked for those bytes only: `frame/11` takes the spans or a
  function of the byte ranges it paints (`Paint.visible_ranges/6`).
- **`Keymap` reads a line over 4 KB through a window** of 1,024 graphemes either side of the
  columns a key needs, and reads the whole line again when an answer reaches a side of the window
  that isn't the line's, so no answer depends on the window. The typing assists read only the
  characters either side of the cursor (the line before it only for a quote).
- **`Doc` cuts a line at a column by its bytes** where the line is ASCII up to there, else with
  `String.split_at/2`. The results are the same as before (its property holds them to the old
  grapheme lists), so replay is unchanged (the cassette is green unregenerated).

**Measured** on the 2 MB line, the cursor near its end, through `Loop.handle_info/2`: a repaint
2.3 s → 11 ms; a word motion, `Alt+8` or a move 0.5–0.9 s → 7–11 ms; `Alt+\` 0.9 s → 30 ms; a typed
character, Enter or Backspace 0.5–1.4 s → 10–12 ms.

**The guard.** `test/geex/loop/long_line_loop_test.exs` times keys, typing (a quote on a line full
of strings too) and the repaint after each on the 2 MB line: a key under 50 ms, a repaint under
100 ms. A non-ASCII long line still costs a walk up to the cursor or the scroll, several times
cheaper than before (doc/bugs.md, BUG-12's remainder).

## Amendment (2026-11-15): a save leaves the key loop and the buffer; a quit waits for it and names unsaved edits

The maintainer's answers of 2026-11-15 (roadmap item 9, "saving off the key loop"), built on the
branch `save-off-loop`. §4 parked saves: at 10 MB (100,000 lines) Ctrl-O held the loop 418 ms with
nothing to trim (the fast-forward check 141 ms and the conflict-block scan 71 ms in the loop, about
200 ms in the buffer) and 801 ms when a merge came first. Moving the save into a process wasn't
enough on its own: every frame reads the buffer (`Session.snapshot/0` calls `Buffer.snapshot/1`), so
the screen would still have waited while the buffer saved.

**Decision.**

- **A save runs in a process of its own.** Ctrl-O and `save-all` start one, which runs
  `Reconcile.save/2` for each file in turn, sending each file's result and then a last word; the
  loop draws them as they come. The catch-up, the conflict-block scan and the write leave the loop.
- **The write leaves the buffer.** `Buffer.save/2` runs in its caller around two short calls:
  `begin_write/2` works out the save's own edits (the final newline, the trim) and keeps the text to
  write as the buffer's **pending write**, without keeping those edits yet; the caller checks the
  file still holds the synced text (else `{:error, :behind}`, as before), writes it in place, and
  answers `end_write/2`. With nothing changed meanwhile the save's edits are kept, one step, and the
  buffer is clean, as before. **Edits made during the write land** and stay unsaved: the written
  text becomes the synced one (an empty group records it, as reconcile's do, ADR-0033), and the
  save's own edits, worked out against the text before them, are left to the file; the next save
  makes them again. A history that changed without its text (an attestation credited during the
  write) gets the save's edits made again on it, so the credit stays (mod-verify's review). A failed
  write leaves the buffer as it was, and the file is read again (it may hold part of the write). A
  writer that dies before `end_write/2` is a failed save (the buffer monitors it). One write at a
  time per buffer (`{:error, :saving}`).
- **A rename, delete or close waits for no write: it is refused while one is under way**
  (`{:error, :saving}`, "not renamed: a.ts to b.ts: it's being saved", "not closed: it's being saved
  (cancel-save stops it)"), so a write that had read its path can't bring the old file back
  (mod-verify's review). `Geex.Session` holds each buffer first (`Buffer.hold/1`): refused while it
  writes, else no save begins until the rename re-keys it, the buffer ends, or `Buffer.release/1`
  (a rename the disk refused). The loop also refuses to close a tab or pane whose buffer its own
  save has. `Buffer.status/1` gains `saving`.
- **Reconcile knows geex's own write** ([ADR-0017](0017-reconcile-file-watch.md)'s amendment of the
  same date): while a save writes, the watcher's sight of the pending text isn't behind; anything
  else is read again once the write is done; a fast-forward is refused (`{:error, :saving}`; the
  loop says "a save is writing the file; try again when it's done").
- **Ctrl-O or `save-all` again while a save runs: "still saving".** "saving a.ts…" shows on the
  status line once a save has run 150 ms.
- **`cancel-save`** stops a save whose write hasn't begun ("save cancelled"). One whose write has
  begun finishes ("already writing: it finishes that file, then stops", then "saved (it was already
  writing)"), and a `save-all` stops after it, naming the files not saved. The loop and the save
  agree through one atomics cell (`Geex.Loop.SaveFlag`): the save takes it just before each write
  begins; a cancel takes it only while no write is under way, and from then the save begins no
  write and starts no more files. So a cancel never cuts a write short: written in place, a cut
  write would leave half a file. The save's process isn't killed (a kill during `git merge-file`
  would leave its temporary directory, mod-verify's review): what it was doing before the write
  finishes, and it ends. So a catch-up already under way still lands after "save cancelled" (for a
  buffer that was behind, maybe a merge with conflict blocks): a recorded step Alt+Z takes back, as
  after Alt+D.
- **A quit waits for a save:** "saving a.ts… quits when done (quit again: leave now; Esc: stay)". A
  second quit leaves now: a save whose write hasn't begun is cancelled, one that is writing finishes
  first. Esc stays, and the save goes on; after a second quit its cancel stands ("staying; the save
  stops after this file"). The terminal closing is a quit that leaves now. A quit's warning or wait
  closes the command line and the settings view first, which would draw over the status line.
- **A quit names unsaved edits first:** "unsaved: a.ts, b.ts (kept for next time); quit again to
  leave". The next quit leaves: any quit key, or `quit` / `exit` typed (the command line's keys keep
  it armed); any other key, or any other command run from the command line or the palette, disarms
  it. Every way out runs the one `quit` command (Ctrl-X, Ctrl-Q,
  Ctrl-C, `quit`, `exit`, the settings view's), so this covers them all; Ctrl-Z isn't bound, and
  closing a tab already refuses unsaved edits. The ledger keeps unsaved edits across a quit
  (ADR-0033), which is why quit never asked; a buffer without one (a scratch buffer, the ledger off)
  is named "not kept" (`Buffer.status/1` gains `kept`).
- **Written in place**, as before, not to a temporary file renamed over the original (the
  maintainer's answer: a rename changes the inode, breaks hard links and needs the permissions
  copied).

**Measured** at 10 MB (100,000 lines, `MIX_ENV=test`, a buffer with a ledger), a save in another
process while a reader polls the buffer: with nothing to trim the save takes 146–150 ms and a read
of the buffer waits at most 26–27 ms; a first save that trims every line takes 353–397 ms and a
read waits at most 172–186 ms (applying the trim in `begin_write/2`, 149 ms, and keeping it, its
history entry and ledger line, in `end_write/2`, 159 ms). The key loop waits on none of it. A
fast-forward takes one snapshot now, not three (each builds the whole text in the buffer). A save
with a key typed during its write spends ~60 ms in `end_write/2` at 10 MB and appends the whole
written text to the ledger, as the empty group's synced text (the shape of reconcile's).

**What still waits.** The save's own edits are applied and recorded in the buffer, as every edit
is: on a big file's first trimming save the frames wait up to ~150 ms twice, and a key typed then
waits for the buffer too. `Alt+D`'s fast-forward still runs in the loop. And on a 100,000-line file
a key takes ~230 ms to show with no save at all, on main as here; `Session.snapshot/0` is 21 ms of
it, and the rest isn't traced yet (roadmap item 9). That cost, not the save's, is most of what a
key typed during a save on such a file waits for (live, a key typed 50 ms into a first trimming save
showed after 471–537 ms here, 582–609 ms on main).

**Open, for the maintainer** (mod-verify's review; answered 2026-11-16, below). A signal that
stops geex (SIGTERM) during a write can cut it: the save's process isn't supervised and doesn't
trap exits, where the old save ran inside the buffer, which a shutdown let finish. And by the
answers above a quit waits for a write under way, so a write that hangs (a stalled network disk)
leaves only a kill.

**Tests.** `test/geex/buffer/pending_write_test.exs` (the buffer answering mid-write, an edit
during the write and the ledger keeping its synced text, a failed or dead writer, the watcher, the
gate), `test/geex/loop/save_flag_test.exs` (every order of a cancel against a write; a property),
`test/geex/loop/save_loop_test.exs` (still saving, saving…, cancel-save, quit while saving, quit
with unsaved edits, the warning from the command line and the settings view, a rename, delete or
close refused mid-write). The loop tests that save let it finish (`Geex.LoopSave.finish/1`).

**See** `lib/geex/buffer.ex` (`save/2`, `begin_write/2`, `end_write/2`, `hold/1`),
`lib/geex/session.ex` (`held_buffers/1`), `lib/geex/reconcile.ex`
(`save/2`'s `gate:`, `{:recheck, path}`), `lib/geex/loop.ex` (`start_save/3`, `cancel_save/1`,
`quit/1`), `lib/geex/loop/save_flag.ex`.

## Amendment (2026-11-16): shutdown during a save

The maintainer's answers of 2026-11-16 to the open question above: a quit may cut a write short
once geex has said that it will ("if we appropriately alerted them before the second ctrl kill
key that's fine"), and two quits are the whole of it: "if they try to exit we warn and then if
they exit again it forces the exit".

- **The first quit warns; the second leaves.** The first quit during a save waits for it, and the
  status line says what the next does: "quits once saved (quit again cuts the save short; Esc:
  stay): saving a.ts…". A second quit leaves, closing the command line and the settings view
  first as the first quit does: a save whose write hasn't begun is cancelled and geex leaves at
  once (as on 2026-11-15); a write under way gets 1 s (`@cut_after_ms`) to finish, the status line
  saying "leaving once written (cut short after 1 s): writing a.ts…", and is cut short then, the
  file maybe left part-written. Esc no longer stays after the second quit. The 1 s covers every
  local write measured, from the gate to the save's return: ~10 ms at 1 MB, 54–129 ms at 10 MB,
  187–212 ms at 30 MB, 257–281 ms for a first trimming save of 10 MB (mod-verify's measure, the
  ledger on); a quick double quit fits inside those, which is why a write under way isn't cut
  at the key. Quits after the second don't leave sooner than its 1 s: a burst of keys from one
  read is handled before any frame is painted, and a key held down repeats.
- **The warning comes first, the file last.** The status line is clipped at its edge, so each
  label puts what a quit does before the file's name (its basename), and while a quit waits the
  label leads the line: the name, `[+]` and behind give way (the label ends with the name). On 80
  columns each warning shows whole with a 28-character name, `[+]` and behind (mod-verify's
  reviews found the earlier wording, the relative path first, clipped there and at 100, and the
  two-quit warning, after the name, clipped for ordinary names).
- **SIGTERM and SIGHUP leave as the terminal closing does** (`Geex.Loop.shutdown/0`, from
  `Geex.CLI.Signals`): there is nobody to warn, so no save is cancelled. A save under way runs on,
  whether or not its write has begun, a save-all to its last file (the maintainer, 2026-11-17: a
  save cancelled by closing the window, with no warning to see, would leave the user believing
  the file saved), for up to 30 s (`@shutdown_wait_ms`; the maintainer chose 30 over 5, so a slow
  network disk isn't cut), then the orderly stop (`Geex.stop/0`), the last session kept. A
  `cancel-save` already made stands. This wait is its own (`:shutdown`): Esc doesn't call it off,
  and the status line says "leaving once saved (quit again cuts it short): saving a.ts…"; a quit
  once that has been up 1 s cuts the save short as a second quit does. Cut short, by that quit or
  by the deadline, a save whose write hasn't begun is cancelled first, so no write begins while
  the VM stops. Each deadline carries a token, so a word from an earlier one is nothing; a second
  signal keeps the first deadline, and a signal after a second quit, which already cut the save
  short, changes nothing (its 1 s stands). Should the loop not get as far as stopping, geex stops
  anyway after 35 s (`Geex.CLI` told under the binary, `System.stop/0` under `mix run`), past the
  wait so it never cuts a save the loop would let finish.
- **A disk that hangs still holds the stop** ([bugs.md](../bugs.md) BUG-21, open). The second
  quit and the shutdown's deadline leave the loop on time, but a file read that never returns
  holds OTP's one file server, every `File` call behind it, so the stop itself waits: 22 s from
  the installed binary (its tree's children killed at their shutdown timeouts, then the halt),
  and forever under `mix run` (Mix's own stop lists files through the stuck file server, and
  nothing on `init:stop/0`'s way has a time limit). Checked live with a FIFO in place of the open
  file.
- **A cut write can be recovered.** With the ledger on, reopening the file shows the cut text as
  one change from outside, and one undo brings back the buffer's text from before the save
  (checked with a script: the write cut halfway, the buffer stopped, reopened).
- **SIGHUP is handled** (BUG-20). Its OS default ended the VM at once: closing the terminal window
  left the ledger lock and the discovery file (swept at the next start), the last session up to
  2 s old, and could cut a write under way. [ADR-0036](0036-installed-binary.md)'s 2026-11-16
  amendment.
- **The terminal process stays after the end of input.** `Geex.TerminalIO` stopped `:normal`
  there; a permanent child, it was restarted into the same end of input until its supervisor gave
  up and took the tree down, the loop and the save it waited for with it. It now says `:eof` to
  each subscriber, and to any that subscribes later (a restarted loop), and stays until the loop
  stops the VM.

Checked live in tmux, under `mix run` and from a release installed in a scratch directory: the
terminal closed 0–0.6 s into a first trimming save of a 9.5 MB file left the file whole (written)
every time, geex gone within 1.5 s, no lock or discovery file left; SIGTERM the same, exit 0.
With SIGHUP handled but before the `TerminalIO` change, five of five such closes under `mix run`
left the VM running with no application. After the second answer, under `mix run`: a 70 MB file of
700 lines with one edit, Ctrl-O and a quit drew "quits once saved (quit again cuts the save short;
Esc: stay): saving wide.txt…" whole on 120 columns, and the second quit left within 1.3 s, the
file whole each time (written once, and once the save cancelled before its write, the file as it
was).

**Tests.** `test/geex/loop/save_loop_test.exs` (the second quit's 1 s timer read and its end;
quits after it not leaving sooner; three quits back to back; Esc not calling a second quit off;
the second quit closing the command line and the settings view; both warnings whole on 80 columns
with a nested name and `[+]`; save-all's warning naming the file being written; the terminal
closing and a signal letting a save run, before and during its write, a save-all to its last
file, a `cancel-save` standing, the 30 s timer read; the wait ending, and a stale word; a quit or
the deadline after a signal cancelling a save not yet writing; a signal after a second quit
changing nothing; Esc not calling a shutdown off),
`test/geex/cli_test.exs` (SIGTERM and SIGHUP through the loop, or `Geex.stop/0` with no loop),
`test/geex/terminal_io_test.exs` (the end of input said, to a later subscriber too; the process
stays).

**See** `lib/geex/loop.ex` (`shutdown/0`, `shutdown/1`, `quit/1`, `saving_label/1`),
`lib/geex/cli/signals.ex`, `lib/geex/terminal_io.ex`, [bugs.md](../bugs.md) BUG-20 and BUG-21.
