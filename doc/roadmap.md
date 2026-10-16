# geex — Roadmap

Project-level stages, spanning the **editor core** and the **AI layer**. This is the
wide view; the AI-layer detail lives in [mcp-ai-integration.md](mcp-ai-integration.md)
§12, and the rationale for each call is in [adr/](adr/).

Guiding rule (from [vision.md](vision.md)): **build the *world* well; the *brain* is
bring-your-own.** The load-bearing early work is the command system — get it right and
undo, replay, collab, provenance, MCP export, and the dogfood loop all fall out of it.

---

## Where we are (2026-06)

**Current (2026-10-16):** 896 tests + 35 doctests green, `--warnings-as-errors` clean. geex installs as a local binary: `mix geex.deploy` builds it with Burrito and links `~/.local/bin/geex` ([adr/0036](adr/0036-installed-binary.md)). Since the
narrative below: the interactive TUI loop, highlighting, selection + clipboard, undo/redo, the
minibuffer's typed verbs, grid mode (human + agent halves) and the command palette all shipped.
**Direction changed on 2026-10-14 ([adr/0032](adr/0032-listener-first-agent-integration.md)):**
the MCP door is frozen; v0.5 is now the **ledger track** (reconcile as the primary agent path,
attested by captAInHook). Items 1–7 are built (item 5's display; item 6 the durable ledger, ADR-0033; item 7 panes, the file tree, the edits pane and holding open buffers, ADR-0034). Next is the maintainer's UI-testing review of the parked decisions (command-surface items 7–8; item 9 parks the slow work still in the key loop, [adr/0035](adr/0035-the-loop-never-waits.md)); the command-surface track at the
end of this file continues alongside it, since editor comfort is the other half of the point. The reconcile watcher is
now shown live against a real `inotify` backend. (Test counts quoted further down are as of their
own dates.)

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

## v0.5 — The ledger: agents edit natively, geex records, captAInHook attributes

**Redefined 2026-10-14 by [adr/0032](adr/0032-listener-first-agent-integration.md).** The
original v0.5 headline (the agent edits *through* geex over MCP, steered there by a preset) is
**frozen**: it works and stays tested, but it's no longer the plan. **Goal now:** whatever an
agent writes with its own native tools lands in geex's one undo history as reviewable,
undoable hunks, attributed to the harness, session and tool call by a captAInHook payload.

The ledger track, in order (each builds on the one before):

1. **Line-level reconcile diffs** — **built 2026-10-14**: `Geex.Edit.LineDiff` (myers over
   lines → bottom-up `replace` spans, verified to reproduce the disk bytes or fall back to one
   whole-text replace), `Buffer.dispatch_group/2` (all-or-nothing, one history entry per hunk,
   one change notification), each reconcile stamped `meta.reconcile = %{group, before_sha256,
   sha256}` (baseline and new disk bytes, 64 lowercase hex), and
   the per-path quiet period (`settle_ms`, default 50, 0 under test). Live-verified: a native
   Claude Code `Write` touching two lines appeared live as two hunks; `Alt+Z` undid them one
   at a time. Original plan: replace the whole-buffer `replace` with a myers line diff →
   one minimal `replace` per hunk, dispatched as one atomic group, so undoing an agent's
   change undoes *that hunk*, not the file. (Pairs with ADR-0020's diff work; pure, so
   table-testable.) **Plus write completion** (ADR-0032 amendment item 4): a per-path quiet
   period before diffing, so a mid-write read never lands as a half-edit hunk (`file_system`
   reports `MODIFY` and `CLOSE_WRITE` as the same `:modified` event).
2. **Conflict UX** — **built 2026-10-14** (ADR-0032 step-b amendment): a three-way merge
   (`Geex.Edit.Merge`) — disk hunks always land, your non-overlapping unsaved hunks are kept
   (still dirty), an overlapping one takes disk with a status-line notice and stays one undo
   away; applied with `expect_seq` (stale snapshot → retry). Original plan: decide
   and build the merge/prompt (non-overlapping hunks merge; overlapping ones ask), plus
   deletion handling and burst coalescing.
3. **Attestation intake** — **built 2026-10-14** (live-verified both orders; see testing.md).
   `Buffer.attest/2` (a history operation, ADR-0031-style)
   upgrades the buffer's **newest reconcile group**, whole and once, from `:external` to
   `{:agent, %{harness, session, …}}`, only when **both** the attestation's `before` and
   `sha256` equal the group's `before_sha256` and `sha256` (stamped since step 1). That one
   rule covers coalesced writes, no-op writes and stale entries (ADR-0032's later amendment).
   **Attestation-first is the primary path:** Claude Code writes atomically and reconcile waits
   out the quiet period, so an early attestation waits in a bounded **pending table** keyed
   (path, sha256), consumed by the matching group. `POST /attest` on the loopback listener,
   now started in TUI mode too; hashes must be 64 lowercase hex, and anything else is rejected
   with a 400. A `0600` discovery file (URL + token + pid) under `$XDG_RUNTIME_DIR/geex/`,
   removed on clean exit.
4. **The captAInHook payload** — **built 2026-10-15** (ADR-0032 step-d amendment):
   `integrations/captainhook/geex-attest.sh`, a fail-open `post-tool-use` oneshot handler the
   user registers in `~/.captainHook/handlers.json`; captAInHook itself stays unaware of geex.
   It attests only `Write` / `Edit` / `NotebookEdit` from `claude-code` (anything else sends
   nothing), parses with `jq`, sends `before` = sha256 of `originalFile` / `original_file` and
   `sha256` = sha256 of the disk, plus `prompt_id` (turn) and `tool_use_id`, and POSTs to every
   live discovery entry in parallel before exiting. A **CRLF** file matches because reconcile
   also stamps `before_sha256_lf` (the baseline with `\r\n` as `\n`, how Claude Code reports
   it). Tested against captAInHook's real envelopes (`test/fixtures/claude-code/`, from
   `3ddb467`).
5. **Surfacing in the TUI** — **display built 2026-10-15** (ADR-0032 step-e amendment): a `▌`
   gutter mark on each line an agent last wrote, and `✎ <harness>/<session8> · turn …` on the
   status line for the line under the cursor, both derived from `Geex.Blame` (a per-line
   `git blame` over the one history: shifts with edits, cleared by undo, relabelled on a late
   attestation). Shell and other unattested writes stay unmarked. Undo of a specific agent hunk
   without touching your own later edits shipped as the forward revert of item 6, step 3.
6. **The durable ledger** ([adr/0033](adr/0033-durable-ledger.md), accepted 2026-10-15): an
   append-only JSONL history log per file in `~/.local/state/geex/ledger/`, so quitting or a
   crash loses nothing. Reopening restores history, blame and unsaved edits when the disk
   matches the replayed synced hash, and otherwise records an `:external` gap. Build order:
   (1) extract the pure `Geex.History` (no behavior change) — **built 2026-10-15**; (2) the ledger codec, write path and
   restore — **built 2026-10-15**; (2b) the hash-only spool that credits agent edits made while a file isn't open — **built 2026-10-15**
   (single writes and same-session runs); (3) per-agent revert (`Alt+U` / `revert`,
   `revert-call`; refused when your later edits overlap) — **built 2026-10-15**; (4) `mix geex.ledger compact` /
   `forget` / `list` — **built 2026-10-15**. All of ADR-0033 is built.
7. **Panes, the file tree, the edits pane, and holding open buffers**
   ([adr/0034](adr/0034-panes-tree-edits-hold.md), accepted 2026-10-15). An open buffer no
   longer changes when its file does. It is marked "behind disk" and fast-forwards on demand
   (`Alt+L`, `fast-forward`, or Enter on its "disk is newer" row). Agent writes it holds are
   credited at the fast-forward by the spool's chain rule. A dirty buffer, and a save of a buffer
   that is behind, merge with `git merge-file`: conflicts become markers in the buffer, and a
   conflicting merge doesn't write. Panes are a tree (git's file list, rooted at the path's git
   top level) · editor · edits pane (file · who · when). Build order: (1) the hold,
   fast-forward, the git merge and save-while-behind — **built 2026-10-15**; (2) more than one
   buffer (`open`, `buffers`, `close`, a cursor and scroll per buffer) — **built 2026-10-15**;
   (3) `Geex.Layout`, panes and `Alt+O` (moved here from step 2: their first consumer) with the
   edits pane — **built 2026-10-15**; (4) the file tree — **built 2026-10-15**; (5)
   `user_modified` ("edited by you") — **built 2026-10-15**. All of ADR-0034 is built. The follow pane in the first draft was dropped.

Exit criteria: with captAInHook installed and the payload registered, an agent session
(Claude Code first) edits a file open in geex with its **native** tools; each change appears
live in the edits pane and lands as a hunk attributed to that session when you fast-forward
(ADR-0034); a shell write appears as `:external`; any of
them can be undone individually; replay still reproduces the state.

### What v0.5 shipped before the redefinition (Direction A — now frozen)

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
  [adr/0010](adr/0010-disk-truth-lsp-v05.md)). Not started — **deferred off the critical
  path by [adr/0032](adr/0032-listener-first-agent-integration.md)** (pharos serves agents;
  LSP in the human editor is a later nice-to-have).

Original exit criteria (Direction A, frozen): a real harness (claude-code first) connects to the running geex over
loopback HTTP and edits buffers; every edit is a provenance-tagged `%Command{}` in the
live shared undo history; out-of-band writes are reconciled as `:external`; sessions
replay. **Status:** the *connect + edit + provenance + save* clauses are proven live (an
external loopback MCP client; the named-harness-honoring-the-preset run is the open item);
`:external` reconcile is shown live (2026-10-14, once `inotify-tools` was installed on the dev
box: an out-of-band disk write to an open buffer's file was reconciled into the live buffer via
the real watcher — see [testing.md](testing.md)); replay is proven by the §15c cassette (`Dispatch.replay/2`), not
re-shown in the dogfood.

v0.5 **non-goals** (deferred, [mcp-ai-integration.md](mcp-ai-integration.md) §12):
unsaved-state LSP, WASM extension host, third-party extension API, distributed Erlang,
*remote* HTTP / WS / TLS / multi-client (v0.5 HTTP is **loopback only**), image/resource
content blocks, OS-sandbox *enforced* rung (lean on harnesses' own sandboxes; geex builds
none — [adr/0016](adr/0016-external-harness-integration.md)).

## Post-0.5 — Direction B, extensions, distribution

Each gated on a **named consumer** (the brain/world test, [vision.md](vision.md) §3):

- **Distribution** — *local install built* ([adr/0036](adr/0036-installed-binary.md)):
  a Burrito binary carrying this machine's ERTS and the glibc tree_sitter_wasm NIF, installed by
  `mix geex.deploy`. *Portable* binaries (the Mac, other Linux machines) need the NIF built per
  target (`rustler_precompiled`, or Zig-linked musl) and Burrito's default phases back; gated on
  a second machine.
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
   input surfaces. **Built and live-verified** ([adr/0029](adr/0029-selection-primitive.md),
   *Accepted*): the pure core, the interactive wiring (loop selection field, `Alt+H` +
   `Alt+B` select-all, render highlight incl. the multi-line / CRLF cases, `Alt+N`/Esc clear),
   and clipboard `cut`/`copy`/`paste` (`Alt+X/C/V`) consuming `range/1`. The **typed** verbs
   and grid-range ops remain (they ride item 2).
2. **The command catalog + the view-action tool category** — **built, first slice**
   ([adr/0030](adr/0030-view-action-tool-category.md), *Accepted*): `Geex.MCP.ViewActions`
   (field-spec → `tools/list`; the fourth `tools/call` route) with **`line`** as the first
   member, and the **typed-verb surface** `Geex.Loop.Verbs` — chords and typed verbs share one
   action vocabulary through the loop's `apply_action` (the parity mechanism); an agent-moved
   cursor now repaints (`{:geex_cursor}` notify). The agent's grid tools (`goto`, `copy`) landed
   as their own category, `Geex.MCP.Grid` (item 4). Remaining: `scroll` / coordinate `select`
   members, and re-basing the `Verbs` table on `Geex.Command.Catalog` (the palette shipped the
   catalog; the verbs don't resolve against it yet, nor are undo/redo/paste agent tools).
3. ~~**Refactor go-to-line through the real system**~~ — **done** (rode item 2): the
   `run_command` hack is deleted; bare `N`, typed `line N`, and `tools/call line` converge on
   `ViewActions.line/1`.
4. **The remaining minibuffer modes** ([adr/0028](adr/0028-editor-shell-and-minibuffer.md) §2):
   - **grid** (`Alt+G`) — **built, first slice** ([adr/0027](adr/0027-grid-command-addressing.md)
     amendment): `Geex.Coord` (`parse`/`to_caret`/`to_span`) + `Width.col_at_display` (the
     display→grapheme cast) + the contextual display-column **ruler** and dotted **grid-line
     overlay**; `copy`/`cut`/`goto` over coordinates, live-verified against a wide glyph.
     The **agent half is built** too (ADR-0027 grid-agent amendment): `Geex.Command.Type`
     `:coord`/`:coord_range` (the same `Coord.parse/1` grammar, resolved as buffer-absolute
     graphemes) + `Geex.MCP.Grid` (`goto`, `copy` onto the shared clipboard ring). Remaining: agent
     `cut`, coordinate `select`, block/multi ranges, the `cursor_x`-oracle *automated* cast test.
   - **palette** (`Alt+P`) — **built** (ADR-0028 §3 amendment): `Geex.Fuzzy` + `Geex.Command.Catalog`
     + the `:palette` minibuffer mode with a candidate popup (`Alt+W`/`Alt+S` navigate, Enter runs).
   - Remaining: incremental **search** (`/`) and the **fuzzy file/buffer finder** (path
     tab-completion — one `Completion` abstraction, sources per mode; reuses `Geex.Fuzzy`).
5. **undo / redo** — **built** ([adr/0031](adr/0031-undo-redo-history-operations.md)): history
   operations on `Alt+Z` / `Alt+Shift+Z` (replay-from-base over the recorded history + the loaded
   `base`, [adr/0014](adr/0014-editor-state-and-dispatch-ownership.md)); a fresh edit clears the
   redo stack, the cursor lands from the returned command, and overlays shift across the revert
   on a byte-footprint diff + monotonic `seq` (the ADR-0031 §5 revision — flicker-free). The
   typed `undo`/`redo` verbs are **built** (item 2's verb surface); insert coalescing is
   deferred polish.
6. **Discharge the parity backlog** ([adr/0028](adr/0028-editor-shell-and-minibuffer.md)
   amendment §2) — **largely done** (rode item 2): `quit`/`exit` typed verbs, `save` on
   `Ctrl-O` ([adr/0026](adr/0026-terminal-input-model.md)) *and* as a typed verb, the clipboard
   + selection + undo/redo verb twins. Remaining: typed twins for the other operation tools
   (`open`/`new`/`close`) — they want the file-path completion of the finder (item 4).
7. **Special keys awaiting a decision** — *to review during UI testing* (noted 2026-10-15). The
   input parser now reads every terminal control sequence whole (`ebeca5a`, `23a886d`;
   [adr/0026](adr/0026-terminal-input-model.md) is the input model): arrows, Home, End and Delete
   work, and every other special key is **dropped** (never typed as text). Each of these needs a
   decision about what it should do, then a small build:
   - **Home / End / Delete inside the minibuffer.** The minibuffer has its own key handling (only
     Left, Right, Backspace today). Likely just "same as in the buffer"; small.
   - **Page Up / Page Down.** Move the cursor one screen. The parser side is one line; the screen
     height lives in the loop, not the pure keymap, so the loop handles it. Small.
   - **Ctrl+Left / Ctrl+Right.** Likely word motion, which exists as `Alt+Q` / `Alt+E`. The parser
     needs to decode the modifier (`ESC [ 1 ; 5 C`). Small.
   - **Shift+arrows.** The common convention is "extend the selection" (selection exists,
     `Alt+H`). Decide whether to adopt it. Small to medium.
   - **Alt + a digit or symbol** (`Alt+1` sends `ESC 1`). Still emits Esc and types the `1`. Read
     it as an Alt chord, or drop it. Tiny.
   - **F-keys, Insert.** Nothing to bind them to yet (no overwrite mode). Leave them dropped until
     something wants one.
   - **The Esc timeout** (40 ms, `Geex.TerminalIO`). Watch for slow remote (SSH) links that split a
     key's bytes past it; the symptom would be a key's tail typed as text.
8. **Attribution ideas awaiting a decision** — *to review during UI testing* (noted 2026-10-15;
   design in [adr/0032](adr/0032-listener-first-agent-integration.md) and
   [adr/0033](adr/0033-durable-ledger.md)). Floated while building the ledger; none is decided:
   - **A mark colour per agent session.** Today every agent's `▌` is the same accent colour, so
     telling two sessions apart takes moving the cursor to read the status line. A colour picked
     from the session id (the glyph unchanged) would show it at a glance. Small.
   - **Labelling shell writes.** A `sed` or script run through an agent's Bash tool is recorded
     `:external`: the hook sees the command text but has no before/after content to prove what
     it changed. Proposed: a hook before each Bash call and the existing one after it bracket the
     call in time, and changes to open files in between are labelled "changed **while** session X
     ran `cmd`", never "by", so attribution by timing never claims authorship (ADR-0032's rule).
     Needs a `pre-tool-use` registration in `~/.captainHook/handlers.json`, a new message to geex,
     and an ADR amendment. About the size of ADR-0032 step c.
   - **`revert-call` from a line you rewrote.** It takes back the tool call that last wrote the
     cursor's line, so on a line you've since edited it says "nothing to revert" even when other
     lines of that call are still the agent's. Fine as designed; the alternative is to also look
     at the call's other lines, or offer a picker of recent agent calls.
   - **Credit for two or more agent writes in a row to a CRLF file** (confirmed live by the
     coordinator session, 2026-10-15; already listed as a limitation in ADR-0033 F). A single
     write is credited. A chain isn't: the payload's `before` hashes Claude Code's text with
     `\r\n` turned into `\n`, but its `sha256` hashes the CRLF bytes on disk, so write 2's `before`
     never equals write 1's `sha256`. The chain stays `:external` (a missed credit, never a wrong
     one), whether held (ADR-0034) or reopened. Two fixes:
     - the payload sends an optional `sha256_lf` (the after bytes folded the same one-pass way;
       `sed 's/\r$//'` gets a lone `\r` wrong) and chains link on either hash. This covers held
       and reopened files and stays within message `v: 1`. `perl -0777 -pe 's/\r\n/\n/g'` is
       a byte-exact fold on Linux and macOS (the coordinator checked): `sed -z` is GNU-only and
       `jq` mangles non-UTF-8 bytes;
     - geex records both hashes of each disk text the watcher reads while a buffer is held. This
       needs no payload change but covers held buffers only.
     Small; it matters only for CRLF files.
9. **Slow work still in the key loop** — *parked* ([adr/0035](adr/0035-the-loop-never-waits.md),
   accepted 2026-10-16: the loop never waits on slow work; the tree's reader, `6a6e3df`, is the
   first instance). Move each when a real file makes it measurably slow:
   - **Save and fast-forward** (they read the file; a two-sided save runs `git merge-file`): a
     clean merge and save 93 ms at 1 MB, 759 ms at 10 MB; a fast-forward 29 ms and 445 ms. Needs a
     "saving…" status, with edits to that buffer queued meanwhile.
   - **Opening a file** replays its ledger in `Buffer.init/1`: 9 ms at 1,000 entries, 137 ms at
     10,000. `geex a b c` could also start its buffers in parallel.
   - **Reconcile, one file at a time.** It never blocks typing; parallel would only land a big
     rewrite's "behind" marks sooner.
   Cheap on the rule, not decided: **project search** (files in parallel, results streamed into a
   pane, a new query kills the old search); **git status marks** on tree rows (groundwork for the
   diff view); **idle housekeeping** (`Ledger.compact`, highlighting buffers that aren't shown).

**Bugs shelf:** [bugs.md](bugs.md) — BUG-1 (renderer atomicity) and BUG-2 (highlighter two-pass
tail flicker) are both **FIXED** (2026-06-09); the shelf is currently clear.

---

## The throughline

Everything above is one bet, staged: **make the command the universal unit, run it
through one dispatcher, and tag it with provenance.** The TUI, the MCP server, the AI
features, collab, and the test harness are all just *consumers and projections* of that
one object. Get v0.1 right and the rest is addition, not redesign.
