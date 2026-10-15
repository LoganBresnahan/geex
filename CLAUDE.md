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

There is no `/deploy` yet — geex has no installed form (no release, no
launcher, no remote). It runs from this checkout via `mix`.

## Architecture in one breath

One Mix app, `:geex`, under `lib/geex/`:

- **Command system** — `Geex.Command` (the macro DSL → a serialization-neutral
  field-spec), `Geex.Commands.*` (each a pure `run(cmd, %EditorState{})`),
  `Geex.Dispatch` (pure `apply_command/2` + deterministic `replay/2`; public
  `run/1` = resolve active buffer → gather → apply → scatter → record).
- **World** — `Geex.Buffer` (GenServer: owns `EditorState` + the ONE undo
  history; `Buffer.Doc` is the text), `Geex.Session` (active-buffer pointer +
  the view-local cursor), `Geex.Reconcile` (file-watch → `:external` commands).
- **Projections** — `Geex.MCP.*` (Protocol is pure; HTTP is the loopback
  Bandit/Plug transport; tool categories: edits, `Operations`, `ViewActions`,
  `Grid`) — **frozen by ADR-0032**: keep it green, add no tools; and the TUI: `Geex.Loop` (+ `loop/`), `Screen`/`Cell`/`Renderer`,
  `TerminalIO` (`:prim_tty`, no NIF), `Input.Parser`, `Minibuffer`.
- **Capabilities** — `Geex.Highlight.*` (reactor + tree-sitter-on-wasm via the
  sibling path dep `../tree_sitter_wasm`), `Geex.Theme`, `priv/grammars`,
  `priv/themes`.

## Sacred invariants — breaking one breaks the project

1. **One shared path.** Every buffer mutation — human, agent, reconcile — is a
   `%Command{}` through `Geex.Dispatch.run/1` into `Buffer.dispatch/2`. No side
   door that edits a `Doc` and skips the history. (ADR-0002/0003/0014.)
2. **Provenance on every command.** Every recorded command carries `meta.actor`
   (`:human` / `{:llm, _}` / `:external`). (ADR-0005.)
3. **The pure core stays pure and replay stays deterministic.** `apply_command/2`,
   `replay/2`, the `run/2` bodies, `Coord`, `Fuzzy`, `Selection`, `Width` are
   `value -> value`. A recorded command list replays to the same state — the
   §15c golden-pair cassette (`test/geex/cassette_test.exs`) pins it; never
   regenerate the golden from the replay under test.
4. **The terminal belongs to the renderer.** In TUI mode only
   `Geex.TerminalIO` writes the tty; `Logger` is redirected to
   `<tmp>/geex.log` before the app boots (`Geex.run/1`, hence `--no-start`).
   No `IO.puts`/`IO.write` in `lib/` outside `terminal_io.ex` and the
   `lib/mix/tasks/` CLI tasks.
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
mix compile --warnings-as-errors   # the bar (no CI yet — this is the only gate)
mix test                           # ~650 tests, ~2s; green TWICE is the ship bar
mix test test/geex/mcp/grid_test.exs
mix geex.serve                     # headless + loopback MCP on a free port (logged)
mix geex.serve --port 4000         # pin 4000 to match presets/claude-code/.mcp.json
mix geex.highlight <file>          # one-shot highlighted dump (engine check)
# every non-test boot also listens on loopback POST /attest (ADR-0032); in TUI
# mode that is the ONLY route — the frozen MCP surface needs mix geex.serve
# the interactive TUI (needs a real tty — /dogfood drives it through tmux):
elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("path")'
```

Feature gates live in `config/config.exs` (`start_terminal` / `start_reconcile`
/ `start_highlight` are all **off under `mix test`** — tests start what they
need explicitly) and `config/runtime.exs` (`GEEX_SERVE=1` flips the HTTP
listener on and the terminal off; `GEEX_MCP_PORT`, `GEEX_MCP_PORT_FILE`).

The reconcile watcher shells out to `inotifywait` (`inotify-tools`, installed
here). Without it the watcher degrades to a logged no-op — geex still runs,
but out-of-band writes aren't auto-reconciled. Tests never depend on it: they
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
- TUI log: `<tmp>/geex.log` (`System.tmp_dir!/0`)
- sibling path dep: `~/tree_sitter_wasm` (Rustler NIF; must exist to compile)
- harness presets: `presets/<harness>/` — copy into a *target* project, never
  geex's own root (it would deny your editor's writers here).
