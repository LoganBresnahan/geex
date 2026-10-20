# ADR-0042: Shell commands from the minibuffer

- **Status:** Accepted 2026-10-19 (the maintainer's ask, relayed by the coordinator session,
  which also passed on the maintainer's choice of `!` to run a command again). Built the same day.
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

## See

`lib/geex/shell.ex`, `lib/geex/shell/text.ex`, `lib/geex/loop/output.ex`,
`lib/geex/minibuffer/recall.ex`, `lib/geex/loop.ex` (`run_shell/2`, `run_pipe/2`, `shell_said/2`,
`apply_output_key/2`, `draw_output_pane/3`), `lib/geex/loop/verbs.ex`;
`test/geex/shell_test.exs`, `test/geex/loop/shell_test.exs`; [testing.md](../testing.md)
2026-10-19.
