# geex — Roadmap

Project-level stages, spanning the **editor core** and the **AI layer**. This is the
wide view; the AI-layer detail lives in [mcp-ai-integration.md](mcp-ai-integration.md)
§12, and the rationale for each call is in [adr/](adr/).

Guiding rule (from [vision.md](vision.md)): **build the *world* well; the *brain* is
bring-your-own.** The load-bearing early work is the command system — get it right and
undo, replay, collab, provenance, MCP export, and the dogfood loop all fall out of it.

---

## Where we are (2026-06)

The command system is built **and wired into the running app** (ADR-0014). The
dispatch "world" is `Geex.EditorState` (today `{doc}`); a command's pure runner is
`run(command, %EditorState{})`. `Geex.Dispatch` has the pure inner layer
(`apply_command/2` + deterministic `replay/2`) and the public `run/1` (resolve active
buffer → gather → apply → scatter → record). `Geex.Buffer` owns the `EditorState` + the
one undo history and exposes the read-only `snapshot/1` / `get_text/1` / `history/1`
surface; `Geex.Session` owns the active-buffer pointer + the view-local cursor and
exposes `snapshot/0` (§15b). `Geex.CommandRegistry` (seeded with `Insert`/`Delete`) is in
the supervision tree. The macro (`Geex.Command`), `Command.{Meta,Field,Type}`,
`Geex.Buffer.Doc`, the virtual screen (`Cell`/`Screen`/`Renderer`/`Rect`), `TerminalIO`,
and `Input.Parser` round it out, plus the §15c-ii golden-pair cassette
([test/geex/cassette_test.exs](../test/geex/cassette_test.exs)) — the v0.1 replay exit
criterion, proven with no LLM.

**The MCP layer (Direction A) is now building:** `Geex.MCP.Schema` (field-spec →
JSON-Schema tool descriptors, the §3a/§4 free projection), `Geex.MCP.Protocol`
(pure `handle_line/1` — JSON-RPC envelope, `initialize`/`tools/list`/`tools/call`/`ping`,
provenance via `Dispatch.run/1`, version 2025-11-25), and `Geex.MCP.HTTP` (the **loopback
Streamable HTTP transport** — a Bandit/Plug listener bound to `127.0.0.1`, feature-gated by
`start_http_mcp`). A real harness can connect over loopback HTTP and edit the live buffer
with provenance — dogfood == production ([adr/0018](adr/0018-mcp-transport-streamable-http.md)).
Edit coverage now includes a range `replace` ([test/geex/buffer/doc_test.exs](../test/geex/buffer/doc_test.exs)),
`Geex.Buffer` has **file I/O** (load-on-open + `save/1`), and the **file lifecycle +
multi-buffer + MCP operation tools** are built: `Geex.Session.open_file/1` (find-or-start a
path-registered buffer, make it active), and a third MCP tool category — `open_file`/`save_file`
**operation tools** ([Geex.MCP.Operations](../lib/geex/mcp/operations.ex)) that act on
`Session`/disk and are **not** recorded as edits ([adr/0019](adr/0019-file-lifecycle-and-operation-tools.md)).
`tools/call` routes by category and `tools/list` merges all three. A real harness can now
**open, edit, and save real files on disk** over loopback. **First dependency:** Bandit +
Plug (JSON stays built-in). **195 tests + 8 doctests green.** What's verified by hand is
logged in [testing.md](testing.md).

The remaining file layer is **decided and recorded, not yet built**: the **reconcile** floor
via the `:file_system` watcher with content-comparison echo-suppression
([adr/0017](adr/0017-reconcile-file-watch.md)) — the deliberate next increment — and the
**diff / search-replace `edit` tool** that compiles to `replace` (ports DeepSeek-Moby's
tiered matcher, [adr/0020](adr/0020-diff-edit-tool.md), [research](research/diff-edit-tool.md)).

Cursor-relative resolution and the `Geex.Clipboard` subsystem are designed
([adr/0014](adr/0014-editor-state-and-dispatch-ownership.md),
[adr/0015](adr/0015-clipboard-subsystem.md)) but deferred to their first real consumer
(interactive TUI typing; copy/cut/paste) per the named-consumer rule.

The v0.5 AI-layer shape is also now decided: how geex works with pre-built harnesses
(per-harness presets + the enforcement ladder, [adr/0016](adr/0016-external-harness-integration.md)),
the honest reconcile floor ([adr/0017](adr/0017-reconcile-file-watch.md)), and the MCP
transport (loopback Streamable HTTP, dogfood == production,
[adr/0018](adr/0018-mcp-transport-streamable-http.md)) — the OS-sandbox enforced rung is
smoke-tested ([evidence](evidence/rung2-sandbox-smoke/)).

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

**Goal:** an external harness edits real buffers through the same path a human does,
by **attaching to the running geex** — dogfood == production.

Ships:
- **`Geex.MCP.{Protocol,Dispatch,…}`** — the transport-agnostic protocol core first
  (`handle_line/1`, `tools/list` from the field-spec, `tools/call → Dispatch.run/1`,
  provenance), the pharos-ported pure-`handle_line` discipline
  ([adr/0006](adr/0006-elixir-not-gleam.md)), feature-gated (default-off).
- **Loopback Streamable HTTP transport (the live dogfood)** served from `geex --serve`
  (`Bandit`+`Plug` — geex's first dep); a real harness *connects* and edits land in the
  live session ([adr/0018](adr/0018-mcp-transport-streamable-http.md)). stdio is demoted
  to a hermetic CI/conformance harness.
- **File lifecycle + operation tools (done)** — `Geex.Buffer` load/save, multi-buffer +
  path addressing (`Session.open_file/1`, path-registered buffers), and MCP **operation
  tools** (`open_file`/`save_file` — a third tool category; not recorded as edits,
  [adr/0019](adr/0019-file-lifecycle-and-operation-tools.md)).
- **The `edit` (diff / search-replace) tool** — harness-ergonomic editing that compiles to
  the `replace` primitive (ports DeepSeek-Moby's tiered matcher,
  [adr/0020](adr/0020-diff-edit-tool.md)).
- **Harness presets + the reconcile floor** — checked-in per-harness presets (deny
  built-in writers, point MCP config at geex) and `Geex.Reconcile` (the `:file_system`
  watcher; out-of-band disk writes → `%Command{}` tagged `:external`, never silent;
  echo-suppressed by content comparison)
  ([adr/0016](adr/0016-external-harness-integration.md),
  [adr/0017](adr/0017-reconcile-file-watch.md)).
- **MCP-client connection to an external pharos** for LSP — **disk-truth only**; pharos
  is *not bundled* ([adr/0008](adr/0008-pharos-not-bundled.md),
  [adr/0010](adr/0010-disk-truth-lsp-v05.md)).

Exit criteria: a real harness (claude-code first) connects to the running geex over
loopback HTTP and edits buffers; every edit is a provenance-tagged `%Command{}` in the
live shared undo history; out-of-band writes are reconciled as `:external`; sessions
replay.

v0.5 **non-goals** (deferred, [mcp-ai-integration.md](mcp-ai-integration.md) §12):
unsaved-state LSP, WASM extension host, third-party extension API, distributed Erlang,
*remote* HTTP / WS / TLS / multi-client (v0.5 HTTP is **loopback only**), image/resource
content blocks, OS-sandbox *enforced* rung (lean on harnesses' own sandboxes; geex builds
none — [adr/0016](adr/0016-external-harness-integration.md)).

## Post-0.5 — Direction B, extensions, distribution

Each gated on a **named consumer** (the brain/world test, [vision.md](vision.md) §3):

- **Direction B (geex-calls-LLM)** — in-editor AI features (rename-suggestion,
  commit-message) on the thin `balance_beam` extraction helper; results become
  `%Command{}`s via the §2 composition rule ([adr/0011](adr/0011-direction-b-balance-beam.md)).
  LLM-response cassettes (§15c-i) + eval ride on this.
- **Editor-state contract / pharos co-location (§8)** — only if a feature needs
  unsaved-state answers *and* stdio warmup is a measured bottleneck.
- **Enforcement ladder, upper rungs ([adr/0016](adr/0016-external-harness-integration.md))**
  — Rung 2 *OS-sandbox enforced* config (lean on Codex/Claude Code shipped sandboxes;
  optional geex bubblewrap wrapper for sandbox-less harnesses); Rung 3 *WASI-P2/wasmex*
  for thin geex-authored guests only. Gated on a named consumer.
- **Extension tiers 2–3 (§14)** — wasmex sandbox; Gleam typed extension API — when a
  real (untrusted / third-party) extension author exists.
- **Layers 3–4 (remote)** — distributed-Erlang collab; *remote* HTTP/WS+TLS + multi-client
  — when a remote/browser consumer + security model exist (v0.5 already ships loopback
  HTTP, [adr/0018](adr/0018-mcp-transport-streamable-http.md); the trust gate for remote is
  the work).

---

## The throughline

Everything above is one bet, staged: **make the command the universal unit, run it
through one dispatcher, and tag it with provenance.** The TUI, the MCP server, the AI
features, collab, and the test harness are all just *consumers and projections* of that
one object. Get v0.1 right and the rest is addition, not redesign.
