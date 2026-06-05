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

### 2026-06-04 — Loopback MCP HTTP transport (`Geex.MCP.HTTP`, ADR-0018 step 2) + adversarial review

**Scope.** The **Mode 2** transport: a harness *connects* to the running geex over MCP
Streamable HTTP (loopback), so edits land in the live session — dogfood == production.
`Geex.MCP.HTTP` (a `Plug.Router`) adapts `POST /mcp` → `Protocol.handle_line/1`; a Bandit
child bound to `127.0.0.1` is feature-gated in `Geex.Application` (`start_http_mcp`, default
off). **geex's first dependency** (Bandit/Plug — "rent the transport"); JSON stays built-in.

**Adversarial review.** A 3-agent workflow checked it against the live MCP Streamable HTTP
spec + an HTTP security threat model. It **independently re-verified there is no Origin
bypass** (the primary ask) and confirmed the status-code mapping, the `127.0.0.1` bind, and
the body cap. Findings applied:

- **MUST (spec):** validate the `MCP-Protocol-Version` header — present-but-unsupported →
  **400** (2025-11-25 requires it); absent is allowed. Supported list now exposed via
  `Protocol.supported_versions/0` (one source of truth for negotiation + the header check).
- **Should-fix:** Origin host comparison is now **case-insensitive** (`http://LOCALHOST`
  was wrongly rejected); a parse error (`:protocol_error`, no client id) now maps to **400**
  (input the server can't accept) while a well-formed request whose *result* is a JSON-RPC
  error still rides 200; non-POST methods on `/mcp` (GET/DELETE/…) → **405** (was 404).

I also caught and fixed, while writing the live smoke, an **Origin prefix-match bypass**
(`http://localhost.evil.com` would have passed) → exact-host via `URI.parse`.

**Automated.** `mix test` → **152 tests, 8 doctests, 0 failures** (was 134+8).
`warnings-as-errors` clean. New: [http_test.exs](../test/geex/mcp/http_test.exs) — outcome
mapping (200/202/400), `initialize`, body-cap 413, Origin (loopback incl. uppercase, evil,
look-alike-bypass, empty/null/absent asymmetry), the protocol-version header (400/200/absent),
GET/DELETE → 405, 404, and a `tools/call` editing the live buffer.

**Manual verification** — a real Bandit listener on `127.0.0.1:4599` driven over the socket
with a raw `gen_tcp` HTTP/1.1 client: `initialize` → `200` (negotiated 2025-11-25) →
`notifications/initialized` → `202` → `tools/call insert` → `200` (`"hello over http"`,
`isError:false`) → `GET` → `405` → `Origin: https://evil.example.com` → `403`; the live
buffer ended `"hello over http"`. *(`:httpc` hit an OTP `:http_util` quirk; `gen_tcp`
proved the wire directly.)*

**Good as of:** the commit carrying this entry. **A real harness can now connect to a
running geex over loopback HTTP and edit the live shared buffer with provenance** — the
dogfood == production path. The enforced-sandbox rung uses this same connect transport.

**Not tested / deferred:** `geex --serve` CLI ergonomics (today: config `start_http_mcp:
true`); sessions + connection-aware provenance (real model/turn — still `{:llm,"unknown"}`);
IPv6 (`::1`) binding (listener is IPv4-only; `::1` Origin allowed for forward-compat);
remote HTTP / WS / TLS / auth (post-0.5). And the **write-tool surface** (only Insert/Delete
today) must grow to create/edit/delete/rename before a harness's built-in writers can be
denied (ADR-0016 coverage gate).

### 2026-06-04 — Range edit primitive: `replace` (write-tool coverage, coordinate vocab)

**Scope.** The general coordinate/range edit (decided vocabulary: coordinate primitives
first). `Geex.Buffer.Doc.replace/3` replaces a grapheme-indexed `{{r1,c1},{r2,c2}}` range
with text (empty or multi-line); `Geex.Commands.Replace` exposes it as a command/MCP tool.
It **subsumes** multi-line delete (`text: ""`), point insert (empty range), and in-place
edit — so the buffer-level write vocabulary is essentially complete for contiguous edits
(the [ADR-0016](adr/0016-external-harness-integration.md) coverage gate, buffer half).
Registered in the supervision tree alongside Insert/Delete. Still in-memory (file
lifecycle + reconcile is the deliberate next increment).

**Automated.** `mix test` → **163 tests, 8 doctests, 0 failures** (was 152+8).
`warnings-as-errors` clean. New: exhaustive `Doc.replace/3` cases in
[doc_test.exs](../test/geex/buffer/doc_test.exs) (single-line, empty-range insert,
empty-text multi-line delete, multi-line→multi-line, collapse-to-one-line, whole-line,
grapheme-aware, **reversed-range → error**, out-of-range row/col), a `Replace`-through-the-
dispatcher test in `buffer_test`, a `tools/call replace` test in `protocol_test`, and the
`tools/list`/registry assertions updated to include `replace`.

**Manual verification** — over `handle_line/1` against a live buffer: `tools/list` →
`["delete","insert","replace"]`; `tools/call insert "hello world"` then `tools/call replace`
range `{0,0}`–`{0,5}` with `"goodbye"` → buffer `"goodbye world"` (`isError:false`).

**Good as of:** the commit carrying this entry. An LLM can now insert, delete, and replace
ranges in the live buffer over MCP. Buffer-level edit coverage is essentially complete.

**Not tested / deferred:** named line-ops (sugar over `replace`, add if ergonomics warrant);
a diff / search-replace tool (the harness-ergonomic layer that compiles to coordinate
commands — reference: the user's DeepSeek-Moby diff work + hex diff libs); file lifecycle
(open/create/save/rename + multi-buffer + path addressing), which pairs with reconcile.

### 2026-06-04 — File lifecycle slice 2: multi-buffer + MCP operation tools

**Scope.** The third MCP tool category (ADR-0019): hand-written **operation tools**
(`open_file`/`save_file`) that act on `Session`/disk and are **not** recorded as edits.
`Geex.Session.open_file/1` is a race-free find-or-start (serialized in the Session
GenServer; `Path.expand`-normalized; reused without clobbering unsaved edits), buffers now
register by path in `Geex.Registry` (`Geex.BufferSupervisor` + `whereis/1`), and
`Geex.MCP.Protocol` routes `tools/call` by category (operation → `Geex.MCP.Operations`,
else the edit registry) and merges both into `tools/list`. Operation tools project
`inputSchema` through the same `Geex.MCP.Schema` and validate args through the shared
`Geex.Command.cast_args/2` — no drift. A real harness can now **open, edit, and save real
files on disk** over loopback — the precondition for "geex editing geex".

**Hardened by an adversarial review workflow** (4 dimension finders → per-finding
adversarial verification; 17 confirmed). Fixed before commit: ① `Geex.Buffer` is now a
`:temporary` child — a crash no longer silently resurrects it from disk (which would drop
unsaved edits); ② `Buffer.init` uses non-bang `File.read` → an unreadable file fails the
start cleanly as `{:error, {:load_error, posix}}` instead of leaking a `%File.Error{}`+
stacktrace into the model's tool result; ③ `Buffer.save/1` returns `{:ok, path}` so
`save_file` needs one call (no save-succeeded-but-reported-as-`-32603` window, no gratuitous
snapshot); ④ an explicit `"arguments": null` coalesces to empty args (was a hard `-32602`);
⑤ `BufferSupervisor` caps open buffers (`max_children: 1024`) so a runaway open-loop fails
cleanly. Out-of-scope findings (active-buffer monitoring, symlink confinement, plugin name
collisions) were left as documented notes — they belong to concurrent-client / sandbox /
plugin work, not this loopback slice.

**Automated.** `mix test` → **195 tests, 8 doctests, 0 failures** (was 163+8).
`warnings-as-errors` clean. New: [operations_test.exs](../test/geex/mcp/operations_test.exs)
(descriptors, lookup, `{:ok}`/`{:error}`/`{:invalid_args}` shapes, name-disjointness guard),
operation-tool coverage in [protocol_test.exs](../test/geex/mcp/protocol_test.exs) (the full
open→edit→save loop, history-invariant assertion, `args: null`, no-path/no-active-buffer
isError, reuse-without-clobber), `open_file` cases in
[session_test.exs](../test/geex/session_test.exs) (find-or-start, reuse, path normalization,
registry registration), and an unreadable-file clean-error case in
[buffer_io_test.exs](../test/geex/buffer_io_test.exs).

**Manual verification** — a live OTP tree (`Registry` + `CommandRegistry` + `BufferSupervisor`
+ `Session`) driven through `Geex.MCP.Protocol.handle_line/1`: `tools/list` →
`["delete","insert","open_file","replace","save_file"]`; `open_file` a 2-line file → returned
its text (`isError:false`); `insert` → `"hello there\nworld\n"`; `save_file` → `"saved
/tmp/…"` and the bytes landed on disk; `Session.snapshot` showed `history_len: 1` (open +
save recorded **nothing** — the ADR-0019 invariant, live); `save_file` with `"arguments":
null` → succeeded (no `-32602`).

**Good as of:** the commit carrying this entry. A harness can open/edit/save real files on
disk over loopback MCP, every edit a provenance-tagged `%Command{}` in the one undo history,
operations deliberately outside it.

**Not tested / deferred:** `close_file` (no buffer eviction yet — the `max_children` cap is
the interim guard); reconcile (out-of-band disk writes → `:external`, the `:file_system`
watcher — the deliberate next increment, ADR-0017); the diff / search-replace `edit` tool
(ADR-0020); active-buffer death monitoring + Session self-heal (surfaced as `-32603` today,
self-heals on re-open); symlink/hard-link path aliasing (dedup is by lexical path);
concurrent multi-file editing (per-edit targets).
