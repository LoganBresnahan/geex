# ADR-0036: An installed binary — Burrito, built and installed locally

- **Status:** Accepted 2026-10-16. The maintainer asked for it ("go ahead and implement the
  deploy with burrito so we can start building locally"). Built by the coordinator session.
  Amended 2026-10-18: the release is trimmed (§5). Amended 2026-11-16: SIGHUP takes the orderly
  stop, and a signal lets a write under way finish (below). Amended 2026-11-17: the stop is
  bounded, a disk that hangs no longer holding it (BUG-21, below). **Superseded in part by
  [ADR-0041](0041-release-without-burrito.md) (2026-10-19):** Burrito is gone; §1's wrap, §4's
  deploy and §6's fork are replaced by a tarball, a launcher and install.sh. §2, §3 and §5 stand.
- **Date:** 2026-10-16
- **Relates to:** [ADR-0001](0001-build-on-the-beam.md) (the BEAM), the sacred invariant "the
  terminal belongs to the renderer", [ADR-0032](0032-listener-first-agent-integration.md) (the
  attestation listener the binary keeps on), [ADR-0033](0033-durable-ledger.md) (the ledger it
  writes)

## Context

geex only ran from its checkout:
`elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("path")'`. To use it
as the editor for an agentic flow, the maintainer wants a `geex` command on the PATH, built from
this checkout and installed on this machine. Distribution was always planned as `mix release`
plus [Burrito](https://github.com/burrito-elixir/burrito), which wraps a release into one
executable. pharos-mcp already ships that way on this machine, with Zig 0.15.2 and Burrito 1.5.

Three things about Burrito decide the shape:

1. **Its launcher hands the arguments to Elixir's CLI.** After the release boots, it runs
   `-s elixir start_cli`. That treats a plain argument as a script to evaluate and then halts.
   So `geex notes.txt` would run `notes.txt` as Elixir code. Checked: `erl … -s elixir start_cli
   -extra foo.txt` evaluates `foo.txt`, and with no argument the VM halts right after boot.
2. **Its Linux flow swaps in a precompiled musl ERTS.** geex loads the tree_sitter_wasm NIF,
   which is Rust built against this machine's glibc. Burrito only rebuilds NIFs that use
   `elixir_make`, so this one would be shipped unchanged into a musl runtime. Pointing Burrito's
   `custom_erts` at the local Erlang install isn't safe either: its copy step deletes the
   matching NIF files in the source tree before copying.
3. **It unpacks once per version.** The binary unpacks into
   `~/.local/share/.burrito/geex_erts-<erts>_<version>/` and skips that when the directory exists.
   Two builds with one version run the first one's code. This bit pharos.

## Decision

### 1. The release and the binary

- `mix.exs` has a `geex` release with steps `[:assemble, &Burrito.wrap/1]`. It writes
  `burrito_out/geex_linux`. Burrito is a build-time, prod-only dependency, pinned to `~> 1.5.0`
  (1.6 needs Zig 0.16).
- **Burrito's phases are cut down** to `fetch: [Fetch.Init]` and `patch: []`, with the default
  build phase. The release is wrapped as `mix release` assembled it, which includes this
  machine's ERTS and the glibc NIF. The binary runs on this machine, or one like it. That is
  what a local install needs, and it needs no download.
- **A prod build's version carries the commit:** `0.1.0+<sha8>`, with `.dirty` added for an
  uncommitted tree, so each commit unpacks into its own directory. Dev and test keep `0.1.0`.
  **Amended 2026-10-18:** `0.1.0+<geex sha8>.<tree_sitter_wasm sha8>`, with `.dirty` when either
  tree is uncommitted. The NIF can change while geex doesn't (the stripped NIF was deployed under
  the cache build's version), and a deploy keeps an in-use unpack on the grounds that a
  committed version is the same code (BUG-4's fix). With only geex's commit in the name, a geex
  running during that deploy would have left the new binary running the old NIF.
- `rel/vm.args.eex` adds `-noinput` and `+Bd`, the flags `Geex.run/1` gets from `--erl`.
  Burrito's launcher already passes `-noshell`.

### 2. The entry point does its work inside `Application.start/2`

Under the binary (`__BURRITO=1`, which the launcher sets), `Geex.Application.start/2` calls
`Geex.CLI.main/2` and never returns. Elixir's CLI therefore never sees the arguments. This is
the pattern Burrito documents. `Geex.CLI.main/2`:

- parses the arguments, purely, in `Geex.CLI.parse/1`:
  - no path means `.`;
  - several paths open in order, the first shown;
  - `--` ends the options;
  - `-v`/`--version` and `-h`/`--help` print and halt;
  - an unknown option prints usage and exits 2;
- sends the log to `<tmp>/geex.log` (`Geex.redirect_logs_to_file/0`, shared with `Geex.run/1`);
- starts the supervision tree;
- opens the paths, expanded against the working directory (`Geex.open_paths/1`, shared);
- then sleeps.

### 3. Quitting is an explicit, orderly stop

Because the application never finishes starting, `System.stop/0` can't stop it in order.
Checked: init exits with status 0 but skips every `terminate/2`. The terminal stays on the
alternate screen, the attestation discovery file stays, and a buffer's ledger lock stays. So:

- The loop's three quit sites (`Ctrl-X`, the `quit` verb, end of input) call `Geex.stop/0`.
  - Under `mix run`, nothing is registered as `Geex.CLI`, so it is still `System.stop/0`.
  - Under the binary, it sends `:geex_quit` to `Geex.CLI`'s process. That process stops the
    supervision tree (`Supervisor.stop/1`), so every child's `terminate/2` runs, flushes the log
    and halts with 0.
- **SIGTERM takes the same path.** `Geex.CLI.Signals` replaces OTP's `erl_signal_handler`; OTP's
  own handler calls `init:stop/0`. SIGUSR1 and SIGQUIT still halt.
- **The terminal restore is synchronous.** `Geex.TerminalIO.terminate/2` writes with
  `:prim_tty.write/3` and waits up to 500 ms for the writer's acknowledgement. `write/2` only hands
  the bytes to the writer process, and the halt right after the stop could kill the writer first.
  Checked: one of two SIGTERM runs left the alternate screen on before this change, and six of six
  quits restored it after.

Under `mix run`, nothing else changes: `standalone?/0` is false, and `start/2` starts the tree and
returns.

### 4. `mix geex.deploy`

- Builds with `MIX_ENV=prod mix release --overwrite`.
- Removes the unpack directory the new build will use (`geex_linux maintenance directory`
  names it).
- Checks that `--version` answers.
- Installs to `$XDG_DATA_HOME/geex/bin/geex` (default `~/.local/share/geex/bin`) and keeps the
  binary it replaces as `geex.prev`. The swap is a rename, so a running geex keeps its file.
- Links `~/.local/bin/geex` to it. It never overwrites a `~/.local/bin/geex` that is something
  else.
- `--no-build` installs the last build. `--rollback` swaps `geex` and `geex.prev`.
- The `/deploy` skill wraps it with the ship bar (suite green twice) and a live check.

### 5. The release is trimmed (amended 2026-10-18)

The maintainer asked for a smaller binary; the coordinator session relayed it. Most of its bulk
was the VM's debug information: `beam.smp` was 54 MB unstripped. The release now has a step
between Mix's `:assemble` and Burrito's wrap (`Mix.Tasks.Geex.Deploy.trim_release/1`).

**`erts-*/bin` keeps four programs:**
- `erlexec`, which Burrito's launcher execs;
- `beam.smp`, which `erlexec` starts;
- `erl_child_setup`, which starts every port (`git`, `inotifywait`);
- `inet_gethost`, which looks up host names for a download (ADR-0040 §3).

`strip --strip-debug` runs over all four. That takes `beam.smp` to 11.0 MB. A full strip would
save another 0.45 MB but lose the symbols a native backtrace names.

**Removed from `erts-*/bin`:**
- tooling: `erlc`, `yielding_c_fun`, `dialyzer`, `typer`, `ct_run`, `escript`, `erl_call`;
- embedded-system helpers: `heart`, `run_erl`, `to_erl`, `dyn_erl`;
- the `erl` and `start` scripts and their `.src` files;
- `epmd`.

**What that loses:**
- distribution: a geex binary can't take `-sname` or a remote shell, since `epmd` is gone. It
  never offered one; the cookie Burrito passes starts nothing.
- the release's own `bin/geex` script, which runs `erts-*/bin/erl`. Burrito never uses it, and
  nothing else runs the release directory.

**Every OTP application stays:**
- `compiler` is a dependency of `elixir`, and `eex` of plug and rustler;
- `iex` is already in the release as `:none`, never loaded;
- `sasl` is 0.2 MB;
- `ssl`, `public_key`, `asn1`, `crypto` and `inets` are what a download and the listener use.

The `.beam` files already carried no debug information or docs (`strip_beams`, Mix's default,
now stated in `mix.exs`). The NIF was already stripped.

**The safety net.** `trim_release/1` stops the build if a module that geex's code calls is
missing from the release. Called means: from geex's own modules, transitively through every
module their calls reach, by each `.beam`'s import table (`unresolved/1`). Six names have never
been in any release, and none is reachable from a running geex, so they are expected:

| Missing | Why it isn't reachable |
|---|---|
| `Mix`, `Mix.Task` | the mix tasks compiled into geex, which run only under mix |
| `:dbg` | inets' tracing |
| `:erl_syntax`, `:erl_syntax_lib` | stdlib's `shell_docs_test` |
| `:Dict` | named in Elixir's Enum and URI, and defined nowhere |

Amended 2026-10-18: `Mix.Project` joins the first row. `mix geex.catalog` reads the
`catalog_release` from it (ADR-0040's amendment). The check stopped the first build after that
change, which is what the check is for.

A call through a variable isn't in an import table, so the check is a floor, not a proof. The
live smoke covers the paths the import tables can't see. `test/geex/deploy_test.exs` runs the
same check against the last built release.

**Measured** with the same machine and the same code, the unpack in a scratch
`GEEX_INSTALL_DIR`:

| | Before | After |
|---|---|---|
| the binary | 21.9 MB | 9.6 MB |
| unpacked | 86.8 MB | 38.8 MB |
| first run (unpack and `--version`) | 1.52 s | 0.81 s |
| warm `--version` | 228 ms | 225 ms |
| warm launch to the first frame | 363 ms | 360 ms |

Of the 38.8 MB unpacked, the tree_sitter_wasm NIF (wasmtime) is 14.5 MB, already stripped.

### 6. A fork of Burrito: embedded mode, and cleanup that spares a running unpack (amended 2026-10-18)

The 0.2.0 deploy showed that Burrito deletes the unpacks of older versions on every run,
whatever runs from them. The coordinator session then found why that kills a running geex:
Burrito's launcher passes `"-mode embedded"` as one argv element, which `init` doesn't split,
so every Burrito binary ran in interactive mode and loaded modules from its unpack lazily. The
maintainer approved a fork: `LoganBresnahan/burrito`, branch `geex`, which is v1.5.0 plus two
patches. It is fork-only, never sent upstream. Its `FORK.md` is the contract.

- **Patch A: the VM runs in embedded mode.** `"-mode", "embedded"` are two elements now, and
  the boot script loads all 1,068 modules up front.
  - The two other combined elements (`-s elixir start_cli`, `-elixir ansi_enabled true`) never
    took effect, so they are dropped, not split. Split, `start_cli` would hand the arguments to
    Elixir's CLI after boot, the trap §2 avoids (geex's boot never finishes, but another app's
    would), and ANSI colour would reach the log.
  - geex logs "loading code in embedded mode" at boot.
  - **The cost:** about 125 ms more to the first frame (356 → 480 ms warm) and 193 ms more for
    `--version` (229 → 422 ms).
- **Embedded mode is strict:** a boot-script path or module that isn't there stops the boot
  (pharos-mcp found one in its release). So `trim_release/1` now also emulates the boot
  (`boot_problems/2`): every `{path, …}` directory must exist, and every preloaded module must
  have a `.beam` on that path. Checked for geex's release: none missing.
- **Patch B: cleanup spares an unpack in use.**
  - A running app holds a shared `flock` on `<unpack>/.burrito-in-use`. Its descriptor
    survives both execs into `beam.smp`, with close-on-exec cleared.
  - The cleanup deletes an older unpack only after taking an exclusive lock without waiting.
  - A pre-fork unpack with no lock file is kept while any process's `/proc/<pid>/exe` lies under
    it.
- **What still needs the unpack** with both patches: a port program started lazily.
  `inet_gethost` starts on the first DNS lookup, so with an unpack deleted by hand, geex's next
  download kills the VM ("Can not execute …/inet_gethost : enoent", a crash dump, the terminal
  not restored). Patch B keeps that from happening by itself; a person can still `rm -rf` it.
- **Checked live** with fork builds sharing an install directory:
  - With 0.2.0 open, a 0.2.1 launch kept the 0.2.0 unpack. The open geex then saved a file and
    installed Markdown over the network. Once 0.2.0 quit, the next 0.2.1 launch removed it.
  - A pre-fork 0.2.0 build was kept while it ran and removed after it quit.
- **The deploy guard of the previous amendment is gone.** `older_in_use` refused a deploy while
  an older geex ran, because the new binary's first run would delete its unpack. Patch B makes
  that run safe, and the guard would only block a deploy that now does no harm. The advice to
  restart open editors after a version change stands only for a binary built before the fork.
- `mix.exs` takes Burrito from the fork, pinned by its git sha.
- **Amended the same day (fork `4407714`):**
  - **The wrapper's own messages go to stderr.** With `GEEX_INSTALL_DIR` set they reached
    stdout before geex's output. They broke pharos-mcp's stdio, and in geex they came before
    `--version`.
  - **`geex maintenance purge`** removes every unpack of geex that no process uses, the current
    version's included, and says why it kept each other one. Burrito takes `maintenance` before
    geex sees its arguments, so geex needs no command of its own for it.
  - Purge runs before anything is unpacked, so it never unpacks its own version only to delete
    it.

## Consequences

- `geex`, `geex PATH…` and `geex DIR` work from any directory, and the bashrc function goes
  away. The binary keeps the attestation listener on (`:start_attest`, the prod default), so
  captAInHook's payload finds it through `$XDG_RUNTIME_DIR/geex/<pid>.json`.
- **Host dependencies stay host dependencies:** `git` (the tree, merges) and `inotify-tools`
  (the watcher) are not in the binary.
- **Not portable yet.** The binary carries this machine's glibc ERTS and NIF. A Mac build, or a
  Linux binary for other machines, needs the NIF built for that target (for example
  `rustler_precompiled`, or Zig-linked musl builds) and Burrito's default phases back. That is
  its own ADR when there is a second machine. (2026-10-18: the plan is now roadmap item 13:
  plain release tarballs per target built in CI and a curl installer, with no Burrito.)
- **Burrito reserves one first argument:** `geex maintenance …` goes to Burrito's maintenance
  commands. `geex -- maintenance` opens a file named `maintenance`.
- **A deploy removes old unpacks, but never one in use.** Burrito removes only versions
  that sort older, and semver ignores the `+<sha>` part, so it never removes a geex build's
  unpack (about 90 MB each; 39 MB since §5). Checked: `0.1.0+797edb8a.dirty` stayed after `0.1.0+4c31f8cd`
  ran. `mix geex.deploy` removes every other `geex_erts-*`. **Amended 2026-10-18 (BUG-4):** it
  keeps `geex.prev`'s and any a running process uses (by `/proc/<pid>/exe` and `cmdline`). A
  running VM loads modules from its unpack as it needs them; removing it under the
  maintainer's open geex crashed it (undefined `sys` and `io_lib_pretty`, garbage on the
  terminal). A running geex no longer needs a restart after a deploy.
  **Amended 2026-10-18 again: across versions it does.** Burrito removes, on every run, the
  unpack of each older version, by semver, which ignores `+<sha>`, and it doesn't look at what
  is running.
  - Within one version (`0.1.0+…`) every build compares equal, so this never happened.
  - At 0.2.0 it did: the deploy's first run of the new binary printed "Uninstalled older
    version (v0.1.0+573091e7…)" and "(…c1a9cb7e…)", which also broke the deploy's `--version`
    check.
  - Nothing was running from them then. A geex that is would have crashed, as in BUG-4.
  - **Now `mix geex.deploy` refuses to run a new version's binary while a geex runs from an
    older version's unpack** (`older_in_use/3`). It says which, and to quit it first; checked
    live against a running 0.1.0 geex, whose unpack stayed. The `--version` check now finds
    its line among Burrito's.
  - **Not covered:** launching the new `geex` later while an older one is still open deletes
    the older one's unpack the same way, and only Burrito could check that. So after a deploy
    that changes the version, restart every open geex before starting the new one. (Since §6,
    Burrito's fork checks it, and this guard is gone.)
- Under the binary the app never reaches "started" (its `start/2` doesn't return). Nothing in
  geex asks. `Application.ensure_all_started(:geex)` is only `Geex.run/1`'s, which the binary
  doesn't use. Anything that stops the VM must go through `Geex.stop/0`, never `System.stop/0`
  (§3).
- **Ctrl-C still kills geex outright,** under the binary and under `mix run` alike. `prim_tty`'s
  raw mode leaves `isig` on, so the terminal sends SIGINT. That is
  [BUG-3](../bugs.md), not part of this ADR. (Fixed the same day: `Geex.TerminalIO` turns the
  tty's signal keys and flow control off, so Ctrl-C quits through the keymap.)

## See

- §5: `Mix.Tasks.Geex.Deploy.trim_release/1`, `trim_erts/2`, `unresolved/1`;
  `test/geex/deploy_test.exs`.
- `mix.exs` (`version/0`, `releases/0`), `rel/vm.args.eex`, `lib/geex/cli.ex`,
  `lib/geex/cli/signals.ex`, `lib/geex/application.ex` (`start/2`), `Geex.stop/0`,
  `Geex.TerminalIO.terminate/2`, `lib/mix/tasks/geex.deploy.ex`, `.claude/skills/deploy/SKILL.md`,
  `test/geex/cli_test.exs`.
- Burrito 1.5.0: `lib/builder/builder.ex` (phases), `src/erlang_launcher.zig` (the launch
  line), `lib/steps/patch/copy_erts.ex` (why `custom_erts` isn't used).
- [testing.md](../testing.md), 2026-10-16 (the live checks of the binary).

## Amendment (2026-11-16): SIGHUP, and a write under way at a signal

- **SIGHUP takes §3's path too.** Closing the terminal window sends it, and its OS default ended
  the VM at once, every `terminate/2` skipped (BUG-20). `Geex.CLI.Signals.install/0` asks for it
  (`:os.set_signal(:sighup, :handle)`) once its own handler is in, since OTP's would ignore it.
- **A signal goes through the loop first.** SIGTERM and SIGHUP call `Geex.Loop.shutdown/0`, so a
  save under way finishes (for up to 30 s) before `Geex.stop/0`; with no loop running it
  is `Geex.stop/0` at once. Should the loop not get that far, geex stops anyway after 35 s:
  `Geex.CLI` is sent `:geex_quit`, or under `mix run` `System.stop/0` is called, as OTP's handler
  would have.
  [ADR-0035](0035-the-loop-never-waits.md)'s 2026-11-16 amendment.
- **`Geex.run/1` installs the handler too**, so `mix run` behaves as the binary does. OTP's
  `init:stop/0` for SIGTERM worked there; it is the same orderly stop either way.

## Amendment (2026-11-17): the stop is bounded (BUG-21)

- **A disk that hangs held the stop.** Elixir's `File` calls that aren't `:raw` go through OTP's
  one file server, which makes each call itself; one read that never returns (a stalled network
  disk; a FIFO in place of the open file) holds it, and every other such call queues behind it
  with no time limit. The loop leaves on time (ADR-0035's 2026-11-16 amendment), but on the way
  out the last session's keep, the ledgers' locks and the discovery file each make one: §3's
  stop took 22 s from the binary (each such child killed at its shutdown timeout, then the halt),
  and under `mix run` never ended (Mix's own stop callback lists files the same way, and nothing
  on `init:stop/0`'s way has a time limit). [bugs.md](../bugs.md) BUG-21.
- **`Geex.StopWatchdog`.** The loop arms it as it leaves (`exit_editor`, before the last session's
  keep, so its 10 s run from the quit), and so do `Geex.stop/0`, `Geex.CLI` on its quit and, under
  the binary, the signals' backstop (the entry process may itself be stuck opening a file before it
  waits for its quit; mod-verify's review). Once armed, a later arm keeps the first deadline. If the
  VM is still up 10 s later (`limit_ms/0`; a normal stop takes 0.1–1.5 s, and can't pass about 6 s:
  each buffer's close is capped at 5 s by its supervisor, the rest takes under 1 s), it asks
  `Geex.TerminalIO` to put the terminal back (`restore/1`, waiting 2 s; a stop that got as far as
  the terminal's `terminate/2` already has, and `terminate/2` then leaves it), logs a warning and
  syncs the log in a process given 1 s (a log rotating behind the stuck file server makes the sync
  wait 5 s and lose the line), and halts: `:erlang.halt(0, flush: false)`, the status a normal stop
  gives (a nonzero one would make git abort a commit when geex is `$EDITOR`), and a port stuck on a
  terminal that's gone doesn't hold it. Once restored, `Geex.TerminalIO` draws nothing more, so a
  frame from a loop still running doesn't land on the shell's screen. The watchdog runs outside
  geex's application: its group leader is the VM's `user` process (not `init`, which answers no IO
  request), since an application's master kills every process it leads as the application stops. It
  makes no `File` call. Off under `mix test` (the `stop_watchdog` gate: a halt would end the run);
  its tests arm it with their own restore and halt.
- **`stty` through an absolute `sh`.** `System.cmd("sh", …)` looks `sh` up through the file
  server (`:os.find_executable/1`), so putting the tty's modes back waited behind the stuck read
  until `Geex.TerminalIO` was killed. It finds `sh` once at start. The shell's modes came back
  either way when the VM exited (`isig ixon icanon echo` read in the same pane after the old
  build's 22 s stop), so this shortens the restore rather than fixing what the user sees.
- **Left as before.** After a halt the ledger lock and the discovery file stay (both swept at the
  next start). The save's own read and write still go through the file server, so until the stop one
  file that hangs stalls every other `File` call in geex, the loop's own among them (a clean buffer
  whose file becomes a FIFO wedges it, and only a signal ends geex, at 45 s); `:raw` there would
  confine it (not done, [bugs.md](../bugs.md) BUG-21; done 2026-11-18, BUG-22,
  [ADR-0035](0035-the-loop-never-waits.md)'s 2026-11-18 amendment). `-shutdown_time` for `mix
  run` would bound `init:stop/0` too; the watchdog makes it needless.

Checked live with a FIFO in place of the open file, an edit, Ctrl-O and two quits: geex gone 10.1 s
after the second quit under `mix run` (it never was) and from a release installed in a scratch
directory (22 s before), the terminal back (the watchdog's `restore/1` did it under `mix run`,
mod-verify's trace), the warning in the log. With the loop itself wedged (a clean open file swapped
for a FIFO, then `open b.txt`), SIGTERM: gone 45.1 s after it in both, the backstop's 35 s then the
watchdog's 10 s. A normal save and quit: 0.1 s from the release, 1.1 s under `mix run`, nothing
left, no warning.

**Tests.** `test/geex/stop_watchdog_test.exs` (off under test; with the gate on, `Geex.stop/0`
arming it; the restore first, then the halt, the warning logged; a second arm keeping the first
deadline; its group leader the VM's `user` process when armed from a process led by another; still
halting with the terminal process gone; the limit's range), `test/geex/terminal_io_test.exs` (a
restored terminal left by a second restore and by the stop; nothing drawn after it).

**See** `lib/geex/stop_watchdog.ex`, `Geex.stop/0`, `lib/geex/cli.ex`, `lib/geex/cli/signals.ex`,
`lib/geex/loop.ex` (`exit_editor/1`), `Geex.TerminalIO.restore/1`, `config/config.exs`
(`stop_watchdog`).
