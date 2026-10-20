# geex

An **LLM-native text editor on the BEAM**: human keystrokes, MCP tool-calls,
extensions and remote peers all become the same `%Command{}` value, run through
one dispatcher into one undo history, each tagged with provenance. See
[doc/README.md](doc/README.md) for the map, [doc/vision.md](doc/vision.md) for
the north star.

**This file is the always-loaded static layer — invariants + where to look. It
is NOT project state.** What shipped and what's next lives in git log and
[doc/roadmap.md](doc/roadmap.md); rationale in [doc/adr/](doc/adr/); what was
hand-verified and when in [doc/testing.md](doc/testing.md) (the verification
log). Those are authoritative and current; this file and memory are
as-of-write-time and can drift. When in doubt, read the code.

## Start here

- **`/orient`** — read-only session-start bearing: reconstructs "you are here"
  from commits + roadmap + the verification log. Run it first in a fresh window.
- **`/shipshape`** — verifies the repo is in order (tests ×2 / docs / conventions
  / deps). Run before commits. It *proposes* fixes; it does not apply them
  unless asked.
- **`/dogfood`** — drives the real app where `mix test` can't reach: the TUI
  through a tmux pty, the MCP server through a live loopback handshake. Run
  after any change a human or agent would *see*.

- **`/deploy`** — builds this checkout into the release tarball and installs it as
  `~/.local/bin/geex` through `install.sh`, the way a release installs (`mix geex.deploy`,
  ADR-0041), then checks it live. Run when the `geex` command should be the current build.

A local build carries the OTP that runs Mix, so it runs on this machine. Portable releases
(linux-x64/arm64, darwin-arm64/x64) are CI's: `release.yml` on a `v*` tag builds each target
with `rel/build-runtime.sh`'s OTP and smoke-tests it; users install with
`curl …/releases/latest/download/install.sh | sh` ([doc/install.md](doc/install.md), ADR-0041).
Development still runs from this checkout via `mix`.

## Architecture in one breath

One Mix app, `:geex`, under `lib/geex/`:

- **Command system** — `Geex.Command` (the macro DSL → a serialization-neutral
  field-spec), `Geex.Commands.*` (each a pure `run(cmd, %EditorState{})`),
  `Geex.Dispatch` (pure `apply_command/2` + deterministic `replay/2`; public
  `run/1` = resolve active buffer → gather → apply → scatter → record).
- **World** — `Geex.Buffer` (GenServer: owns the ONE undo history as a pure
  `Geex.History` value, every transition going through it (ADR-0033); `Geex.Blame`
  derives who last wrote each line; `Buffer.Doc` is the text), `Geex.Session` (active-buffer pointer, the
  recent buffers, and each buffer's view-local cursor), `Geex.Reconcile` (file-watch marks an open buffer *behind*; a fast-forward or
  save records the change as `:external` commands, merging with `git merge-file`, ADR-0034).
- **Projections** — `Geex.MCP.*` (Protocol is pure; HTTP is the loopback
  Bandit/Plug transport; tool categories: edits, `Operations`, `ViewActions`,
  `Grid`) — **frozen by ADR-0032**: keep it green, add no tools; and the TUI: `Geex.Loop` (+ `loop/`), `Screen`/`Cell`/`Renderer`,
  `TerminalIO` (`:prim_tty`, no NIF), `Input.Parser`, `Minibuffer`, `Layout` (pure: where
  the tree, the file panes and the edits pane go), `Loop.Panes` (pure: the split file panes
  and each one's tabs, ADR-0038), `Loop.Mouse` (pure: where a mouse event lands, ADR-0039), `Loop.Settings` (pure: the `Alt+Y` view, ADR-0040), `Geex.Finder` (`Alt+O`'s fuzzy file ranking, run off the loop), `Geex.Tree` (the tree's files, from `git
  ls-files`; `Tree.Watcher` re-reads them as files come and go), and `Geex.Edits` (the in-memory edits list behind the edits pane, ADR-0034).
- **Capabilities** — `Geex.Highlight.*` (reactor + tree-sitter-on-wasm via the
  sibling path dep `../tree_sitter_wasm`), `Geex.Theme` (+ `Theme.Terminal`, the terminal's own
  colours), `Geex.Catalog` (the embedded `catalog/catalog.json`), `Geex.Install` /
  `Geex.Installed` (installing and listing grammars and themes, ADR-0040). geex ships **no**
  grammar or theme: tests install `test/fixtures/{grammars,themes}` (`Geex.Fixtures`, from
  `test_helper.exs`), and Birds of Paradise lives in `catalog/themes`.

## Sacred invariants — breaking one breaks the project

1. **One shared path.** Every buffer mutation — human, agent, reconcile — is a
   `%Command{}` through `Geex.Dispatch.run/1` into `Buffer.dispatch/2`. No side
   door that edits a `Doc` and skips the history. (ADR-0002/0003/0014.)
2. **Provenance on every command.** Every recorded command carries `meta.actor`
   (`:human` / `{:llm, _}` / `:external`). (ADR-0005.)
3. **The pure core stays pure and replay stays deterministic.** `apply_command/2`,
   `replay/2`, the `run/2` bodies, `History`, `Blame`, `Coord`, `Fuzzy`, `Selection`, `Width` are
   `value -> value`. A recorded command list replays to the same state — the
   §15c golden-pair cassette (`test/geex/cassette_test.exs`) pins it; never
   regenerate the golden from the replay under test.
4. **The terminal belongs to the renderer.** In TUI mode only
   `Geex.TerminalIO` writes the tty; `Logger` is redirected to
   `Geex.log_file/0` before the app boots (`Geex.run/1`, hence `--no-start`).
   No `IO.puts`/`IO.write` in `lib/` outside `terminal_io.ex`, the
   `lib/mix/tasks/` CLI tasks, and `cli.ex`'s `--version`/`--help`/usage/`install`/
   `highlight`/`self` and its start-failure line (printed before the terminal is taken, or
   instead of it, then the VM halts). Anything that
   stops the VM goes through `Geex.stop/0`, never `System.stop/0`: the
   installed program's application never finishes starting, so only an
   explicit stop restores the terminal there (ADR-0036 §3).
5. **Grapheme addressing; width never addresses.** Commands address graphemes
   (and logical lines); display width (`Geex.Width`) is a *render* concern only
   — width can mis-render, never mis-address. Display→grapheme casts are pure.
   (ADR-0027.)
6. **Agents edit natively; geex records, captAInHook attributes** (ADR-0032).
   Reconcile is the primary agent path. Attribution comes only from an
   attestation that matches the exact content hash; with no match the command
   stays `:external`. Never infer an actor from timing.
7. **World, not brain.** geex owns buffers / the shared path / undo / replay /
   provenance; agent orchestration, planning, context and cost are
   bring-your-own. Apply this test before proposing any feature. (ADR-0007.)
8. **Loopback only.** The MCP listener binds `127.0.0.1`; `Origin` is matched by
   parsed host, never a prefix. `quit` stays human-only — no agent tool may
   stop the VM.

## Build / test / run

```sh
mix compile --warnings-as-errors   # the bar locally; ci.yml runs it and the suite on every push
mix test                           # ~1100 tests, ~10s; green TWICE is the ship bar
mix test test/geex/mcp/grid_test.exs
mix geex.serve                     # headless + loopback MCP on a free port (logged)
mix geex.serve --port 4000         # pin 4000 to match presets/claude-code/.mcp.json
mix geex.highlight <file>          # one-shot highlighted dump (engine check)
mix geex.ledger list               # the durable ledgers (ADR-0033); also forget / compact
# every non-test boot also listens on loopback POST /attest (ADR-0032); in TUI
# mode that is the ONLY route — the frozen MCP surface needs mix geex.serve
# the interactive TUI (needs a real tty — /dogfood drives it through tmux):
elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("path")'
mix geex.deploy                    # build the release tarball, install it with install.sh (ADR-0041)
mix geex.deploy --rollback         # switch back to the previous version (install.sh --rollback)
rel/smoke.sh --version X           # install a release into a temp HOME and run it (CI's smoke)
mix geex.catalog                   # build the grammar/theme packages from catalog/*.exs into
                                   # _build/catalog/dist, write catalog/catalog.json (ADR-0040)
```

Feature gates live in `config/config.exs` (`start_terminal` / `start_reconcile`
/ `start_highlight` / `ledger` are all **off under `mix test`** — tests start what they
need explicitly) and `config/runtime.exs` (`GEEX_SERVE=1` flips the HTTP
listener on and the terminal off; `GEEX_MCP_PORT`, `GEEX_MCP_PORT_FILE`).

The reconcile watcher shells out to `inotifywait` (`inotify-tools`, installed
here). Without it the watcher degrades to a logged no-op — geex still runs,
but out-of-band writes aren't noticed. Merging a buffer that is behind shells out to
`git merge-file`; without git it falls back to geex's own merge (ADR-0034). Tests never depend on it: they
inject a stub via `Geex.Reconcile`'s `:start_watcher` option.

## Conventions when you touch code

- **Pure fn naming:** `Dispatch.apply_command/2`, never `apply/2` (collides with
  `Kernel.apply`). Check for name collisions in the module before adding a
  helper (`Protocol.route/2` is the JSON-RPC router).
- **Assert against values, never rendered bytes** — buffer text, cursor, the
  command history, `Screen` cells. (testing.md § Strategy.)
- **Named-consumer rule:** don't build a subsystem until its first real
  consumer lands (the clipboard waited for copy/paste; per-participant Views
  wait for multi-participant).
- **The key loop never waits on slow work** (ADR-0035): anything that grows with file size,
  file count, history length or an external program runs in a monitored process, and
  `Geex.Loop` draws its answer when it arrives (the tree's reader is the model).
- **Log lines** are prefixed by subsystem: `"geex reconcile: …"`,
  `"geex MCP: …"`. Lifecycle = `info`, degraded-but-running = `warning`,
  per-event chatter = `debug`.
- **`~s(...)` with inner parens breaks the parser** — use `~s|...|`.
- **A nested struct used in its parent's compile-time `@attr`** must live in
  its own file (see `Catalog.Entry`).
- Adversarial review of a slice is a house habit — `.claude/workflows/*.js`
  are the per-slice multi-agent reviews; copy one as a template.

## Docs discipline

- **Decisions → ADR** (`doc/adr/NNNN-kebab-title.md`; Status · Context ·
  Decision · Consequences · See). A new dependency, changed contract, or a
  pattern adopted/rejected needs one, or an **amendment** to the ADR it extends
  (the common case here). Add a row to `doc/adr/README.md`'s index.
- **What was verified → [doc/testing.md](doc/testing.md) verification log** —
  one dated entry per increment: what was hand-checked, the test count, what
  was *not* tested. Append-only; never rewrite past entries.
- **What's next → [doc/roadmap.md](doc/roadmap.md).** Update the item (and
  "Where we are") in the commit that lands it.
- **Bugs found but not fixed → [doc/bugs.md](doc/bugs.md)**, with the verified
  root cause; when fixed, move the verification to testing.md.
- **[doc/notes.md](doc/notes.md)** is design-space exploration and brain-dumps
  — non-authoritative; don't cite it as a plan.

## Commits

`<Area>: <what> (ADR-NNNN)` subject (e.g. "Grid mode: Alt+G ruler + grid-line
overlay + copy/cut/goto over coordinates (ADR-0027)"); `Docs:` for docs-only.
Body: the slice as bullets, then **Deferred:** and how it was verified
("Live-verified via tmux …", "N tests + M doctests green"). End with the
session's `Co-Authored-By` trailer.

## Names & paths

- app `:geex`, modules `Geex.*`, repo `~/geex`
- env: `GEEX_SERVE`, `GEEX_MCP_PORT`, `GEEX_MCP_PORT_FILE`
- attestation discovery file (ADR-0032): `$XDG_RUNTIME_DIR/geex/<os_pid>.json`
  (`<tmp>/geex-<user>/` without it), `0600`, removed on clean exit; app gate
  `:start_attest` (off under test)
- attestation payload (ADR-0032 step d): `integrations/captainhook/geex-attest.sh`, which the
  user registers in `~/.captainHook/handlers.json` (never edit that file without asking);
  tested against `test/fixtures/claude-code/` (verbatim captAInHook captures)
- settings the `Alt+Y` view keeps (ADR-0040 §7): `$XDG_CONFIG_HOME/geex/settings.json` (default
  `~/.config/geex/`), written by geex (`Geex.Settings`); tests get their own `settings_path`
- installed grammars and themes (ADR-0040): `$XDG_DATA_HOME/geex/{grammars,themes}/<name>/`
  (default `~/.local/share/geex/`), each with `installed.json` written last; `geex install NAME |
  --list | ./pkg`; `GEEX_CATALOG_URL` (a `file://` dir or `http(s)://` base) replaces the release
  host. Tests get their own `data_dir`. Only `Geex.Install` touches the network, and only on
  the user's word (a test reads the import tables). Compiled grammars cache in
  `$XDG_CACHE_HOME/geex/wasm` (off under test: `wasm_cache`)
- durable ledger (ADR-0033): `$XDG_STATE_HOME/geex/ledger/<key>.jsonl` (default
  `~/.local/state/geex/ledger/`; `<key>` = 16 hex of the sha256 of the absolute path),
  `0600` in `0700`, plus `<key>.lock` while a buffer has it open and `<key>.spool.jsonl` (the
  payload's attestations for the file while no geex had it open); app gates `ledger` (off under
  test; tests pass `:ledger_dir`) and `ledger_dir`. Dogfood with `XDG_STATE_HOME` pointed at a
  scratch dir to keep the real one clean
- edits list kept across restarts (ADR-0034's 2026-10-18 amendment): `$XDG_STATE_HOME/geex/edits.jsonl`
  (+ `edits.1.jsonl`, the previous generation), `0600`; app gate `edits_log` (off under test;
  tests pass `:file`), `edits_file` overrides
- minibuffer history (ADR-0042): `$XDG_STATE_HOME/geex/history.json` (`{"command": [...],
  "grid": [...]}`, newest first, 500 each), `0600`; app gate `minibuffer_history` (off under test),
  `history_file` overrides. Shell commands (`!`, `|`) run in the project root via `Geex.Shell`
- TUI log: `$XDG_STATE_HOME/geex/geex.log` (`Geex.log_file/0`, default `~/.local/state/geex/`,
  0700, rotates at 1 MB); a VM crash dump lands beside it (`erl_crash.dump`, the launcher's
  `ERL_CRASH_DUMP`)
- installed program (ADR-0041): built to `_build/package/geex-<version>-<os>-<arch>.tar.gz` +
  `SHA256SUMS`; `install.sh` unpacks it to `$GEEX_INSTALL_DIR/versions/<version>/` (default
  `${XDG_DATA_HOME:-~/.local/share}/geex`) and links `$GEEX_BIN_DIR/geex` (default
  `~/.local/bin`) to its `bin/geex` launcher; `previous` names the rollback version;
  `GEEX_DOWNLOAD_URL` replaces the release download dir (`file://` works). A local prod build's
  version is `0.3.0+<geex sha8>.<tree_sitter_wasm sha8>` (`.dirty` when either tree is
  uncommitted); a release build (`GEEX_RELEASE=1`) is the plain version, at
  `@tree_sitter_wasm_ref`. The launcher passes `-geex standalone true` (`Geex.CLI.standalone?/0`).
  Each version carries its `install.sh`; `geex self update|rollback|prune|uninstall` is the
  launcher's own (sh, no VM: a running geex is what prune and uninstall leave alone), and only a
  bad `self` or a release install.sh didn't install reaches `Geex.CLI`
- releases: `v*` tags are geex versions (`release.yml` publishes, `smoke.yml` checks from the
  public URL); catalog releases keep `v0.1.0`/`v0.2.0` and are `catalog-v<N>` from now on,
  published as not-latest (ADR-0041 §5)
- sibling path dep: `~/tree_sitter_wasm` (Rustler NIF; must exist to compile)
- harness presets: `presets/<harness>/` — copy into a *target* project, never
  geex's own root (it would deny your editor's writers here).
