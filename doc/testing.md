# geex — Testing & verification

Two parts:

1. **[Strategy](#strategy)** — how geex is tested and why it's testable (the short
   version of [mcp-ai-integration.md](mcp-ai-integration.md) §15, which has the
   rationale).
2. **[Verification log](#verification-log)** — an **append-only, dated, commit-anchored
   record of what was checked by hand and considered "good" at a point in time.** This
   is history to refer back to, not a plan; never rewrite past entries.

---

## Strategy

geex is testable bottom-up because its hot paths are **pure** and its write path is a
**value** (a `%Command{}`), not a side effect. The discipline, everywhere: **assert
against the value** — buffer text, cursor, the command history — *never against rendered
bytes*.

The pyramid (detail + rationale in §15a):

1. **Pure unit** — the highest-value, most portable layer. The macro-generated
   `parse/1`, `Geex.Dispatch.apply_command/2` and `replay/2` over an
   `%EditorState{}`, `Geex.EditorState` ops, and (later) `MCP.Protocol.handle_line/1`
   and the field-spec→JSON-Schema renderer. All pure `value -> value`.
2. **Property + Dialyzer** (§5 mandates this) — the §1 round-trip the compiler can't
   enforce: `minibuffer-string → %Command{}` and `MCP-args → %Command{}` must yield the
   *same* struct; the JSON-RPC envelope (id echo, request-vs-notification, the three
   outcomes). *Lands with the MCP projection (v0.2).*
3. **Integration** — `Dispatch.run/1 → Buffer → undo history` with provenance present
   and correct; feature-gated supervision subtrees start/stop cleanly (mirroring the
   `terminal_io_child/0` gate).
4. **End-to-end dogfood-replay** — §15b/§15c.

### The two cassette layers (keep them separate — §15c)

- **(ii) `%Command{}`-sequence cassette** — geex-native, the spine. A recorded command
  list replayed through `Dispatch.replay/2`, **diffed against a recorded golden state**
  (a *pair* — never against a state the same replay regenerated). Deterministic, free,
  no key, no model. **Available now**; it is the v0.1 exit criterion. See
  [`test/geex/cassette_test.exs`](../test/geex/cassette_test.exs) +
  [`test/fixtures/cassettes/`](../test/fixtures/cassettes/).
- **(i) LLM-response cassette** — records the model's `{prompt → response}` so
  Direction B replays with no API key. *Post-0.5, gated on the balance_beam decision.*

### Dogfooding — when it comes in

- **Now:** replay-as-regression (the (ii) cassette) exercises the real write path with
  no model. The `Session.snapshot/0` / `Buffer.get_text/1` read-only surface built this
  increment is exactly what headless assertion needs.
- **Next:** the real dogfood — a harness *connects* to the running geex over loopback
  Streamable HTTP (`geex --serve`) and edits land in the live session, so **dogfood ==
  production** ([adr/0018](adr/0018-mcp-transport-streamable-http.md)). Needs the
  transport-agnostic protocol core (`Protocol.handle_line/1` + `tools/list` +
  `tools/call`) then the HTTP transport; stdio is the hermetic CI harness, not the
  dogfood (§15b). The `Session.snapshot/0` / `Buffer.get_text/1` surface built earlier is
  what headless assertion needs.
- **Post-0.5 milestone (not a gate):** "geex editing geex."

---

## Verification log

> Each entry: what shipped, the automated suite state, what was driven **by hand** and
> the **observed** result, honest gaps, and the commit it was blessed at. Append only.

### 2026-06-04 — Wire the command system into the running app (ADR-0014)

**Scope.** Widened the dispatch "world" from a bare `Doc` to `Geex.EditorState`; gave
`Geex.Buffer` ownership of the `EditorState` + the one undo history; added the public
`Geex.Dispatch.run/1` (resolve active buffer → gather → apply → scatter → record); added
the read-only `Session.snapshot/0` / `Buffer.{snapshot,get_text,history}` surface; wired
`Geex.CommandRegistry` (seeded with `Insert`/`Delete`) into the supervision tree.

**Automated.** `mix test` → **8 doctests, 102 tests, 0 failures** (was 83+8).
`mix compile --warnings-as-errors` clean. New tests: `editor_state_test`, `buffer_test`,
`session_test`, `supervision_test`, `cassette_test`; `dispatch_test` rewritten to the
`EditorState` shape. The §15c-ii golden-pair cassette replays and is asserted against an
independently-authored golden (`["world"]`), not a replay-regenerated state.

**Manual verification** — driven against the live OTP app, terminal off
(`MIX_ENV=test mix run`), exercising the whole spine end-to-end through the real
supervision tree. Observed:

| Step | Observed |
|---|---|
| `CommandRegistry.all/0` (in-tree) | `:delete`, `:insert` present; `lookup(:insert) → {:ok, Geex.Commands.Insert}` |
| Open buffer + `Session.set_active_buffer/1` | `Session.active_buffer/0 → {:ok, #PID<…>}` |
| Human edit via `Dispatch.run/1` | text → `"hello"` |
| **LLM edit via the SAME path** | text → `"hello world"` |
| `Session.snapshot/0` | `text: "hello world"`, `cursor: {0, 0}` (view-local), `version: 2`, history actors `[:human, {:llm, "claude-opus-4-8"}]` |
| Out-of-range edit | `{:error, :row_out_of_range}`; state unchanged `{"hello world", 2}`, **not recorded** |
| `Dispatch.replay/2` (frozen `at`) | text → `"world"`; replaying twice is `==` (deterministic) |

**Good as of:** the commit carrying this entry (2026-06-04). The one-path / one-history
invariant holds for edits across human + LLM origins, with honest provenance, and the
replay property is proven before any AI code exists.

**Not tested / deferred (honest gaps):**

- **Cursor-relative resolution at dispatch** (the *gather-the-cursor* step of Fork-1=A):
  the architecture is in place (cursor is view-local on `Geex.View`, out of
  `EditorState`/history, surfaced read-only by `snapshot/0`), but there is **no
  cursor-relative command yet** to resolve, so no resolve step was built. Deferred to the
  first real consumer (interactive TUI typing), per the named-consumer rule
  ([vision.md](vision.md) §3) — building it now would be speculative.
- **Clipboard subsystem** (`Geex.Clipboard`, copy/cut/paste) — ADR-0015, not yet started.
- **Buffer load/save** — `Buffer` holds text in memory; no file I/O round-trip yet.
- **Property tests + Dialyzer** — arrive with the MCP projection (v0.2, §15a-2).
- **MCP headless slice** — the §15b dogfood loop is unlocked but not yet built.

### 2026-06-04 — MCP tool-schema renderer (`Geex.MCP.Schema`, ADR-0018 step 1)

**Scope.** First `Geex.MCP.*` module: project the neutral field-spec
([Field](../lib/geex/command/field.ex)) → MCP tool descriptors (the `tools/list` payload)
— the §3a/§4 "free projection." Pure and **dependency-free** (Elixir 1.19's built-in
`JSON`); the first dep (Bandit/Plug) doesn't arrive until the HTTP transport.

**Automated.** `mix test` → **112 tests, 8 doctests, 0 failures** (was 102+8).
`warnings-as-errors` clean. New: [schema_test.exs](../test/geex/mcp/schema_test.exs) — real
`Insert`/`Delete` plus synthetic field-specs for the edge cases (no-description omitted,
empty-string description omitted, defaulted arg not required, declaration-order `required`,
**unknown arg type raises** so Type↔Schema drift surfaces, and a JSON round-trip proving
the schema is wire-stable).

**Manual verification** — rendered the `tools/list` payload from the live
`CommandRegistry`, encoded with built-in `JSON`. Observed:

- `insert` → `required: [line, col, text]`; `text:string`, `line`/`col:integer`.
- `delete` → `required: [line, col]` (`count` defaulted ⇒ optional); `count:integer`.
- every `inputSchema` is `type:"object"`, `additionalProperties:false`, and round-trips
  through `JSON.encode!/decode!`.

**Good as of:** the commit carrying this entry. Adding a command now auto-exports its MCP
tool schema with no hand-sync — the ADR-0004 promise, realized.

**Not tested / deferred:** the JSON-RPC envelope (`Protocol.handle_line/1`), `tools/call`
wiring (name → `parse/1` → provenance → `Dispatch.run/1`), and the loopback HTTP transport
are the next steps; only `:string`/`:integer`/`:boolean` are mapped (richer editor types
raise loudly until a row is added).

### 2026-06-04 — MCP protocol core (`Geex.MCP.Protocol`, ADR-0018 step 1) + adversarial review

**Scope.** The pure JSON-RPC/MCP core: `handle_line/1` (the three outcomes), method
routing (`initialize` with version negotiation, `tools/list` via `Schema`, `tools/call`,
`ping`, the two notifications), and `tools/call` wiring (name → `parse/1` → `Meta.llm`
provenance → `Dispatch.run/1`). Still **dependency-free** (built-in `JSON`).

**Adversarial review.** A 3-agent workflow checked the implementation against the live MCP
(2025-11-25) + JSON-RPC 2.0 specs. It **confirmed correct**: version negotiation, the
`initialize`/`tools/list`/`tools/call` result shapes, error-code usage, `ping`,
notification handling, parse/non-object/`-32600` classification, present-null-id =
request, and the `isError` mechanism. It caught **two real, empirically-reproduced crash
paths**, both now fixed:

1. `handle_line/1` could **exit uncaught** when a dependency GenServer
   (CommandRegistry/Session/Buffer) was down → now contained at the protocol boundary as
   `-32603` (filling the §11 internal-error gap the code never produced).
2. A command whose `run/2` **raises** crashed the shared `Geex.Buffer` → now contained in
   `Dispatch.apply_command/2` as `{:error, {:command_crashed, _}}`; the buffer stays
   alive, state/history untouched, and the tool-call returns `isError: true`.

Also applied (review "should-fix"): bumped the preferred protocol version to **2025-11-25**
(2025-06-18 still supported); per **SEP-1303**, a found tool's invalid arguments now return
an `isError` result (model self-corrects) rather than `-32602` (reserved for unknown
tool / malformed call). Reconciled the docs (§11 currency, §11/§13 `listChanged` —
advertise only when emitted; v0.5 ships bare `{tools: {}}`).

**Automated.** `mix test` → **134 tests, 8 doctests, 0 failures** (was 112+8).
`warnings-as-errors` clean. New: [protocol_test.exs](../test/geex/mcp/protocol_test.exs)
(envelope, id-echo, negotiation incl. back-compat, `tools/list`, `tools/call` incl.
SEP-1303 `isError`, **dead-buffer → -32603**, one-parser round-trip) + crash-containment
tests in `dispatch_test`/`buffer_test`.

**Manual verification** — drove a full session through `handle_line/1` against a live
buffer: `initialize` (negotiated 2025-11-25, advertised `tools: {}`) → `notifications/
initialized` (no reply) → `tools/list` (projected schema) → two `tools/call` inserts
(`hello` → `hello world`, `isError: false`); `Session.snapshot/0` showed the live edits
with history actors `[{:llm,"unknown"}, {:llm,"unknown"}]`.

**Good as of:** the commit carrying this entry. An LLM can drive the full MCP protocol
(list + call) into the live shared undo history with provenance — over an in-memory call;
the **loopback HTTP transport** (Bandit/Plug, first dep) is the next step and makes it a
real connection.

**Not tested / deferred:** the HTTP transport; connection-aware provenance (real `model`
from `clientInfo` + `turn_id`, threaded by the session layer — today `{:llm,"unknown"}`);
`error.data`; `tools/list` pagination; the `listChanged` emission path (§13).
