# ADR-0036: An installed binary — Burrito, built and installed locally

- **Status:** Accepted 2026-10-16. The maintainer asked for it ("go ahead and implement the
  deploy with burrito so we can start building locally"). Built by the coordinator session.
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

## Consequences

- `geex`, `geex PATH…` and `geex DIR` work from any directory, and the bashrc function goes
  away. The binary keeps the attestation listener on (`:start_attest`, the prod default), so
  captAInHook's payload finds it through `$XDG_RUNTIME_DIR/geex/<pid>.json`.
- **Host dependencies stay host dependencies:** `git` (the tree, merges) and `inotify-tools`
  (the watcher) are not in the binary.
- **Not portable yet.** The binary carries this machine's glibc ERTS and NIF. A Mac build, or a
  Linux binary for other machines, needs the NIF built for that target (for example
  `rustler_precompiled`, or Zig-linked musl builds) and Burrito's default phases back. That is
  its own ADR when there is a second machine.
- **Burrito reserves one first argument:** `geex maintenance …` goes to Burrito's maintenance
  commands. `geex -- maintenance` opens a file named `maintenance`.
- **A deploy removes old unpacks, but never one in use.** Burrito removes only versions
  that sort older, and semver ignores the `+<sha>` part, so it never removes a geex build's
  unpack (about 90 MB each). Checked: `0.1.0+797edb8a.dirty` stayed after `0.1.0+4c31f8cd`
  ran. `mix geex.deploy` removes every other `geex_erts-*`. **Amended 2026-10-18 (BUG-4):** it
  keeps `geex.prev`'s and any a running process uses (by `/proc/<pid>/exe` and `cmdline`). A
  running VM loads modules from its unpack as it needs them; removing it under the
  maintainer's open geex crashed it (undefined `sys` and `io_lib_pretty`, garbage on the
  terminal). A running geex no longer needs a restart after a deploy.
- Under the binary the app never reaches "started" (its `start/2` doesn't return). Nothing in
  geex asks. `Application.ensure_all_started(:geex)` is only `Geex.run/1`'s, which the binary
  doesn't use. Anything that stops the VM must go through `Geex.stop/0`, never `System.stop/0`
  (§3).
- **Ctrl-C still kills geex outright,** under the binary and under `mix run` alike. `prim_tty`'s
  raw mode leaves `isig` on, so the terminal sends SIGINT. That is
  [BUG-3](../bugs.md), not part of this ADR. (Fixed the same day: `Geex.TerminalIO` turns the
  tty's signal keys and flow control off, so Ctrl-C quits through the keymap.)

## See

- `mix.exs` (`version/0`, `releases/0`), `rel/vm.args.eex`, `lib/geex/cli.ex`,
  `lib/geex/cli/signals.ex`, `lib/geex/application.ex` (`start/2`), `Geex.stop/0`,
  `Geex.TerminalIO.terminate/2`, `lib/mix/tasks/geex.deploy.ex`, `.claude/skills/deploy/SKILL.md`,
  `test/geex/cli_test.exs`.
- Burrito 1.5.0: `lib/builder/builder.ex` (phases), `src/erlang_launcher.zig` (the launch
  line), `lib/steps/patch/copy_erts.ex` (why `custom_erts` isn't used).
- [testing.md](../testing.md), 2026-10-16 (the live checks of the binary).
