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
**open, edit, and save real files on disk** over loopback. The **reconcile floor** is built
too ([adr/0017](adr/0017-reconcile-file-watch.md)): `Geex.Reconcile` watches each open
buffer's backing file (the `:file_system` watcher) and replays out-of-band disk writes as
`:external`-tagged `%Command{}`s into the one undo history, with content-comparison
echo-suppression — Rung 0, the always-on honest floor under every enforcement rung. **Deps:**
Bandit + Plug (HTTP), `:file_system` (watcher); JSON + diffing stay built-in. **212 tests +
8 doctests green.** What's verified by hand is logged in [testing.md](testing.md).

The file layer is now complete: the **diff / search-replace `edit` tool** is built
([Geex.Commands.Edit](../lib/geex/commands/edit.ex) + the pure
[Geex.Edit.Resolve](../lib/geex/edit/resolve.ex), [adr/0020](adr/0020-diff-edit-tool.md),
[research](research/diff-edit-tool.md)). An LLM edits by quoting old text → new text; geex
resolves it (exact-unique, then whitespace-normalized window + reindent; refuse-never-guess,
stricter than DeepSeek-Moby) and compiles each block to the `replace` primitive as **one
atomic command** (all-or-nothing). **251 tests + 8 doctests green.** The v0.5 MCP write
surface — edit tools (`insert`/`delete`/`replace`/`edit`), the read snapshot, and the
operation tools (`open_file`/`save_file`) — is in place.

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
- **The `edit` (diff / search-replace) tool (done)** — harness-ergonomic editing that
  compiles to the `replace` primitive as one atomic command (ports DeepSeek-Moby's tiered
  matcher, stricter — refuse-never-guess, [adr/0020](adr/0020-diff-edit-tool.md)).
- **The reconcile floor (done)** — `Geex.Reconcile` (the `:file_system` watcher;
  out-of-band disk writes → `%Command{}` tagged `:external`, never silent; echo-suppressed
  by content comparison) ([adr/0017](adr/0017-reconcile-file-watch.md)).
- **Per-harness presets + the serve switch (done; Claude Code flagship)** — `mix geex.serve`
  (`GEEX_SERVE=1` via `config/runtime.exs`) brings up the loopback MCP listener, and
  `presets/claude-code/` ships the **Rung 1** preset — an `.mcp.json` pointing the harness at
  geex plus a `permissions.deny` of its structured writers
  ([adr/0016](adr/0016-external-harness-integration.md), advisory-by-cooperation; shell writes
  stay Rung 0's job). Verified end-to-end *over the wire*: an external `curl` client did
  `initialize → tools/list → open_file → insert → save_file` against a running geex and the
  edit landed as a provenance-tagged `%Command{}` on disk ([testing.md](testing.md)). Still
  pending: a live *claude-code-honoring-the-preset* run (vs. the `curl` proof), and the
  other first-class presets (Codex, Gemini, Continue, Roo, OpenCode).
- **MCP-client connection to an external pharos** for LSP — **disk-truth only**; pharos
  is *not bundled* ([adr/0008](adr/0008-pharos-not-bundled.md),
  [adr/0010](adr/0010-disk-truth-lsp-v05.md)). Not started — the remaining v0.5 ship.

Exit criteria: a real harness (claude-code first) connects to the running geex over
loopback HTTP and edits buffers; every edit is a provenance-tagged `%Command{}` in the
live shared undo history; out-of-band writes are reconciled as `:external`; sessions
replay. **Status:** the *connect + edit + provenance + save* clauses are proven live (an
external loopback MCP client; the named-harness-honoring-the-preset run is the open item);
`:external` reconcile is core-tested but not yet shown against a live `inotify` backend
(absent on the dev box); replay is proven by the §15c cassette (`Dispatch.replay/2`), not
re-shown in the dogfood.

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
- **ACP host / bring-your-own-agent** — a *third* protocol seam alongside the MCP **server**
  (Direction A) and the MCP **client** (pharos): geex as an Agent Client Protocol *editor*,
  spawning an agent subprocess over JSON-RPC ("LSP for agents", Zed's
  [bring-your-own-agent](https://zed.dev/blog/bring-your-own-agent-to-zed)). Gated on a named
  consumer — the proposed first one is **porting DeepSeek Moby** (today the VS Code extension)
  to an ACP agent. Currently an open question in [notes.md](notes.md) "Agent integration";
  *needs an ADR before code.* (Distinct from the already-built Moby *matcher* in the `edit`
  tool, [adr/0020](adr/0020-diff-edit-tool.md).)

---

## The editor-experience layer (highlighting · themes · TUI)

Orthogonal to the AI-layer staging above — this is the *"build the world well"* axis
([vision.md](vision.md)) that makes geex a place a human (and an LLM) actually edits.

**Built:**
- **Highlighter** — tree-sitter on the WASM tier via the standalone `tree_sitter_wasm` NIF;
  emits capture-tagged spans ([adr/0021](adr/0021-capability-connections.md)).
- **The capability reactor** — a per-buffer process that fires highlighting off the command
  stream (async, coalesced, latest-wins) and exposes the overlay
  ([adr/0022](adr/0022-capability-reactor.md)).
- **Themes are data** — native JSON keyed on tree-sitter captures, longest-prefix resolution,
  truecolor SGR + alpha-flatten; Birds of Paradise is the bundled reference; a Zed importer reads
  the in-vocabulary ecosystem ([adr/0023](adr/0023-theming-and-extension-loading.md)).
- **The TUI core** — `TerminalIO` (`:prim_tty`, NIF-free) + `Screen`/`Cell`/`Renderer`/`Sgr`
  (cell diff → bytes); extractable but kept in geex for now
  ([adr/0024](adr/0024-tui-core-extractable.md)).
- **Display width** — `Geex.Width` (`:unicode_util`-backed, NIF-free): wide/CJK/emoji glyphs take
  two columns via a lead + continuation cell, zero-width marks take none. Closes the first of
  ADR-0024's "half a toolkit" gaps.

**Pending (each gated on its named consumer):**
- **The user-config layer** — theme selection + grammar/extension paths in `~/.config/geex/
  config.toml`, precedence + cache ([adr/0025](adr/0025-user-config-layer.md), *Proposed*). The
  theme loader is path-ready; this is the reader that points at it (the userpath-theme install
  story).
- **The interactive TUI loop** — render the reactor's overlay each frame against an open buffer
  ([adr/0024](adr/0024-tui-core-extractable.md)). Brings the keymap (→ user-config) and the
  cursor/clipboard consumers ([adr/0014](adr/0014-editor-state-and-dispatch-ownership.md),
  [adr/0015](adr/0015-clipboard-subsystem.md)). **In flight:** the loop runs, with a
  line-number gutter, active-line highlight, vertical + horizontal scroll bars, the
  Birds-of-Paradise theme, the `Alt`-key keymap (WASD/Q-E/R-F motion, `Alt+M`), and the
  **minibuffer first slice** (`:command` mode = bare-line-number go-to-line). Syntax overlay
  rendering + the cursor/clipboard consumers are the remaining pieces.
- **Remaining toolkit gaps** — truecolor→256/16 degradation (capability detect), mouse input.

### The command surface & shell (in flight — the minibuffer track)

The minibuffer is built (one mode); these are the next steps, ordered by dependency. Shared
design in [adr/0028](adr/0028-editor-shell-and-minibuffer.md) (shell + parity),
[adr/0027](adr/0027-grid-command-addressing.md) (grid + ruler), and
[notes.md](notes.md) "Editing & selection bindings".

1. **The `Selection` primitive** (`%Selection{anchor, active}`) — the shared dependency under
   both highlight mode (`Alt+H`, interactive) and grid ranges (declarative); one span, two
   input surfaces. **Pure core + tests built** ([adr/0029](adr/0029-selection-primitive.md),
   *Proposed*); the interactive wiring (view field, `Alt+H`, render highlight, clipboard
   consuming `range/1`) is the remaining build. Unblocks clipboard `cut`/`copy`/`paste`
   (`Alt+X/C/V` + typed verbs) and grid-range ops.
2. **The command catalog + the view-action tool category** — a *fourth* tool category
   (view actions: `line`/`scroll`/`select`/`undo`) registered with field-specs like the
   operation tools, so they render into `tools/list` (palette-discoverable, agent-callable)
   without being recorded edits ([adr/0030](adr/0030-view-action-tool-category.md),
   *Proposed*). This is what the palette and the parity backlog stand on.
3. **Refactor go-to-line through the real system** — replace the `loop.ex` `run_command`
   hack with a registered `line N` view-action (the bare-number shortcut preserved as sugar);
   the first member of the view-action category ([adr/0030](adr/0030-view-action-tool-category.md)).
4. **The remaining minibuffer modes** ([adr/0028](adr/0028-editor-shell-and-minibuffer.md) §2):
   **palette** (`Alt+P` / typed `palette`), **grid** (`:coord`/`:coord_range` cast →
   `Coord.to_span` → copy/cut/replace, [adr/0027](adr/0027-grid-command-addressing.md)) with
   the **display ruler + grid-line overlay** (the ADR-0027 amendment; `cursor_x`-verified
   display↔grapheme cast), incremental **search** (`/`), and the **fuzzy file/buffer finder**
   (with path tab-completion — one `Completion` abstraction, sources per mode).
5. **undo / redo** — history-navigation verbs on `Alt+B` / `Alt+Shift+B` + typed `undo`/`redo`.
   The substrate exists (Buffer owns the recorded-command history, `Dispatch.replay/2`,
   [adr/0014](adr/0014-editor-state-and-dispatch-ownership.md)); this is the user-facing
   navigation, never given a positive ADR/roadmap slot before — *a real gap, now homed here.*
6. **Discharge the parity backlog** ([adr/0028](adr/0028-editor-shell-and-minibuffer.md)
   amendment §2): a `quit`/`exit` typed verb; chords for the operation tools (`save` = Ctrl-O
   per [adr/0026](adr/0026-terminal-input-model.md)).

**Bugs shelf:** [bugs.md](bugs.md) — BUG-1 (typing flicker: add synchronized output +
conditional show-cursor) is open and should land alongside this track.

---

## The throughline

Everything above is one bet, staged: **make the command the universal unit, run it
through one dispatcher, and tag it with provenance.** The TUI, the MCP server, the AI
features, collab, and the test harness are all just *consumers and projections* of that
one object. Get v0.1 right and the rest is addition, not redesign.
