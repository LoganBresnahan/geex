# ADR-0042: Shell commands from the minibuffer

- **Status:** Accepted 2026-10-19 (the maintainer's ask, relayed by the coordinator session,
  which also passed on the maintainer's choice of `!` to run a command again). Built the same day. **Amended 2026-11-09 (recorded 2026-11-10):** the output pane's title row is the band's handle. **Amended 2026-11-12 by [ADR-0051](0051-panes-on-alt-angle-brackets-digits-free.md):** `Alt+<` / `Alt+>` reach the output pane, not `Alt+P`. **Amended 2026-11-12 by [ADR-0053](0053-search.md):** the output pane also holds a project search's results (`Alt+Shift+Q`), `Alt+N` stepping them. **Amended 2026-11-13:** `!!` after a restart runs the newest kept `!` line. **Amended 2026-11-13:** Enter opens tsc's `path(line,col): error` too. **Amended 2026-11-23** (accepted, not built): locations drawn as links, a click opens one, `Alt+N` steps them (in place of [ADR-0055](0055-checks-on-save.md), parked).
- **Date:** 2026-10-19
- **Relates to:** [ADR-0028](0028-editor-shell-and-minibuffer.md) (the minibuffer and its typed
  verbs), [ADR-0035](0035-the-loop-never-waits.md) (slow work runs off the key loop),
  [ADR-0034](0034-panes-tree-edits-hold.md) (the edits pane, whose band the output pane shares),
  [ADR-0031](0031-undo-redo-history-operations.md) (one edit, one undo), the sacred invariants
  "one shared path" and "provenance on every command"

## Context

Running the tests, a build or `git` meant leaving geex for another terminal, and the output had
to be read there and its `path:line` typed back in by hand. The maintainer asked for shell
commands in the minibuffer, an output pane, a way to filter text through a command, and a
history for the minibuffer.

## Decision

### 1. `!COMMAND` runs a command

- It runs as `sh -c COMMAND` in the project root ([ADR-0037](0037-pane-and-file-keys.md)'s
  2026-10-19 amendment: every path is from the root), in a process of its own (`Geex.Shell`).
  The key loop never waits on it.
- **No terminal.** stdin is `/dev/null`; stdout and stderr are pipes, read together. The
  environment adds `TERM=dumb`, `PAGER=cat` and `GIT_PAGER=cat`, so programs neither draw nor
  page.
- **Its own process group.** The VM starts every port program in a new session
  (`erl_child_setup` calls `setsid()` before exec on Unix), so the shell's pid is the id of a group
  holding everything the command starts. **Ctrl-G**, from anywhere while a command runs, sends
  the group TERM, then KILL two seconds later. No `setsid` binary is needed, which macOS lacks.
- **Programs that want a terminal.** If the output contains a switch to the alternate screen
  (`ESC [?1049h`, or the older 47 and 1047), the group is stopped and the pane says "this needs a
  real terminal: run it in a terminal split". Under `TERM=dumb`, though, programs that use
  terminfo never send that switch: vim showed a dumb frame and waited until Ctrl-G. So a command
  whose program is a known full-screen one (vi, vim, nvim, nano, emacs, top, htop, watch, tmux,
  screen, ssh, fzf and a few more, by its first word after any `NAME=value`) is not started, with
  the same message.
- **Escape sequences are removed** (v1), not interpreted: CSI, OSC and two-byte ones. A carriage
  return keeps what was written after it (a progress bar's last state), tabs expand to every 8
  columns, other control characters go, and bytes that aren't UTF-8 are replaced. Each line is
  cleaned once its newline arrives, so a sequence or a character split across two reads is whole.

- **A flood can't reach the key loop.** The first build sent every chunk to the loop, which split
  and cleaned it: `!seq 1 5000000` froze the editor (no key, no clock) until it ended. So the
  runner splits and cleans, and sends the loop at most one batch every 50 ms: the lines since the
  last one (the newest 5,000 at most) and the unfinished line. A port can't be told to read
  slower, so when the runner falls behind (64 chunks waiting) it passes over the waiting chunks,
  checked only for the alternate screen, and splits just the newest from its first whole line:
  the end of the output (a test run's summary) always arrives. If chunks still pile up past 2,048
  (about 128 MB, a loaded machine), the command is stopped: "it printed faster than geex can show
  it: stopped (pipe it through head or tail)". **Amended 2026-10-19:** the cap is checked at
  every chunk the drain passes over too, and the TERM is sent from a process of its own, so the
  runner keeps passing over output while `sh` starts. Before, a CI run under the suite's load saw
  2,948 chunks waiting; with busy processes in the VM the peak grew with the load (2,500–6,900),
  and now stays at the cap (1,967–2,048 under 16, 64 and 256). A plain line (no control byte, UTF-8) is passed
  through uncleaned, which made the runner about 4× faster. Measured: `!seq 1 50000000` ends in
  1.0 s with its last line shown, and `!yes` runs with the keys live until Ctrl-G.

### 2. The output pane

- A read-only pane in the edits pane's band under the editor. While it is open, the band shows it
  instead of the edits pane; `q` closes it (stopping the command if it runs), and the edits pane
  is back. `Alt+P` reaches it as it reaches the edits pane.
- **Title:** the command, then "running Ns" (counted each second), then "exit N · 1.2s", or
  "stopped" when it needed a terminal.
- **Following:** while the highlight is on the last line it stays there as output arrives; moving
  up stops that, and moving back to the last line starts it again. Only the newest 5,000 lines
  are kept.
- **Enter** on a line naming `path:line` or `path:line:col` (compilers, test runners, grep)
  opens the file there. The path is from the root; a URL's `host:port` isn't one, and a path to no
  file says so.
- **`!` runs the command again** (the maintainer's choice; there is no `r`). The mouse: a click
  highlights a line, the wheel moves the highlight.

### 3. `!!` runs the last `!` command again, from the minibuffer.

### 4. `|COMMAND` filters the selection

- The selection's text goes to the command on stdin (from a temporary file, `0600`, removed after),
  and stdout (at most 64 MB; past that the command is stopped) replaces the selection as **one
  recorded edit**: a `Replace` with `:human`
  provenance through `Geex.Dispatch.run/1`, so one `Alt+Z` takes it back.
- When the selection didn't end in a newline and the output does, that one newline is dropped
  (`sort`, `tr`, `fmt` end their output with one).
- **On a non-zero exit** the text is left alone, and stderr shows in the output pane with the
  exit code.
- **Nothing is replaced** if the buffer's text changed while the command ran, or another buffer is
  shown: the selection's coordinates would no longer mean the same text.
- One command runs at a time: a `!` or `|` while one runs is refused with "Ctrl-G stops it".

### 5. The minibuffer's history

- Every line entered in the `:command` and `:grid` modes is kept, each mode in its own list,
  newest first. Entering one again moves it to the front. Up shows older entries, and Down newer
  ones, back to what was being typed.
- Kept in `$XDG_STATE_HOME/geex/history.json` (default `~/.local/state/geex/`), `0600`, at
  most 500 entries a mode, written whole (a temporary file renamed) in a process of its own after
  each entry. A file that won't read is ignored. The `minibuffer_history` gate is off under test;
  `history_file` overrides the path.

## Consequences

- Tests, builds and `git` run without leaving geex, and their `path:line` output is one Enter
  away.
- `|` makes any filter an editing command, recorded and undoable like a paste.
- A command that wants input waits on `/dev/null` and usually ends at once. One that ignores
  stdin and never ends (a server, `tail -f`) runs until Ctrl-G or `q`.
- Interactive full-screen programs belong in a terminal split. The known-program list is a
  heuristic: one it doesn't name, under `TERM=dumb`, runs until Ctrl-G.
- Colours are lost in v1. Interpreting SGR into the pane's cells is a later step if a consumer
  wants it.


## Amendment (2026-11-09, recorded 2026-11-10): the output pane's handle

Roadmap item 18.3: the output pane takes the edits pane's band, and now its title row is the
band's handle too ([ADR-0038](0038-split-panes-and-tabs.md) §6): it draws `⠛⠛` between the
title and the hint, a drag resizes the band (the same height the edits pane uses), and a press on
it focuses the output pane, not the edits pane it covers.

## Amendment (2026-11-13): `!!` after a restart

The last `!` command was the loop's alone, so after a restart `!!` said "no ! command yet" though
the kept history of typed lines (ADR-0042's `history.json`) had it. Now `!!` runs the loop's last
`!` command, else the newest `!` line in that history. A restart itself still runs nothing, and
the output pane isn't kept across one: it is a snapshot of when the command ran (the maintainer's
call, 2026-11-13); `Alt+M` then Up, or `!!`, runs it again.

## Amendment (2026-11-13): Enter opens tsc's `path(line,col): error` too

The maintainer is learning TypeScript in geex, checking with `!tsc` (or `!npx tsc --noEmit`).
Run by `!`, tsc has no terminal, so it prints `src/a.ts(2,5): error TS2322: …`, not the
`src/a.ts:2:5 - error …` of `--pretty`, and Enter said "no path:line on this line".
`Geex.Shell.Text.location/1` now also reads `path(line,col)` and `path(line)` (MSBuild's and the
C# compiler's form too), but only followed by `: error`, `: warning`, `: info`, `: message` or
`: note` (any case), so a call in ordinary output (`Math.max(1,2)`) is never one. When a line
holds both forms, the one further left wins. Project search's own results (`Search.Project`)
are untouched. Two properties pin it (`test/geex/shell/text_test.exs`): the form reads back as
`{path, line, col}` at any indent, and without the severity word a parenthesised pair is never
a location.

## Amendment (2026-11-23): locations drawn as links, a click opens one, `Alt+N` steps them

**Status:** accepted 2026-11-23 (the maintainer's ask; reviewed by geex-mod); not built. It also amends
[ADR-0039](0039-mouse.md) (a click in the output pane) and [ADR-0053](0053-search.md) (which
list `Alt+N` steps).

**Context.** The maintainer parked checks on save ([ADR-0055](0055-checks-on-save.md)'s
"Parked 2026-11-23") for something less invasive: the user runs their own checker (`!npx tsc
--noEmit`, `!cargo check --message-format=short`, `!mix compile`) and its output's lines are
clickable. Half of it is here: Enter on a highlighted line opens the `path:line[:col]` or
`path(line,col): error` it names (`Geex.Shell.Text.location/1`). What is missing:

- nothing shows which lines name a place;
- a click only highlights the line (`output_press/3`), so opening one takes a click and Enter;
- `Alt+N` steps a project search's results but not a `!` command's locations (ADR-0055's
  Context said it did; it didn't).

**Decision.**

1. **Each line's location is resolved off the loop, as the lines arrive.** A process beside the
   pane (the tree's reader the model, ADR-0035) takes each finished line, reads its location with
   the reader Enter uses, which gains the location's position in the line
   (`Text.location_span/1`, pure; a property: the span's text reads back as the same location),
   and asks `Geex.Disk` whether it names a regular file under the root. The loop keeps the answer
   with the line. A project search's result lines go the same way, with their own reader
   (`Search.Project.locations/1`), which fixes [BUG-26](../bugs.md): today one `Alt+N` over the
   results can stat every line in the loop. Drawing, a click and `Alt+N` then only look the
   answer up; none of them touches the disk.
2. **Locations are drawn as links,** only those resolved to a file: the span is drawn
   underlined in the theme's `accent`, the rest of the row as now. A line not resolved yet draws
   plain, and becomes a link when its answer comes. So a clock (`10:16:05`), an address
   (`127.0.0.1:4000`, `localhost:5173`) or a path to no file is never underlined. The
   highlighted row keeps its tint, with the link still underlined.
3. **A click on a link opens it**, as Enter on its line does: the file at its line and column,
   in the pane that holds it or the current one. A click elsewhere on the row highlights it, as
   now; the wheel still moves the highlight. It opens on the press: the pane's rows have no drag
   (the title row's band handle is the only one, and it holds no link). One click, no
   double-click: the pane is read-only, so a click has nothing else to do there.
4. **`Alt+N` steps the `!` output's locations.** After a `!` (or a `|`, whose pane shows its
   stderr) whose output names a file, `Alt+N` opens the next line resolved to a file, after the
   one last opened (by Enter, a click or `Alt+N`) or, before any, after the highlight, wrapping;
   one stop per line, other lines passed over, as a project search's results are stepped
   (ADR-0053, Q13). Lines not resolved yet are passed over too. Which list `Alt+N` steps is the
   one started last: a `!`, a project search, or a file search (`Alt+Q`). The pane holds one list
   at a time (a `!` replaces a project search's results, and the other way round), so closing it
   with `q`, or a `!` whose output names no file, gives `Alt+N` back to the file's matches (Q14),
   never to a search the pane no longer shows. While the command runs, `Alt+N` steps what has
   arrived and stops the pane following.
5. **The hint** on the focused pane's title gains `Alt+N next` while its output names a place.

**Not in this slice:**

- A message split over lines: `mix compile` prints the message, then a code excerpt, then
  `└─ lib/w.ex:2:9: W.f/1`. Only the `└─` line is a link; Enter on the message line doesn't look
  below it.
- Column units: a column is taken as a character position, as Enter takes it today. tsc counts
  UTF-16 units and gcc bytes, which differ only on lines with wide or non-ASCII text before the
  column.
- Stepping back: `Alt+Shift+N` stays unbound until multiple cursors take it (ADR-0053).
- Paths relative to another directory: `!cd web && npx tsc` prints paths from `web/`, which
  don't resolve from the root, so they aren't links, as Enter can't open them today.
- Marking the code, a problems list, anything that runs on its own: that was ADR-0055.

**Consequences.**

- Running a checker in geex becomes: `!cmd`, then click (or `Alt+N`) through what it found. No
  config, no language knowledge in geex beyond the two location forms it already reads.
- A link is drawn only once geex knows the file is there, so a link appears a moment after its
  line on a slow disk, and never for a line naming no file. The answer can go stale (a file
  deleted after its line arrived): opening it then says "no such file here".
- The resolver costs one stat per reading of each arriving line, off the loop; output that is
  only paths (a `find`) costs one per line, at most the pane's 5,000.
- `Alt+N`'s meaning now follows three lists. The rule is the one ADR-0053 set for two: the list
  started last.
- Invariants: no buffer change and no command (1 to 3); drawn through the `Screen` (4); a click
  maps to a line and a column, and the column becomes a grapheme position as Enter already does
  it (5).

## See

`lib/geex/shell.ex`, `lib/geex/shell/text.ex`, `lib/geex/loop/output.ex`,
`lib/geex/minibuffer/recall.ex`, `lib/geex/loop.ex` (`run_shell/2`, `run_pipe/2`, `shell_said/2`,
`apply_output_key/2`, `draw_output_pane/3`), `lib/geex/loop/verbs.ex`;
`test/geex/shell_test.exs`, `test/geex/loop/shell_test.exs`; [testing.md](../testing.md)
2026-10-19.
