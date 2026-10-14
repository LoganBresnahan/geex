---
name: shipshape
description: Verify geex is shipshape — compiles warnings-clean, the suite is green twice, docs (roadmap / ADR index + amendments / testing.md verification log / bugs.md) match the code, the invariants hold (one shared path, terminal owned by the renderer, purity of the core, loopback-only MCP), and the deps are honest (lockfile, the ../tree_sitter_wasm path dep). Use after substantive changes, before commits, or when asked whether the project is in order.
---

# /shipshape — repo verification pass

Four gates: **Tests**, **Docs**, **Conventions**, **Deps**. Check all four even
if one fails early — the deliverable is the full report, not the first failure.
Propose fixes; do **not** apply them unless the user asks.

geex has **no CI**. This skill is the only gate between a change and `main`, so
don't skip a step because "CI will catch it" — nothing will.

## 0. Scope the audit

```bash
git status --short && git diff HEAD --stat && git branch --show-current
```

Uncommitted work is the primary audit surface; spot-check the rest. If the user
asks for a full audit, the scope is the whole repo. `doc/evidence/` and
`doc/research/` are frozen inputs — exempt.

## 1. Tests gate

```bash
mix compile --warnings-as-errors --force
mix test
mix test
```

`--force` because an incremental compile only re-warns files it recompiles — a
warning in an untouched module stays invisible. Green **twice in a row** is the
flaky bar: the reactor, reconcile, and buffer tests are process- and
timing-shaped and must survive a loaded machine.

`inotify-tools` is installed on this box (2026-10-14), so the suite should be
quiet. `[error] inotify-tools is needed …` / `geex reconcile: cannot watch`
lines mean the package went missing — not a geex failure, but the reconcile
watcher is dead until it's back (`sudo apt-get install inotify-tools`). Read
the summary line, not the scrollback.

Coverage is judged by **behavior mapping**, not a percentage. For each changed
public behavior in scope, name the test that pins it — the usual surfaces:

- `Geex.Dispatch` / `Geex.Buffer`: apply → record, failing command leaves state
  + history untouched, undo/redo replay-from-base (`dispatch_test`,
  `buffer_test`).
- **Replay determinism**: `test/geex/cassette_test.exs` — the §15c golden pair.
  A change to any command's `run/2` or to `EditorState` must keep it green
  *without* regenerating the golden from the code under test.
- `Geex.MCP.Protocol` / `Schema` / `Grid` / `ViewActions` / `Operations`:
  `tools/list` shape, `tools/call` routing per category, arg-cast errors.
- `Geex.Coord` / `Width` / `Fuzzy` / `Selection`: pure — table tests.
- `Geex.Loop` + `loop/keymap.ex` + `loop/verbs.ex`: a new binding or verb
  needs a keymap/verbs test **and** a `/dogfood` TUI pass (unit tests can't
  see the paint).
- `presets_test.exs`: the preset invariants (loopback endpoint, all four
  structured writers denied, Bash *not* denied).

A new or changed public behavior with no test naming it = **gap**. A TUI-visible
change with no `/dogfood` pass this session = **gap** (say so; don't run it from
here — that's `/dogfood`'s job).

## 2. Docs gate

**ADRs** (`doc/adr/NNNN-kebab-title.md`). A decision in scope — new dependency,
changed contract, new tool category, pattern adopted or rejected — needs an ADR
or a dated **amendment** on the ADR it extends (the common case here). Index
sync:

```bash
ls doc/adr/[0-9]*.md | grep -oE '[0-9]{4}' | sort -u > /tmp/geex_adr_files
grep -oE '^\| \[[0-9]{4}\]' doc/adr/README.md | grep -oE '[0-9]{4}' | sort -u > /tmp/geex_adr_index
diff /tmp/geex_adr_files /tmp/geex_adr_index && echo "ADR index in sync"
```

Also check the index row's **Status** against the file's own Status line when
an ADR moved (Proposed → Accepted is usually flipped in the landing commit).

**Verification log** (`doc/testing.md` § Verification log) — every shipped
increment gets a dated entry: what was hand-checked, the test count, and what
was **not** tested. Check the log keeps pace with the commits:

```bash
grep -n '^### ' doc/testing.md | tail -3          # newest entries
git log --format='%h %ad %s' --date=short -8      # newest commits
```

A feature commit newer than the newest log entry, with no entry covering it =
**gap**. The log is append-only — a *rewritten* past entry is a finding too.

**Roadmap** (`doc/roadmap.md`): the item the change lands says *built* (with
what remains), in the same commit. The "Where we are" section quotes test
counts and slice lists that go stale silently — flag a count that's off by
more than the last slice.

**bugs.md**: a fixed bug moves its verification to testing.md; an open bug the
change touched is either fixed or still accurately described.

**README / presets/README.md**: status claims still true (e.g. the Claude Code
preset row must not claim "verified end-to-end" until a live harness run has
been logged).

Drift check for any doc that names code artifacts:

```bash
git log -1 --format='%ct %h' -- <doc>
git log -1 --format='%ct %h' -- <files it describes>
```

If a source is newer than the doc, read the diff since the doc's commit and
either confirm it still matches or name the exact stale claim. Grep that every
module/function the doc names still exists.

## 3. Conventions gate

**The terminal belongs to the renderer** (CLAUDE.md invariant 4):

```bash
grep -rnE '(^|[^A-Za-z])IO\.(puts|write|inspect)' lib --include=*.ex | grep -v '^\s*#'
# (the [^A-Za-z] guard keeps `TerminalIO.write` from matching)
# allowed: lib/geex/terminal_io.ex, lib/mix/tasks/*.ex — anything else paints
# over the alt-screen in TUI mode
```

**One shared path** (invariant 1) — nothing outside the dispatch path edits a
`Doc` and records around the history. Judgment, guided by grep:

```bash
grep -rn 'Doc\.\(replace\|insert\|delete\)' lib --include=*.ex
# expect: code in lib/geex/commands/*, lib/geex/edit/*, lib/geex/buffer/*, plus
# docstring/doctest mentions in coord.ex, selection.ex, command.ex,
# editor_state.ex. A real call from loop/, mcp/, session.ex or reconcile.ex is
# a side door unless it only builds a value that then goes through
# Dispatch.run/1
```

**Provenance** (invariant 2): any new `%Command{}` construction site sets
`meta.actor` honestly — `:human` from the loop, `{:llm, _}` from the MCP door,
`:external` from reconcile. Never fabricate `{:llm, _}` for an off-path write.

**Loopback only** (invariant 7):

```bash
grep -rnE 'ip: |0\.0\.0\.0|:any' lib/geex/application.ex lib/geex/mcp/
# expect the listener on {127, 0, 0, 1} only
```

And no agent-callable tool reaches `System.stop`/`System.halt`:

```bash
grep -rnE 'System\.(stop|halt)' lib/geex/mcp/   # expect: no hits
```

**Purity** (invariant 3, judgment): a module documented as pure (`Coord`,
`Width`, `Fuzzy`, `Selection`, `Dispatch.apply_command/2`, `replay/2`, command
`run/2` bodies) gains no `GenServer.call`, `Process`, `send`, `File`, or
`System` call.

**Log shape**: new `Logger` calls carry the `"geex <subsystem>: "` prefix and
the level semantics in CLAUDE.md.

**Grapheme addressing** (invariant 5, judgment): a new coordinate-taking path
resolves graphemes; `Width` only feeds paint and the display→grapheme cast.

## 4. Deps gate

```bash
mix deps.unlock --check-unused        # mix.lock carries nothing mix.exs dropped
mix hex.outdated                      # informational, not a failure
```

**The path dep is the sharp edge.** `{:tree_sitter_wasm, path: "../tree_sitter_wasm"}`
means geex compiles against whatever is on disk in the sibling repo —
uncommitted changes included — and `mix.lock` records nothing about it:

```bash
git -C ../tree_sitter_wasm status --short
git -C ../tree_sitter_wasm log -1 --format='%h %ad %s' --date=short
```

Dirty sibling state = **finding**: geex's green suite is then pinned to bytes
that exist in no commit anywhere. Report the files; the fix is to commit (or
stash) in the sibling and re-run the tests gate.

A **new dependency** needs an ADR (each existing one is justified in a comment
at its `mix.exs` line — a new dep without that comment is a finding too).

## 5. Report

```
SHIPSHAPE — geex @ <branch> <sha>
  tests        ✓|✗  compile -Werror ✓ · suite <n>+<d> doctests ×2 · gaps: <behavior lacking a test | TUI change w/o dogfood | none>
  docs         ✓|✗  ADR index <sync|missing NNNN> · verify-log <in step|behind: <commits>> · roadmap <true|stale: …> · drift: <doc: claim | none>
  conventions  ✓|✗  violations: <file:line — rule, or none>
  deps         ✓|✗  lock clean · sibling tree_sitter_wasm <clean|dirty: files> · outdated: <info>
  findings     <numbered, most severe first — each with the fix you'd apply>
```

Propose the fixes; apply only on request. All green → the ship is shipshape. ⛵
