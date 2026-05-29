# geex — Roadmap

Project-level stages, spanning the **editor core** and the **AI layer**. This is the
wide view; the AI-layer detail lives in [mcp-ai-integration.md](mcp-ai-integration.md)
§12, and the rationale for each call is in [adr/](adr/).

Guiding rule (from [vision.md](vision.md)): **build the *world* well; the *brain* is
bring-your-own.** The load-bearing early work is the command system — get it right and
undo, replay, collab, provenance, MCP export, and the dogfood loop all fall out of it.

---

## Where we are (2026-05)

The virtual screen exists and is tested: `Cell`, `Screen`, `Renderer` (pure `diff/2`),
`Rect`, with `async: true` ExUnit tests. `TerminalIO` (prim_tty single-writer),
`Application` (feature-gated child pattern), and an `Input.Parser` exist. `Buffer` is a
v0.1 stub (no edit ops / `get_text`); `Session` references a `Geex.Dispatcher` not yet
written. **No deps** (`mix.exs` is `deps: []`). Design is locked; implementation of the
command system is the next real work.

---

## v0.1 — The command system + a usable TUI (the foundation)

**Goal:** one path exists, and a human can edit a buffer in the terminal.

Ships:
- **`Geex.Command` macro** → struct + runner + help + the serialization-neutral
  **field-spec** ([adr/0004](adr/0004-neutral-field-spec.md)).
- **`parse/1`** (one parser; minibuffer + future MCP args share it), **`CommandRegistry`**,
  **`Geex.Dispatch.run/1`** — the single shared path ([adr/0003](adr/0003-one-shared-path.md)).
- **`%Command.Meta{}`** provenance (`actor` / `at` / `prompt_hash` / `origin`) from day
  one ([adr/0005](adr/0005-provenance-on-every-command.md)).
- **`Buffer`** real edit ops + a read-only query surface (`get_text/1`, `Session.snapshot/0`).
- **Minibuffer** + TUI editing on `prim_tty` (the human consumer of commands).

Exit criteria: a human edits a buffer through `%Command{}`s into one undo history; the
`%Command{}`-sequence cassette (§15c-ii) replays deterministically in CI — **free,
no LLM** — proving the replay property before any AI work.

## v0.2 — Command coverage + the MCP projection

**Goal:** the command set is rich, and it can be *projected* without new machinery.

Ships:
- Real editing command coverage (motion, edit, clipboard `cut a1-b5`, etc.).
- **MCP tool export** — `tools/list` + the field-spec→JSON-Schema renderer
  ([adr/0004](adr/0004-neutral-field-spec.md)). Free once the macro emits the neutral spec.
- Property tests + Dialyzer for the round-trip and (soon) the JSON-RPC envelope (§15a).

Exit criteria: every command auto-exports as an MCP tool schema with no hand-sync.

## v0.5 — Direction A: the LLM drives geex (the headline)

**Goal:** an external LLM edits real buffers through the same path a human does.

Ships:
- **`Geex.MCP.{Protocol,Dispatch,Stdio,Writer,Supervisor}`** — the pharos-ported pure
  core + the two Port gotchas ([adr/0006](adr/0006-elixir-not-gleam.md)), feature-gated
  (`start_mcp`, default-off).
- A **thin headless slice first** (`handle_line/1` + `tools/list` + `tools/call`, TUI
  off) as the dogfood/test harness — point claude-code at `geex --mcp` and an LLM edits
  buffers headlessly (§15b).
- **MCP-client connection to an external pharos** for LSP — **disk-truth only**; pharos
  is *not bundled* ([adr/0008](adr/0008-pharos-not-bundled.md),
  [adr/0010](adr/0010-disk-truth-lsp-v05.md)).

Exit criteria: claude-code edits geex buffers via MCP tools; every edit is a
provenance-tagged `%Command{}` in the shared undo history; sessions are replayable.

v0.5 **non-goals** (deferred, [mcp-ai-integration.md](mcp-ai-integration.md) §12):
unsaved-state LSP, WASM extension host, third-party extension API, distributed Erlang,
HTTP/WS, multi-client, image/resource content blocks.

## Post-0.5 — Direction B, extensions, distribution

Each gated on a **named consumer** (the brain/world test, [vision.md](vision.md) §3):

- **Direction B (geex-calls-LLM)** — in-editor AI features (rename-suggestion,
  commit-message) on the thin `balance_beam` extraction helper; results become
  `%Command{}`s via the §2 composition rule ([adr/0011](adr/0011-direction-b-balance-beam.md)).
  LLM-response cassettes (§15c-i) + eval ride on this.
- **Editor-state contract / pharos co-location (§8)** — only if a feature needs
  unsaved-state answers *and* stdio warmup is a measured bottleneck.
- **Extension tiers 2–3 (§14)** — wasmex sandbox; Gleam typed extension API — when a
  real (untrusted / third-party) extension author exists.
- **Layers 3–4** — distributed-Erlang collab; HTTP/WS+TLS — when a remote/browser
  consumer + security model exist ([adr/0001](adr/0001-build-on-the-beam.md) gives the
  primitive; the trust gate is the work).

---

## The throughline

Everything above is one bet, staged: **make the command the universal unit, run it
through one dispatcher, and tag it with provenance.** The TUI, the MCP server, the AI
features, collab, and the test harness are all just *consumers and projections* of that
one object. Get v0.1 right and the rest is addition, not redesign.
