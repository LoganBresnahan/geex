# geex — Known bugs (triage shelf)

Bugs found but deliberately **not fixed yet** — captured so they aren't lost and so a fix
starts from a real root cause, not a guess. Each entry: symptom, status, the *verified*
cause, the recommended fix, and what was ruled out. When one is fixed, move it to
[testing.md](testing.md) with the verification.

---

## BUG-28 — Keys typed while the screen was stalled arrive together, and Esc then a letter reads as Alt+letter

- **Status:** open. Seen 2026-11-23 by geex-verifier, on a disk made to stall (a FUSE stub) with
  the first build of clickable output: after the terminal's writes waited and then recovered,
  the keys typed meanwhile were read in one go, and Esc followed by `t` ran `Alt+T`. Predates that
  branch: any stall that lets input pile up (a loaded machine, a suspended terminal) does it.
- **Why they piled up:** the terminal's reader (`Geex.TerminalIO`) was waiting for a dirty I/O
  scheduler too, all ten held by stalled stats (geex-verifier), so nothing was read until one came
  free.
- **Cause (observed, the parser's design):** a terminal sends Alt+key as Esc then the key, so the
  parser (`Geex.Input.Parser`) reads an Esc followed at once by a key in the same read as one
  Alt chord; only an Esc alone at the end of a read (or after its timeout) is a plain Esc. Bytes
  that arrive together after a stall look exactly like an Alt chord.
- **Recommended fix:** none certain. The terminal gives no timing in the bytes themselves; the
  Kitty keyboard protocol (ADR-0026's capability-gated extras) reports Esc and Alt as distinct
  keys where the terminal supports it. Worth weighing only if it bites outside a stall.
- **Ruled out:** a loss of bytes: every key arrived, in order.

---

## BUG-27 — Under load, stopping a `!` can KILL it before its TERM lands (exit 137, not 143)

- **Status:** open. Seen 2026-11-23 while building clickable output: `shell_test.exs`'s "`stop`
  picked in the palette stops it too" failed once in 40 runs of three test files (and one full
  suite run failed once, its output not kept), expecting `{:exit, 143}` and getting
  `{:exit, 137}`. Not caused by that branch: it doesn't touch `Geex.Shell`'s stop.
- **Symptom:** `Ctrl-G` (or `stop`) on a `!` started a moment before, on a loaded machine, ends it
  with KILL instead of TERM: the title says "exit 137", and the command gets no chance to clean up.
- **Seen again** 2026-11-23 by geex-verifier at a LIGHT load (3.6; seed 814068, `+S 2:2`,
  `--max-cases 2`), and not reproduced by replaying that seed ten times nor by 600 direct
  `Shell` start/stop cycles (immediately, and after 50 ms; all 143). A load of 3.6 doesn't fit
  the theory below, so it is unconfirmed: the cause is open.
- **Suspected cause (from the code, unconfirmed):** `Geex.Shell.stop_group/2` sends
  the TERM from a spawned process that starts `sh -c 'kill -s TERM -- -PID'`, and schedules the
  KILL `@grace_ms` (2 s) after the stop. Starting that `sh` is the slow part on a loaded machine
  (the comment above `stop_group/2` says so); when it takes longer than the grace period, the KILL
  is sent first. 137 is 128 + 9, the KILL path.
- **Recommended fix:** start the grace period once the TERM has been sent (the spawned process
  reports back, then the runner schedules the KILL). Reproduce first: delay `signal/2`'s TERM by
  more than 2 s in a test, which should give 137 every time.
- **Ruled out:** the clickable-output branch's resolver (it never signals, and the failing test
  never opens a link).

---

## BUG-26 — One `Alt+N` over a project search's results can stat every result line in the key loop  ✅ FIXED (2026-11-23)

- **Status:** **FIXED** 2026-11-23 on the branch `clickable-output` (ADR-0042's amendment of that
  date): a project search's result lines are resolved off the loop as they arrive, and `Alt+N`
  steps by those answers alone. Was open. Found 2026-11-23 by geex-mod, reviewing ADR-0042's proposed amendment of that
  date (clickable output), which would have copied the pattern to `!` output. Not reproduced
  live: read from the code. In **0.7.0** and every build since ADR-0053's project search.
- **Symptom (expected):** with a project search's results in the output pane, one `Alt+N` stats a
  file for each line it passes, in the key loop; on a disk that stalls (a network mount), one stat
  that never returns leaves no key working, against ADR-0035.
- **Verified cause (code reading):** `next_result/1` (`lib/geex/loop.ex`, "Alt+N: the next result
  line") tries up to every line of the pane, calling `result_target/1` on each, and
  `result_target/1` calls `Geex.Disk.regular?/1` for each reading of the line until one is a file.
  `Geex.Disk` keeps a hung call off OTP's file server, but a `:raw` call that hangs still holds the
  process that made it (its moduledoc), here the loop. So one keypress costs up to (lines × readings)
  stats in the loop, unbounded on a stalled mount.
- **Recommended fix:** resolve each output line's location off the loop as the lines arrive, the
  tree's reader the model (ADR-0035), so `Alt+N`, Enter and a click are lookups. ADR-0042's
  2026-11-23 amendment (proposed) decides that for `!` output and project search alike; the
  clickable-output build fixes this with it.
- **Ruled out:** Enter's `open_location/2` and opening a result also stat in the loop, but once per
  keypress for the one file opened, as opening any file does; not this bug's growth with the
  output's length.

---

## BUG-25 — Dot folders are missing from the tree outside a git work tree  ✅ FIXED (2026-11-22)

- **Status:** **FIXED** 2026-11-22 on the branch `tree-links` (ADR-0034's amendment of that date):
  dot folders listed and watched, never `.git`, `.hg` or `.svn`. Reported by the maintainer
  2026-11-22; by design since ADR-0034 §5 (the tree's first build), then unwanted. In **0.7.0** and
  every build before the fix.
- **Symptom:** a folder whose name starts with a dot (`.github/`, `.config/`, `.aws/`) isn't in
  the tree when geex's root isn't inside a git work tree. Dotfiles (`.gitignore`) show. Inside a
  git work tree they show, unless git ignores them.
- **Verified cause:** `Geex.Tree.entries/2` (the walk used when `git ls-files` fails) drops every
  directory whose name starts with `.` ("skipping dot-directories" in the module doc), and
  `Geex.Tree.Watcher.new_dirs/2` doesn't watch them either. Reproduced 2026-11-22: a scratch
  directory listed `.gitignore`, `a.txt`, `real_dir/r.txt`, without `.github/ci.yml` or
  `.hidden_untracked/h.txt`; with `.git` present, both were listed.
- **Recommended fix:** show dot folders in the walk, except a version control directory (`.git`,
  `.hg`, `.svn`), and watch them too; ADR-0034 §5 amended. A dot folder can be large (`~/.cache`,
  `~/.npm` under a home-like root), so whether its contents are listed up front or when opened is
  the maintainer's call, with BUG-24's symlinked folders.
- **Ruled out:** git mode: tracked and untracked-but-not-ignored dot folders are listed; an
  ignored one (`.ignored/` in `.gitignore`) isn't, which is git's rule, not this bug.

---

## BUG-24 — Symlinked folders never show in the tree; outside git, no symlink does  ✅ FIXED (2026-11-22)

- **Status:** **FIXED** 2026-11-22 on the branch `tree-links` (ADR-0034's amendment of that date):
  a link to a file is a file; a link to a folder is a folder marked `↗`, listed when opened (the
  maintainer's choice), a link inside it a link again. Reported by the maintainer 2026-11-22. In
  **0.7.0** and every build before the fix, since the tree's first (ADR-0034 §5).
- **Symptom:** a symlink to a folder (`link_to_dir -> real_dir`, `~/.aws -> /mnt/c/…`) is missing
  from the tree, inside a git work tree or not. Outside a git work tree a symlink to a *file* is
  missing too (inside one it shows).
- **Verified cause:** inside a work tree, `git ls-files` lists a symlink as one entry (git stores
  the link, not what it points to), and `Geex.Tree.git_files/1` keeps only entries that are
  regular files (`Geex.Disk.regular?/1`, which follows the link): a link to a file passes, a link
  to a folder doesn't, and nothing ever lists what's inside it. Outside one, `Geex.Tree.entries/2`
  reads each entry with `lstat` and keeps only `:regular` and `:directory`, so every link
  (`:symlink`) is dropped: "skips … symlinks (no loops)" in the module doc. Reproduced 2026-11-22:
  git mode kept `link_to_file.txt` and `link_outside_file.txt` but not `link_to_dir`,
  `link_outside_dir` or an untracked `untracked_link_dir`; the walk kept none of the four.
- **Fix, as built:** a link to a file is a file; a link to a folder is a folder marked `↗`, listed
  when it is opened and one level at a time (the maintainer's choices, the second after
  geex-verifier's review found a whole-subtree listing walked `/usr`'s 104k files and would walk
  `/mnt/c` over WSL): a folder inside it is listed when opened, a link inside it is a link again,
  so nothing is followed on its own and no loop can run away. A reload keeps the open levels on
  screen and lists them again. ADR-0034 §5 amended.
- **Ruled out:** `Geex.Disk.regular?/1` itself: it follows links, so a linked file is kept in git
  mode as before BUG-22's change.

---

## BUG-23 — `search-project` crashed the loop through a link to a name past Latin-1  ✅ FIXED (2026-11-18)

- **Status:** **FIXED** 2026-11-18 on the branch `raw-files`, found by mod-verify's review of
  BUG-22. In **0.7.0** and before (since `search-project`'s link following, 2026-11-13).
- **Symptom:** `search-project hello` from a project reached through a link to a directory named
  with a character above U+00FF (`link -> projł`, `日本`), outside a git work tree (git's top level
  resolves links) or with a link in the home directory's path: "GenServer Geex.Loop terminating
  ** (ArgumentError) … :erlang.list_to_binary([112, 114, 111, 106, 322])" in the log. The loop was
  restarted and keys worked after, but the search never ran and nothing said so. A link to `café`
  came back as the Latin-1 byte 233, not UTF-8.
- **Verified cause:** `Geex.Search.Project.real_path/1` turned a link's target into bytes with
  `:erlang.list_to_binary/1`. `read_link_all/1` answers with a charlist of characters for any
  target it can decode in the file name encoding, and a binary only for one it can't, so the
  comment's "the target's raw bytes as a binary" held only for that case.
- **Fix:** the characters go back to the file name encoding's bytes
  (`:unicode.characters_to_binary(chars, :unicode, :file.native_name_encoding())`, mod-verify's).
  A test follows links to `projł`, `日本` and `café`; the old line fails it with the
  `ArgumentError`.

---

## BUG-22 — One file that hung stalled every file call in geex, and could leave no key working  ✅ FIXED (2026-11-18)

- **Status:** **FIXED** 2026-11-18 on the branch `raw-files`. Found 2026-11-17 by mod-verify's
  review of BUG-21's fix, which left it as "not done"; in **0.7.0** and before.
- **Symptom:** a clean open file replaced by a FIFO, the stand-in for a network disk that stalls.
  The watcher reads it, and the next `open b.txt` waits: no key works, Ctrl-X included, and only a
  signal ends geex (45.1 s after a SIGTERM from the `bug-21` build: the backstop's 35 s, then the
  watchdog's 10). With an edit first, Ctrl-O shows "saving a.txt…" for good, and the second quit
  leaves through the watchdog, 10 s later.
- **Verified cause:** BUG-21's. Elixir's `File` calls that aren't `:raw` go through OTP's one file
  server, `file_server_2`, which makes each call itself; the watcher's read of the FIFO
  (`Reconcile.on_disk_change/1`) held it, and the loop's `open` asks `File.exists?/1` through it.
  A probe in a plain VM with the server held by a read of a FIFO: `File.read`, `File.exists?`,
  `File.rm`, `File.ls`, `File.rename`, `File.mkdir_p`, `File.rmdir`, `File.cp`, `File.cwd`,
  `Path.expand/1` of a relative path, `System.find_executable/1`, `:filelib` and `Path.wildcard`
  wait, and so does `File.regular?(path, raw: true)` (the option is `[:raw]`, not a keyword);
  `:file.read_file(path, [:raw])`, `File.write(path, data, [:raw])`, `:file.read_file_info/2` and
  `:file.read_link_info/2` with `:raw`, `File.regular?/exists?/dir?(path, [:raw])`,
  `:file.delete(path, [:raw])`, `File.open(path, [:read, :raw])`, `File.stream!/1`, `:prim_file`'s
  `list_dir`, `rename`, `make_dir`, `del_dir` and `read_link_all`, and `System.cmd/3` of a full path
  answer at once.
- **Fix:** `Geex.Disk`. Geex's calls on the user's files (a buffer's load and save, reconcile's
  reads, the session's create, rename, delete and directories, the loop's and file ops' checks, the
  tree and its watcher, the preview's read, search's link following, `geex FILE`'s checks) run in
  the caller, `:raw`, or through `:prim_file` where `:file` has no raw form: a call that hangs
  holds only the process that made it. A FIFO, a device or a socket is never opened: `read/1` and
  `write/2` say `{:error, :not_regular}` at once (opening a buffer already left one empty). The
  watcher skips it; Ctrl-O says "not saved: the file is now a FIFO, a device or a socket",
  `fast-forward` "not read: …", the preview "not a regular file …". Geex's own files (the ledger,
  settings, the log, the last session) stay on `File`. A test fails if a module that touches the
  user's files calls `File`, `:file`, `:filelib` or `Path.wildcard`.
  [ADR-0035](adr/0035-the-loop-never-waits.md)'s 2026-11-18 amendment. Checked live: the `open`
  works and the quit takes 1.2 s under `mix run`, 0.06 s from a release; Ctrl-O says so at once.
- **Left as is:** a call on a disk that hangs still holds its own process. On a stalled network
  mount the loop's own checks (an `open`'s, and Alt+D's read, which runs in the loop) still wedge
  it, and the watcher's read holds the watcher, so no other file's change is seen until the disk
  answers. And only until ten calls hang: each keeps one of the VM's dirty I/O schedulers (10)
  until it returns, and with all ten held every other file call waits, the terminal's writes among
  them (mod-verify's probe: nine hung reads of FIFOs left the rest answering, ten stopped a raw
  stat, a raw write, `File.exists?/1` and `IO.puts/1` until released). The tree's read checks its
  files `System.schedulers_online/0` at a time (8 here), so one tree read on a stalled project
  disk takes most of them; a lower limit there is an option, not taken. Geex's own files on a
  stalled disk still go through the file server.

---

## BUG-21 — A disk that hung held geex's stop: 22 s from the installed binary, forever under `mix run`  ✅ FIXED (2026-11-17)

- **Status:** **FIXED** 2026-11-17 on the branch `bug-21`: the stop is bounded at 10 s. Found
  2026-11-16 on the branch `save-followups`, checking live a write that hangs (the maintainer's
  "if they exit again it forces the exit"). Any stop while a file read hangs, in **0.7.0** and
  before; `save-followups` didn't cause it (the earlier build of the branch in the scratch install
  behaves the same).
- **Symptom:** a file whose read never returns, a FIFO put in place of the open file standing in
  for a stalled network disk; an edit, Ctrl-O, then two quits. The save, stuck in its first read,
  is cancelled and the loop leaves at once, as designed, but the VM doesn't stop. From a release
  installed in a scratch directory: the last session's keep times out at 2 s, the tree's stop runs
  until 17 s (the terminal restored there), the VM halts at 22 s, and the ledger lock and the
  discovery file are left (both swept at the next start). Under `mix run`: the terminal restored
  at 17 s, and the VM still running a minute later (SIGUSR1 ended it).
- **Verified cause:** Elixir's `File.read/1`, `File.write/2`, `File.ls/1` and the like (not
  `:raw`) go through OTP's one file server, `file_server_2` (`file:read_file/1` →
  `check_and_call/2`), which does the read itself, in a dirty I/O NIF. One read that never returns
  (here `Reconcile.fast_forward/1`'s, the first thing a save does, and the watcher's after the
  file changed) holds that process, and every other such call in the VM queues behind it, with no
  time limit: the last session's write, the ledger's close and lock, the discovery file's removal,
  so each child of geex's tree that makes one is killed at its 5 s shutdown timeout. The crash dump
  shows the geex application gone and `file_server_2` `DIRTY_RUNNING` in `prim_file:read_file/1`,
  called from `file_server:handle_call/3`. Under `mix run`, `System.stop/0` (`init:stop/0`) then
  stops Mix's application, whose stop callback queues behind the read too (`Mix.stop/1` →
  `Mix.Local.remove_archives/0` → `File.ls/1`); neither its application master nor the
  application controller has a time limit (kernel's `shutdown_timeout` defaults to infinity), so
  init never gets as far as kernel (mod-verify's re-review, with a probe and no geex at all). In a
  plain `elixir` VM the same stuck read lets `System.stop/0` finish in 3.9 s: kernel's supervisor
  gives `file_server_2` its 2 s shutdown, then kills it. The binary's `Geex.CLI` stops geex's
  tree and then calls `System.halt/0`, so it does get out, after its children's timeouts.
- **Fix:** `Geex.StopWatchdog`. The loop arms it as it leaves, and so do `Geex.stop/0`, `Geex.CLI`
  on its quit and the signals' backstop; off under `mix test` (`stop_watchdog`). If the VM is still
  up 10 s after the quit, it asks `Geex.TerminalIO` to put the terminal back (`restore/1`), logs a
  warning and syncs the log (given 1 s), and halts with status 0. Its group leader is the VM's
  `user` process, not geex's application master, which kills every process it leads as the
  application stops; it makes no `File` call. `Geex.TerminalIO` finds `sh` once at start, since
  `System.cmd("sh", …)` looks it up through the file server and its `stty` waited behind the stuck
  read; once restored it draws nothing more. [ADR-0036](adr/0036-installed-binary.md)'s 2026-11-17
  amendment. Checked live, a FIFO in place of the open file, an edit, Ctrl-O and two quits: gone
  10.1 s after the second quit under `mix run` and from a release installed in a scratch directory,
  the terminal back; the loop itself wedged, SIGTERM: gone at 45 s (the backstop's 35, then 10). The
  ledger lock and the discovery file are still left (swept at the next start). Not done: the save's
  own read and write `:raw`, so one file that hangs wouldn't stall every other `File` call in geex
  until the stop. That stall can wedge the loop itself: a clean buffer whose file becomes a FIFO is
  read by the watcher, and the loop's next `File` call (an `open`) hangs, so no key works and only a
  signal ends geex, at 45 s (mod-verify's review; **fixed 2026-11-18 as BUG-22**, above). And
  `-shutdown_time` for `mix run`, which the watchdog makes needless.
- **Ruled out:** the save's write: the read before it hung first, the gate never reached, so the
  second quit cancelled the save and left at once. The loop: it painted and took keys throughout.
  A process that can't be killed (my first reading): `file_server_2` killed mid-read goes down at
  once, only its native call running on (mod-verify's probe; not a fix: kernel's supervisor is
  one_for_all with no restarts, so it would take kernel down).

---

## BUG-20 — Closing the terminal ended geex at once, and could cut a save's write  ✅ FIXED (2026-11-16)

- **Status:** **FIXED** 2026-11-16 on the branch `save-followups`, found answering the
  maintainer's question about shutdown during a save. The SIGHUP part is in **0.7.0** and every
  release before it; the tree coming down mid-wait was in `save-off-loop` (c397a70, local main,
  unreleased) once SIGHUP was handled.
- **Symptom:** closing the terminal window running geex (SIGHUP) ended the VM on the spot: the
  ledger lock and the attestation discovery file stayed (both swept at the next start), the last
  session was as the loop last kept it (at most 2 s old), and a write under way could be cut,
  leaving the file part-written. Checked with the installed 0.7.0 in tmux: `kill-server` left
  both files and no stop lines in the log.
- **Verified causes:** (1) SIGHUP's OS default terminates the process, and nothing asked for it
  (`elixir -e` with a `kill -HUP` of itself exits 129). (2) With SIGHUP handled, `Geex.TerminalIO`
  stopped `:normal` at the end of input; a permanent child, it was restarted into the same end of
  input until its supervisor gave up ("Application geex exited: shutdown"), taking the loop and the
  save it was waiting for with it. Under `mix run` five of five closes during a 10 MB save left the
  VM running with no application: `init` was never asked to stop (checked over distribution).
- **Fix:** `Geex.CLI.Signals.install/0` handles SIGHUP (`:os.set_signal/2`, once its handler is
  in) and `Geex.run/1` installs it too; SIGTERM and SIGHUP go to `Geex.Loop.shutdown/0`, the same
  leaving as the end of input: a save under way finishes, for up to 30 s, then the orderly stop.
  `Geex.TerminalIO` says `:eof` and stays (a later subscriber is told too). ADR-0035's and
  ADR-0036's 2026-11-16 amendments. Checked live: the terminal closed 0–0.6 s into a first
  trimming save of a 9.5 MB file left it whole every time, geex gone within 1.5 s, no lock or
  discovery file, under `mix run` and from a release installed in a scratch directory.

---

## BUG-19 — A rename into a directory that isn't there reported success and left the file  ✅ FIXED (2026-11-16)

- **Status:** **FIXED** 2026-11-16 on the branch `save-followups`. Found 2026-11-15 writing a test
  for `save-off-loop` (mod-verify's review of it). In **0.7.0** and before.
- **Symptom:** with `a.txt` open, `Session.rename_file("a.txt", "no/such/b.txt")` (the `rename`
  command, the tree's `r`, MCP's `rename_file`) answered `{:ok, …}`: the buffer was re-keyed to
  `no/such/b.txt` in memory while the file stayed at `a.txt`. The next save tried to write into the
  missing directory and failed.
- **Verified cause:** `File.rename/2` answers `:enoent` for a missing destination directory as it
  does for a missing source, and `Session.rename_file/2` read every `:enoent` as "a never-saved
  buffer has no file yet" (ADR-0019), re-keying an open buffer.
- **Fix:** `Session.rename_file/2` refuses a destination whose directory isn't there, before
  touching anything: `{:error, :no_directory}` (a rename makes no directory; `new` still offers to
  make its parents). The TUI says "not renamed: src/ doesn't exist" (or "lib/a.ex/ isn't a
  directory"); MCP's `rename_file` answers the error as it answers any other. The never-saved
  branch now also checks that the source really is missing (`File.lstat/1`), so a directory that
  vanishes between the check and the rename is an error too. Tests: `session_test.exs` (an open
  file, a never-saved buffer, a file as the directory), `file_ops_test.exs` (the words).
- **Ruled out:** nothing else re-keys on a failed rename.

---

## BUG-18 — A first save that trims every line's trailing whitespace stalled for seconds  ✅ FIXED (2026-11-15)

- **Status:** **FIXED** 2026-11-15 on the branch `bug-18`. Found 2026-11-13 measuring roadmap
  item 9 (saving off the key loop) for the maintainer. In **0.6.0** and **0.7.0** (the trim on
  save, ADR-0054).
- **Symptom:** a 10 MB file of 100,000 lines, each ending in a space, saved with "Trim trailing
  whitespace" on (the default, ADR-0054): `Buffer.save` took 3,561 ms, against 78 ms for the
  same save without the trim and about 200 ms for a later one with nothing left to trim. It runs
  inside the buffer process, so the key loop and every frame wait for it (ADR-0035). A 2 MB file of
  20,000 such lines took 1.8 s under eprof (not timed without it).
- **Verified cause:** `Geex.Buffer`'s `trim_line/1`. For each line whose body ends in a space or
  a tab it split the whole line into graphemes (`Geex.Text.graphemes/1`), reversed, dropped the
  trailing ones and joined. eprof on the 2 MB file: 2,000,000 `String.do_graphemes` and
  `unicode_util:gc` calls take about half the save's time, `Enum.map`, `reverse` and
  `entry_to_string` most of the rest; the `Replace` itself and the blame are small beside it.
  The cost was the line's length, paid on every line that has trailing whitespace, not on the
  whitespace.
- **Fix:** `Geex.Text.trim_trailing_blanks/1` (the per-line trim, moved from `Geex.Buffer`, same
  results) finds the trailing run of space and tab *bytes* and cuts it. Only the run's edge can be a
  grapheme that isn't whitespace: a space a Prepend character just before it joins (a tab is a
  control and never joined), so when the byte before the run isn't ASCII the segmenter is asked
  about the last 4 bytes and the first space alone. At 10 MB the trimming save now takes 300 ms
  against 112 ms without the trim (3,248 ms before; the same machine and script, a buffer with a
  ledger as a real one has); the trim itself is 16 ms for the 100,000 lines. The rest is the one
  replace, its history entry and ledger line, and the write, all inside the buffer; item 9 would
  move the write out. Guards: a property against the old grapheme walk (with a 4-byte Prepend,
  which fills the whole tail: mod-verify's review), and 10,000 lines of 1,000 bytes trimmed
  within three times 10,000 short lines with the same end, plus 20 ms, the fastest of three (the
  old walk: 583 ms against a 25 ms bound).
- **Ruled out:** the write (78 ms) and the conflict-block scan (71 ms, in the caller).

---

## BUG-17 — A long line holding an emoji or © before an invalid byte froze every key on it  ✅ FIXED (2026-11-13)

- **Status:** **FIXED** 2026-11-13 on the branch `search` (slice A), found by mod-verify's review
  of that slice. In **0.6.0**; fixed in **0.7.0** (the maintainer chose a 0.7.0 from main over a
  0.6.1 patch).
- **Symptom:** on a Latin-1 line of 256 KB with one `©` + invalid byte at its start, each Right
  arrow took 19–21 s (55–65 ms without the pair); `Text.length` alone took 3.8 s. Search on that
  line took 4 s, and on a 1.5 MB line of such pairs ran for minutes.
- **Verified cause:** `Geex.Text.chunked/1`, the fallback for where `String` raises, was
  body-recursive with a list append per invalid byte: quadratic in the number of invalid bytes.
  It runs on any line holding an Extended_Pictographic right before an invalid byte, and
  `Keymap.line_len` and Session's cursor clamp call `Text.length` on the cursor's line every key.
- **Fix:** a tail-recursive `chunked` (accumulate, reverse once) with identical output, and
  `Text.length` counting without building the list. A guard: that 256 KB line's `Text.length` and
  `Text.graphemes` within three times the clean line's.

---

## BUG-16 — The markdown preview couldn't render a file holding a byte that isn't UTF-8  ✅ FIXED (2026-11-16)

- **Status:** **FIXED** 2026-11-16 on the branch `save-followups`. Found 2026-11-12 by mod-verify's
  review of `crash-fixes` (216e97b). In **0.6.0** and **0.7.0** (the preview, ADR-0043).
- **Symptom:** opening the preview (`Alt+P`) of a Markdown file with a Latin-1 byte or any other
  byte that isn't UTF-8 showed "render failed (see the log)" instead of the rendered file. The
  editor itself draws and edits the file (BUG-15); only the preview gave up, gracefully.
- **Verified cause:** `Geex.Markdown.Parse` hands the file's text to `TreeSitterWasm.highlight/2`
  (`lib/geex/markdown/parse.ex`), which raises (`ArgumentError`) on text that isn't UTF-8 before
  any of geex's own layout runs; the preview process catches it and reports the render failed.
- **Fix:** `Geex.Markdown.parse/2` turns each invalid byte into U+FFFD
  (`String.replace_invalid/1`) where it already turns `\r\n` into `\n`, so the tree and the layout
  both index the same text. No newline moves, so each row still names its source line (`Place`).
  Test: `layout_test.exs`, a heading, bold text, a list item and a code block each holding the
  byte render as the same file with `?` in its place, U+FFFD shown, the same source lines.

---

## BUG-15 — An invalid UTF-8 byte on screen could crash a paint  ✅ FIXED (2026-11-12)

- **Status:** **FIXED** 2026-11-12 on the branch `crash-fixes`, at the maintainer's word; found the
  same day by mod-verify's review of `long-lines` (9c718bd). Older than that branch. Verification
  is in the [testing.md](testing.md) 2026-11-12 entry "BUG-14, BUG-15 and the compaction counts".
- **Fix:** `Geex.Text` gives `String`'s grapheme functions (graphemes, next_grapheme, length,
  split_at, slice, at, last) that return exactly what `String`'s do, and only where OTP's
  segmentation raises (an emoji right before an invalid byte) segment the valid stretches as
  `String` does with each invalid byte a grapheme of its own, the rule Elixir already follows
  elsewhere (`String.graphemes("caf\xE9")` is four graphemes). Width, Paint, Screen, Doc, Coord,
  Keymap and the loop's cursor helpers use it. `Width.cells/1` counts an invalid byte as one
  column, `Screen.put_grapheme/4` draws it as `�`, so no bad byte reaches the terminal, and
  Keymap's `word?/1` no longer runs a Unicode regex on one (it raised on any invalid byte, so
  typing next to a Latin-1 `é` crashed). `Width.seek/3` checks a column target before measuring
  the grapheme there (mod-verify's note). ADR-0027's 2026-11-12 amendment.
- **Symptom:** a line holding a byte that isn't UTF-8 (a binary file opened by mistake, a file in
  Latin-1), drawn on screen, can raise inside the paint instead of drawing.
- **Verified cause:** `Geex.Width.advance/3` → `Width.cells/1` → `String.to_charlist/1` raises
  `UnicodeConversionError` on an invalid byte (`Width.advance(<<0xFF>>, 0, 2)`); and OTP's
  grapheme walk raises `ArgumentError` on an emoji followed by invalid bytes
  (`String.next_grapheme("👍" <> <<0xFF, 0xFE>>)`, `String.graphemes/1` the same). The paint, the
  cursor's display column and the widest line all walk graphemes and measure them.
- **Recommended fix:** make the width total: `Width.cells/1` counts a grapheme that isn't valid
  UTF-8 as one column (a replacement glyph's width), and the walkers step past a byte that won't
  segment one byte at a time (a `rescue ArgumentError` around `String.next_grapheme/1`, or checking
  `String.valid?/1` on the slice first), drawing `�` for it, as the input path already replaces
  invalid bytes (BUG-11). A property over `Geex.Gen` text with random invalid bytes would pin it.

---

## BUG-14 — Alt+Z after an MCP `edit` command crashed the loop  ✅ FIXED (2026-11-12)

- **Status:** **FIXED** 2026-11-12 on the branch `crash-fixes`, at the maintainer's word; found the
  same day by mod-verify's review of `long-lines` (9c718bd). Verification is in the
  [testing.md](testing.md) 2026-11-12 entry "BUG-14, BUG-15 and the compaction counts".
- **Fix:** the buffer's undo and redo reply carries where the text changed (`changed`: the start
  and end of the splice between the texts before and after, from `Footprint.between/2`, in the
  text left), and the loop places the cursor by it for any command with no coordinates of its own:
  the start for an undo, the end for a redo. The buffer's choice of a step's topmost command puts
  such a command after any with coordinates. The MCP surface is untouched (ADR-0032).
- **Symptom:** undoing (or redoing) a command recorded by the MCP `edit` tool
  (`Geex.Commands.Edit`, search/replace blocks) raises `FunctionClauseError` in the loop. Reachable
  by reopening in the TUI a file whose ledger holds an edit made under `mix geex.serve`.
- **Verified cause:** `Geex.Loop.do_undo/1` and `do_redo/1` place the cursor with
  `edit_start/1` and `edit_landing/1` (`lib/geex/loop.ex`), which have clauses for `Insert`,
  `Delete` and `Replace` only. `Buffer.undo/1` returns the command it undid, and an `Edit` carries
  no coordinates of its own (it resolves its blocks against the text when it runs).
- **Recommended fix:** a clause for any other command that places the cursor where the text
  changed: the first position at which the text before and after the undo differ (a common-prefix
  scan of the two texts, which `Buffer.undo/1` already has), falling back to the cursor's own
  position clamped to the text. A test: dispatch an `Edit`, then `Alt+Z` and `Alt+Shift+Z` through
  `Loop.handle_info/2`.

---

## BUG-13 — Every frame painted the whole of a long line  ✅ FIXED (2026-11-12)

- **Status:** **FIXED** 2026-11-12 on the branch `long-lines`, at the maintainer's word; found the
  same day measuring BUG-12. Older than that branch: main painted the same way. Verification is
  in the [testing.md](testing.md) 2026-11-12 entry "BUG-12 and BUG-13: a long line costs its
  screen".
- **Symptom:** a file with one 2 MB line (minified JS or JSON, a log line): every repaint took
  about 2.3 s, whatever the key, so on that line every key felt that slow.
- **Verified cause:** an `:eprof` profile of one repaint: `Geex.Highlight.Paint.to_screen/10`
  placed every one of the line's 2.1 million graphemes and `Geex.Width.cells/1` ran 6.3 M times
  (the line split into graphemes and measured three times over: the paint, the cursor's display
  column in `Loop.cursor_xy/4`, the widest line in `Loop.max_line_width/2`), though 100 columns
  of it showed.
- **Fix:** `Geex.Width.seek/3` finds a grapheme column or a display column on a line measuring
  its ASCII up to its first other character by its bytes (only its tabs and control characters
  one by one) and walking the rest a grapheme at a time, as before, with its byte patterns
  compiled once (`Geex.Ascii`); `Width.line/2` and `Width.col_at_display/3`
  (the mouse's cast) use it, and so does `Loop.cursor_xy/4`. The paint takes, of each row, the
  graphemes from the first that draws into the horizontal scroll's column to the last that
  starts before the right edge, resolves the spans over those bytes only, and asks the reactor
  for the spans over them only (`Paint.visible_ranges/6`, `frame/11` taking a function of the
  ranges). A repaint of the 2 MB line takes 11 ms.

---

## BUG-12 — Far into a very long line, a word motion or an editing key stalled the key loop  ✅ FIXED (2026-11-12)

- **Status:** **FIXED** 2026-11-12 on the branch `long-lines`, at the maintainer's word. Found
  2026-11-12 by mod-verify's review of ADR-0052 (`editing-keys`); older than that branch (`Alt+O`
  on main took as long). Verification is in the [testing.md](testing.md) 2026-11-12 entries
  "BUG-12: a long line read near the cursor" and "BUG-12 and BUG-13: a long line costs its
  screen".
- **Symptom:** on one 2 MB line, with the cursor near its end, `Alt+O`/`Alt+U` took about 0.4 s,
  `Alt+8` and the sideways moves about as long, `` Alt+\ `` 0.7–0.9 s, and a typed character,
  Enter or Backspace 0.5–1.4 s. Every key waits behind it (ADR-0035).
- **Verified cause:** the line was split into graphemes from its start: `Keymap`'s line helpers
  (`line_tuple/2`, `String.at/2` and `String.slice/3` in `matching_bracket/2`), the typing
  assists (`autoclose/5`'s `String.slice/3` and `String.last/1`, `newline/4`'s, `dedent/3`'s,
  `unpair/3`'s `String.at/2`, `leading_whitespace/1`), and `Geex.Buffer.Doc`'s insert, delete,
  replace, slice and byte offset, which split the edited line into a grapheme list.
- **Fix:** `Keymap` reads a line over 4 KB through a window of 1,024 graphemes each side of the
  columns a key needs (`on_window/4`), running again on the whole line when a read reaches a
  side of the window that isn't the line's, so no answer depends on the window; an ASCII line is
  cut by bytes, another walked with `String.split_at/2`. `` Alt+\ `` reads from the cursor and a
  long line above it from its end. The typing assists read the characters either side of the
  cursor (`around/2`), a line's leading whitespace by its bytes, and the line before the cursor
  only for a quote (ASCII by its quotes and backslashes). `Doc` cuts a line at a column by its
  bytes when it is ASCII up to there, else with `String.split_at/2`, with the same results (its
  property holds it to the grapheme lists).
- **What remains:** a non-ASCII long line still costs a walk up to the cursor in `Keymap` and
  `Doc` (`String.split_at/2`: 40–80 ms at 2 MB, was 0.3–1 s), and up to the horizontal scroll in
  the paint (a grapheme at a time past its ASCII runs). The comment toggle (`Alt+/`) and Tab's
  indent still read the whole line, which they rewrite anyway.

---

## BUG-11 — A byte that isn't UTF-8 makes the input go deaf, Ctrl-Q included  ✅ FIXED (2026-11-09)

- **Status:** **FIXED** 2026-11-09 on the branch `editor-assist` (roadmap item 19), at the
  maintainer's word; found the same day by session geex-d3's review of item 19, live in tmux.
  Older than that branch (main at c3f6f58 has it). Verification is in the
  [testing.md](testing.md) 2026-11-09 entry "typing assists: geex-d3's review answered".
- **Symptom:** type `x` (it shows), send one byte `0xff` (`tmux send-keys -H ff`, or paste
  binary), then `y`: the `y` never shows, and no key, Ctrl-Q included, is read again.
- **Verified cause:** OTP's `:prim_tty` reader (28.1, `prim_tty.erl` `reader_read/2`), meeting
  bytes that don't decode as UTF-8, sends its parent `{reader_pid, set_unicode_state, false}`
  and blocks until it gets `{set_unicode_state, false}` and then `{parent, set_unicode_state, _}`.
  `Geex.TerminalIO`, the parent, dropped the request in its catch-all `handle_info/2`.
- **Fix:** answer it as OTP's `user_drv` does: `:prim_tty.unicode(tty, false)` (which tells the
  reader), `{self(), :set_unicode_state, true}` to the reader, then `:prim_tty.unicode(tty, true)`
  to read UTF-8 again (`TerminalIO.answer_unicode/3`). The stray byte arrives as its Latin-1
  character.
- **Ruled out:** the parser. The bytes never reached it; the reader was blocked before sending.

## BUG-10 — A tab character draws zero columns wide, so tab-indented files lose their indentation  ✅ FIXED (2026-11-09)

- **Status:** **FIXED** 2026-11-09 by roadmap item 18.7 (ADR-0027's 2026-11-09 amendment), on the
  `editor-comfort` branch. Verification is in the [testing.md](testing.md) 2026-11-09 entry
  "editor comfort". Found the same day while looking at the maintainer's tab-size ask.
- **Symptom:** a Go file (or a Makefile) indented with tabs shows every line flush left: `\tfmt.Println`
  draws as `fmt.Println`. Seen live in tmux.
- **Verified cause:** `Geex.Width.cells/1` gives a control character, `\t` included, zero columns,
  so `Width.string("a\tb") == 2` and the painter lays the line out without the tab.
- **Fix:** a tab's width depends on where it starts: the columns to the next tab stop of the
  tab-size setting. The width walks (the painter, `cursor_xy`, `col_at_display`, the mouse) learn
  it; addressing stays by grapheme (ADR-0027), so a wrong width mis-renders, never mis-addresses.
- **Ruled out:** loading. `EditorState.new/1` keeps the tab (the text round-trips byte for byte).

## BUG-9 — An attestation didn't relabel the blame a compacted ledger's checkpoint carries  ✅ FIXED (2026-11-09)

- **Status:** **FIXED** 2026-11-09, at the maintainer's word (relayed by session geex-d3): the
  recommended fix below. Verification is in the [testing.md](testing.md) 2026-11-09 entry
  "BUG-9: an attestation credits a checkpoint's lines". Found the same day by a verify pass over
  ADR-0044 (session geex-d3). Very rare: it needs a compaction that splits a reconcile group
  (some of its commands folded into the checkpoint, some still recorded), a restart (compaction
  refuses while a running geex has the ledger open, so a history only starts from a checkpoint
  after a reopen), then a late attestation for that group.
- **Symptom:** `History.from_checkpoint("a\nb", [{:external, 7}, {:external, 7}], "a\nb", 8)`,
  a command of group 7 on line 1, `attest(h, 7, agent)`: both lines show the agent. Then any
  edit and its undo: line 0 showed `{:external, 7}` again, and `unattested?(h, 7)` was false, so
  a repeat attestation was ignored and the line stayed an outside change.
- **Verified cause:** `History.attest/3` relabelled `blame` and the commands but not `base_blame`;
  `undo/1` rebuilds the blame from `base_blame` plus the remaining commands
  (`Blame.replay(h.base, …, h.base_blame)`), so the checkpoint's lines of the group came back as
  they were.
- **Fix:** `base_blame: Blame.relabel(h.base_blame, group, actor)` in `History.attest/3`. The
  ledger replays `{:attest, …}` through the same function, so restore stays equal to live. The
  example above is a test (`history_test.exs`), and a property compacts a split group through the
  real `Ledger.Compact` rewrite and checks that attesting commutes with undo and redo. The fix
  also keeps a later compaction honest: `Compact.entries` replays the folded commands from
  `base_blame`, so without it a second compaction after such an attestation would have written
  the lines `:external` and `Compact.check` would have refused it ("blame differs"). Ledgers
  written before the fix restore such a checkpoint line as credited where the live session had
  shown `:external`: a correction.
- **Known limit, not this bug:** a compaction that folds **every** command of a group into the
  checkpoint drops the group's stamp, so a late attestation finds no group and is lost, even for
  the newest write. Older than this fix and very rare (close, compact, reopen, then the late
  attestation).
- **Ruled out:** compaction itself (`Ledger.Compact` writes the blame it replayed, correctly).

---

## BUG-8 — A late attestation missed the undone hunks of its group  ✅ FIXED (2026-11-09)

- **Status:** **FIXED** 2026-11-09, in two steps. Found by the history property's new law, "a
  reconcile group's commands carry one actor" (ADR-0044 §8.2), on the first of five runs (the
  law alone catches it on about 3 seeds in 10 at 100 runs). Fixed for a **partly** undone group
  in the same commit (`ff1e66b`); a verify pass (session geex-d3) then found the **fully**
  undone case still open, fixed the same day; its recheck found the first version of that fix
  let an attested undone group shadow an applied one, also fixed. Verification is in the [testing.md](testing.md)
  2026-11-09 entries "property tests, slice 2" and "the verify pass".
- **Symptom (partly undone):** a reconcile group of two hunks; undo one; the attestation arrives
  and matches (the group's stamp is on the hunk still applied); redo. The redone hunk's line
  shows as an outside change while the rest of the group shows the agent, and a repeat
  attestation is ignored, because `History.unattested?/2` finds the group partly credited.
- **Symptom (fully undone):** undo both hunks before the attestation arrives: it is `:held` (no
  applied group matches), never links at the next fast-forward (the held entry starts from the
  text before the group, the chain from the disk after it), and is dropped; the redo brings both
  hunks back `:external`. ADR-0032 step (e)'s "an undone hunk loses its mark, and redo restores
  it" didn't hold after a late attestation in either case.
- **Verified cause:** `History.attest/3` mapped over `h.commands` only, so an undone hunk waited
  on `h.redo` with its old actor; and `Buffer.attest/2` matched only `History.newest_group/1`,
  which scans the applied commands, so a fully undone group wasn't attestable at all. The shrunk
  counterexample (partly undone): base `""`, the disk becomes `"a"` (group 1), then `"\na\n"`
  (group 2, two hunks), undo, attest group 2, redo: group 2's actors were `[:external, agent]`.
- **Fix:** `History.attest/3` relabels `h.redo` too; `History.attestable_groups/1` gives the
  stamps an attestation may match, the newest undone group first, then the newest applied one;
  `Buffer.attest/2` credits the first that matches and is still unattested, so an attested
  undone group with the same hashes doesn't shadow the applied one (the recheck's
  counterexample, now an example test) and nothing that matched before stops matching;
  `unattested?/2` counts undone commands. As before, only the newest write's group is tried
  among the undone ones: undo two groups in full, and a late attestation for the older is still
  held and lost, under ADR-0032's "only the newest group". The ledger replays `{:attest, group, actor}`
  through `History.attest/3`, so a restored history matches the live one. Ledgers written
  before the fix restore an attest-then-redo with the redone hunk credited, where the live
  session had left it `:external`: a correction. Examples in `history_test.exs` and
  `attest_test.exs`; a targeted property (below) catches either half of the fix removed on 10
  seeds in 10.
- **Ruled out:** the hashes. The attestation matched the stamp correctly.

---

## BUG-7 — After a terminal resize, stale text stays in the cells the new frame leaves blank  ✅ FIXED (2026-11-06)

- **Status:** **FIXED** 2026-11-06 on the branch `markdown-preview`, at the maintainer's word
  ("yeah fix bug 7 too"): `Renderer.handle_cast({:resize, …})` now resets the model to
  `Screen.new(0, 0)`. Verification is in the [testing.md](testing.md) 2026-11-06 entry "BUG-7:
  a resize redraws the whole screen". Found 2026-11-06 while dogfooding the markdown preview
  (ADR-0043 slice 5); not the preview's: main (`464bd3b`) did the same.
- **Symptom:** in tmux, `resize-window` from 120 to 96 columns leaves the old text in every cell
  the new frame draws blank, so rows read like `1 Agent intro line. line.` and
  `3 # Previewrtestw##est ##`. It stays until something draws over those cells; Esc or another
  repaint doesn't clear it. The log is clean.
- **Verified cause:** `Geex.Renderer.handle_cast({:resize, w, h}, …)` sets the model of the
  terminal to `Screen.new(w, h)`, a blank screen **of the new size**. The next flush's `diff/2`
  then sees equal dimensions, so it takes the incremental path: no `\e[2J`, and every cell blank
  in the new frame matches the blank model and isn't written. But the terminal isn't blank
  after a resize (tmux reflows what was there), so the old text stays in those cells. The
  moduledoc's own contract ("Dimension changes (initial flush, terminal resize) emit `\e[2J`") is
  what breaks.
- **Recommended fix:** reset the model to `Screen.new(0, 0)` on resize, as `init/1` does, so the
  next flush sees new dimensions and clears and redraws everything. Tried in a throwaway
  worktree of main: the same resize then draws a clean frame. A renderer test should assert that
  the flush after `resize/2` starts with `\e[2J`.
- **Ruled out:** tmux's window and pane really are 96 wide after the resize (`#{pane_width}`),
  and geex lays out at 96 (its tab bar's `×` is at the new right edge), so it isn't a missed
  SIGWINCH.

---

## BUG-6 — The installed binary carried every earlier geex release, the bundled grammars included  ✅ FIXED (2026-10-18)

- **Status:** **FIXED** 2026-10-18. `mix geex.deploy` removes `_build/prod/rel/geex` before
  building, and Burrito's working copy after. Verification is in the
  [testing.md](testing.md) 2026-10-18 entry "BUG-6: one release in the binary". Found by the
  coordinator session in the unpack of `0.1.0+1cbe3f34.89a87236`, the first "bare" binary.
- **Symptom:**
  - The unpack's `lib/` held 23 `geex-0.1.0+<sha>` application directories, one per deploy since
    the first (`.dirty` builds too). That is 46 MB of a ~114 MB unpack and a 22.3 MB binary,
    growing with each deploy.
  - Several still carried `priv/grammars/{elixir,json}` and `priv/themes/birds-of-paradise.json`.
    So the bare binary redistributed them, and without the NOTICE entries, which now name only
    the catalog and the test fixtures.
- **Verified cause:** `mix release` keeps the releases already in `_build/prod/rel/geex/{lib,
  releases}` beside a new one, and every build's version differs (it names the commits). Burrito
  packs the whole release directory. The boot script names one release, so the old ones were
  never loaded: a cost and a licence problem, not a correctness one.
- **Also found:** Burrito's working copy of each build, `/tmp/burrito_build_*` (~120 MB), was
  never removed: 15 from this one day's deploys. The deploy now removes the ones its build made,
  found by listing before and after, so another project's build isn't touched.

---

## BUG-5 — Flaky: the reconcile quiet-period test finds the buffer behind an *empty* file  ✅ FIXED (2026-10-18)

- **Status:** **FIXED** 2026-10-18: a test timing assumption, not a product bug. The cause and
  the verification are in the [testing.md](testing.md) 2026-10-18 entry "BUG-5: the
  quiet-period test assumed a deadline". `reconcile_test.exs:299` once found the buffer behind
  `""` inside its reconciler's 150 ms quiet period (seed 125550).
- **Verified cause:** the test's own reconciler, its quiet period running out as designed while
  the test process was descheduled past 150 ms. Reproduced under CPU load with the test alone.
  - A stall mid-`File.write!`, after the truncate and before the bytes, reads `""`: the first
    sighting.
  - A stall after both writes reads the final bytes: the reproduction (sha of "v2 done\n").
  - A probe in `Buffer.disk_changed/2` ruled out any other caller.
  - The suspect noted here before, `session_test`'s reconciler with a real inotify backend, is
    a hazard but not this cause. It is stubbed now too.

---

## BUG-4 — A deploy deletes the unpack a running geex runs from, and that geex crashes  ✅ FIXED (2026-10-18)

- **Status:** **FIXED** 2026-10-18. `mix geex.deploy` keeps any unpack a running process uses,
  and `geex.prev`'s. Verification is in the [testing.md](testing.md) 2026-10-18 entry "A deploy
  keeps the unpack a running geex uses (BUG-4)". Found by the coordinator session: the deploy
  of `dcce38b` crashed the maintainer's open `geex .`.
- **Symptom:** the maintainer's geex (`0.1.0+839c64cb`, started from the installed binary)
  died during a deploy. The terminal filled with "DEFAULT FORMATTER CRASHED" and the UI stopped
  answering. The VM was still alive and quit on SIGTERM, cleanly (discovery file removed, no
  ledger locks left).
- **Verified cause:** the deploy's prune (`prune_unpacks/1`) removed every `geex_erts-*` but the
  new build's, `geex_erts-16.1_0.1.0+839c64cb` included, which that geex ran from. A running
  VM loads modules from its unpack as it first needs them (interactive mode), so the next ones
  were missing: `{undef, [{sys, get_log, …}]}` in ThousandIsland's shutdown, and
  `io_lib_pretty` `nofile` in the logger's formatter, whose crash report went to the
  terminal. The earlier note "restart running editors after a deploy" assumed only an unloaded
  grammar would fail.
- **Fix:** the prune skips an unpack named by a process's `/proc/<pid>/exe` (Burrito's
  `beam.smp` lives in the unpack) or by a path in its `cmdline` (`-root <unpack>`), and
  `geex.prev`'s. The removal of the new build's own unpack, before its first run, is skipped
  the same way for a committed build (the same code); a dirty one stops the deploy.

---

## BUG-3 — Ctrl-C kills geex outright: the terminal, the ledger lock and the discovery file are left behind  ✅ FIXED (2026-10-16)

- **Status:** **FIXED** 2026-10-16. `Geex.TerminalIO` runs `stty -isig -ixon` on the tty after
  `:prim_tty` takes it, and puts the earlier settings back on exit. Verification is in the
  [testing.md](testing.md) 2026-10-16 entry "Ctrl-C and the other tty keys reach
  geex (BUG-3)". Found by the coordinator session while checking the installed binary (ADR-0036). It
  happened the same under `mix run`, so the binary didn't cause it.
- **Symptom:** Ctrl-C in geex didn't quit through the keymap. The VM died at once, and the shell
  that ran it died of SIGINT too (`tmux` reported the pane dead by signal 2). Nothing's
  `terminate/2` ran, so:
  - the terminal stayed on the alternate screen;
  - `$XDG_RUNTIME_DIR/geex/<pid>.json` was left behind;
  - an open buffer's `<key>.lock` stayed in the ledger directory;
  - unsaved edits were lost.

  Ctrl-Z (SIGTSTP) suspended geex with the frame and raw mode left on screen, and `kill %1`
  couldn't end it: the coordinator saw it under the binary, and a `mix run` geex of the
  maintainer's sat suspended for hours holding `ansi.ex`'s ledger lock. Ctrl-\\ (SIGQUIT) ended
  the VM with no restore. Ctrl-S (XOFF) froze the screen, and Ctrl-Q (XON), a quit key, never
  reached geex.
- **Verified cause:** `:prim_tty`'s raw input mode turns off `icanon` and `echo` but leaves `isig`
  and `ixon` on. Checked with `stty -F <pane tty> -a` while geex ran: `ixon isig -icanon
  -echo`. So the terminal turned Ctrl-C into SIGINT for the foreground process group, and the
  keymap never saw the byte. With `+Bd` the break handler is off, so SIGINT ended the VM with no
  cleanup.
- **Fix notes:**
  - `stty` runs on the VM's own stdin device (`/proc/<pid>/fd/0`), because a port's child has no
    controlling terminal and can't open `/dev/tty`.
  - After SIGCONT, `:prim_tty` sets its raw mode again, so `TerminalIO` turns the keys off again.
  - Bytes 0 and 28–31 (Ctrl-@, Ctrl-\\, Ctrl-], Ctrl-^, Ctrl-_) now parse as Ctrl keys. They
    used to come through as text, so Ctrl-\\ would have typed a control byte into the buffer.
  - The minibuffer quits on Ctrl-Q and Ctrl-C as well as Ctrl-X, like the editor and the panes.
- **Ruled out:** the binary. `mix run` with `--erl "-noshell -noinput +Bd"` behaved the same.

---

## BUG-2 — Flicker at the line tail while typing (the highlighter's two-pass)  ✅ FIXED (2026-06-09)

- **Status:** **FIXED** — the optimistic highlight-overlay shift. Verified: 503 tests + 9
  doctests green, adversarially reviewed (5 findings fixed), live-smoked. See the
  [testing.md](testing.md) 2026-06-09 entry.
- **Symptom (user-reported, after BUG-1):** "when I type a character, the end characters or
  close to the end characters per line flicker a little bit." Confirmed by the user: typing in
  a **no-grammar scratch buffer does not flicker** — so it's the highlighter, not the renderer.

**Verified cause.** Every keystroke triggers two repaints. The **immediate** one (so the typed
char appears with no latency) painted with the highlight spans computed for the *previous* text
— but spans are **byte offsets** ([`Span`](../lib/geex/highlight/span.ex)), and the edit shifted
every byte after the cursor. So the colours past the edit point were misaligned by the edit's
byte delta for one frame, until the **async re-highlight** ([`Reactor`](../lib/geex/highlight/reactor.ex))
landed and corrected them. Misalignment clusters at token boundaries → "the end characters
flicker." The loop even had the overlay's version available but discarded it.

**Fix (carry the edit, shift the overlay optimistically).** The buffer now emits the edit's
**byte footprint** `%{at, removed, added}` on its change event ([`Geex.Edit.Footprint`](../lib/geex/edit/footprint.ex)
+ [`Doc.byte_offset/2`](../lib/geex/buffer/doc.ex)) — on the *event*, so it covers human, agent,
and reconcile edits alike. The reactor shifts its overlay across the footprint
([`Span.shift_all/2`](../lib/geex/highlight/span.ex)) into an **optimistic** overlay served by a
new `render/1`, which the loop paints — so the immediate frame is already colour-aligned. The
exact re-highlight then supersedes it. `highlights/1`/`await/3` stay exact (tests unperturbed).

**Adversarial review fixed 5 issues** (4 dimensions, 14 agents): the span-shift boundary was
asymmetric-wrong (a char typed at a token's *start* stretched the token over it — fixed with
`shift_start` strict-`<` / `shift_end` inclusive-`<=`); an `:unknown` footprint (the multi-block
`edit` tool) regressed the overlay buffer-wide (now retains the prior overlay); plus two low items
(the loop's two-read version-skew window — documented; a stale `subscribe/2` docstring — fixed).

**Lays the groundwork for incremental reparse:** the same `{at, removed, added}` is what
tree-sitter's `Tree.edit` needs — a deferred ADR-0022 optimization.

**Deferred (low):** version-reconcile the loop's two reads (text@Session vs spans@Reactor) so a
concurrent MCP/reconcile edit can't briefly pair mismatched versions — documented at the read
site, one-frame self-correcting, not worth a guard yet.

---

## BUG-1 — Flicker while typing  ✅ FIXED (2026-06-09)

- **Status:** **FIXED** — `Geex.Renderer.frame/3` (atomic frames via DEC 2026 + conditional
  show/position cursor). Verified: 466 tests + 9 doctests green, live-smoked in tmux. See the
  [testing.md](testing.md) 2026-06-09 entry. *Visual "flicker gone" confirmation is the user's
  to make — `capture-pane` can't show intermediate frames.* The diagnosis + fix below are kept
  as the record.
- **Symptom (user-reported):** visible flicker/jitter on each keystroke.

**What it is NOT** (ruled out by reading the render path):
- **Not a full-frame repaint.** `Geex.Renderer` is a true damage/diff renderer — `diff/2`
  compares the prev/next `Screen` cell-by-cell and emits only changed cells, grouped into
  runs ([renderer.ex:77-86](../lib/geex/renderer.ex#L77-L86), `diff_row`/`group_runs`).
- **Not clear-then-redraw.** `\e[2J` is emitted **only** on a dimension change (initial
  flush + resize), never on a keystroke ([renderer.ex:84](../lib/geex/renderer.ex#L84)).
- **Not many small writes.** Each frame is a single `:prim_tty.write` of one iolist
  ([renderer.ex:175](../lib/geex/renderer.ex#L175) → [terminal_io.ex:133](../lib/geex/terminal_io.ex#L133)).
- **Not the wide-glyph continuation cell.** Emitting `""` for the right half of a wide
  glyph is intentional and correct ([cell.ex:17-21](../lib/geex/cell.ex#L17-L21)); the
  terminal advances two columns for the lead glyph, so position stays correct. Checked —
  not the cause.

**Verified root cause (the honest, post-adversarial picture).** The frame is a *single
atomic* `:prim_tty.write` with the cursor emitted **last by deliberate design**
([renderer.ex:48-52](../lib/geex/renderer.ex#L48-L52)), so the early "visible cursor
teleports across each changed run" theory does **not** hold — intermediate CUP moves inside
one write are not independently presented. Two genuine, code-grounded causes remain:

1. **No synchronized output.** There is no `\e[?2026h … \e[?2026l` (Begin/End Synchronized
   Update) anywhere in `lib/` (grep: zero hits). A keystroke frame can touch several
   non-adjacent runs (edited text + the status col counter, and on a line-change the
   active-line background + possibly the gutter). A large enough frame can be **presented
   torn** across the terminal's refresh boundary → flicker. *This is the primary cause.*
2. **Unconditional show-cursor every frame.** `cursor_seq({x,y})` re-emits `\e[?25h` on
   **every** frame ([renderer.ex:94-95](../lib/geex/renderer.ex#L94-L95)) even when the
   cursor was already visible and didn't move — which can **reset the cursor blink state**
   each keystroke and read as cursor flicker on some terminals.

**Recommended fix (in order):**
1. **Wrap each frame in synchronized output** — prepend `\e[?2026h` and append `\e[?2026l`
   around the `[diff, cursor_seq]` iolist in `flush/1` and `flush/2`
   ([renderer.ex:164-177](../lib/geex/renderer.ex#L164-L177)). Terminals that support DEC
   2026 (kitty, foot, recent iTerm2, WezTerm, Ghostty, Windows Terminal) present the frame
   atomically; others ignore the unknown private mode, so it is always safe to emit. Keep
   the existing "skip the write when `diff == []` and the cursor is unchanged" fast path so
   idle frames still cost nothing, and don't emit the wrapper around an empty payload.
2. **Emit show/position only on a transition** — send `\e[?25h` + CUP when the cursor's
   visibility or position actually changed, not on every frame, to stop the blink-state
   reset.
3. *(belt-and-suspenders, optional)* hide the cursor for the paint (`\e[?25l` before the
   diff). Mostly cosmetic given the single atomic write + cursor-last ordering above; do it
   only if 1–2 don't fully resolve it on a non-2026 terminal.

**Layered perf note (not the fix):** `highlight_line/4`
([loop.ex:380](../lib/geex/loop.ex#L380)) re-tints the active line's whole-width background
every frame; trimming the per-keystroke damage to only the rows whose active-line state
changed shrinks each frame (fewer runs), compounding the benefit on terminals that ignore
synchronized output. Medium effort, layered on top of fixes 1–2 — not a substitute.

**Verification when fixed:** drive a keystroke burst in the tmux dogfood and confirm no
visible tearing; on a DEC-2026 terminal confirm the frame is atomic; check the cursor no
longer blinks-resets on same-position frames.
