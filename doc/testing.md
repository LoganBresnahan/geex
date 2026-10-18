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

### 2026-06-05 — Reconcile: file-watch + `:external` provenance (Rung 0, the honest floor)

**Scope.** `Geex.Reconcile` (ADR-0017): when something writes an open buffer's backing
file behind geex's back, geex diffs disk against its `EditorState` and replays the change
as a provenance-tagged `%Command{}` — "the file-watcher is just another transport producing
commands". Two layers like `Geex.MCP.Protocol`: a directly-testable **core**
(`reconcile/2` — content-comparison echo-suppression → synthesize one `:external`
whole-buffer `replace` → `Buffer.dispatch` into the changed buffer's history → `mark_synced`)
and a **watcher GenServer** (`:file_system` per-directory; resolves buffers by path via
`Geex.Registry`; degrades to a logged no-op when `inotify-tools` is absent). `:external` is
never fabricated as `{:llm,_}`/`:human`; surfaced-never-silent = `Logger` + the `:external`
command in queryable history; geex-as-observer (disk is truth) is the default, and even an
overwrite of unsaved edits is one **undoable** `:external` command. **geex's ~3rd dependency:
`:file_system`** (Bandit/Plug were 1st/2nd; JSON + diffing stay built-in).

**Hardened by an adversarial review workflow** (4 dimension finders → per-finding
verification; 13 confirmed). Fixed before commit: ① the `:file_system` worker survives a
*normal* backend exit and forwards `:stop` without an `{:EXIT,…}` — the old code dropped
`:stop`, leaving a directory permanently "watched" by a zombie worker (silently never
reconciling again); now `:stop` *and* a trapped `:EXIT` both free the directory for
re-watching. ② `reconcile/2`'s bare `GenServer.call`s could let a target buffer's death
crash the reconciler and cascade-kill every linked watcher → now contained as `{:error,
{:buffer_down, _}}`. ③ reconcile left the buffer `dirty: true` though memory now equals disk
→ added `Buffer.mark_synced/1`, called after a reconcile (geex-as-observer post-condition).
④ ADR-0017's "runs through `Dispatch.run/1`" was inaccurate (run/1 only hits the active
buffer) — amended to `Buffer.dispatch/2` targeting the changed buffer. Verifier-refuted /
out-of-scope findings left as notes: close-event filtering/debounce for mid-write partials
(the proposed `:closed` filter was *wrong* — the backend maps CLOSE_WRITE→`:modified`; needs
a timer, deferred), `@max_watched_dirs` (transitively bounded by `@max_buffers`), symlink
canonicalization (doesn't fire on the Linux/inotify backend).

**Automated.** `mix test` → **212 tests, 8 doctests, 0 failures** (was 195+8).
`warnings-as-errors` clean. New: [reconcile_test.exs](../test/geex/reconcile_test.exs) — the
core (echo-suppression; `:external` synthesis; empty↔content; unicode; non-active-target;
dirty cleared; dead-buffer containment), the watcher glue via injected `:file_event` (changed
file reconciles; equal disk = echo ignored; no-open-buffer no-op; deleted file not reconciled
to empty; `:stop`/unknown ignored), watcher cleanup (`:stop`/`:EXIT` free the dir; unknown
watcher no-op), and `watch/2` lifecycle (no-op when gated off; graceful backend-missing
degradation).

**Manual verification** — a live OTP tree (`Registry`+`CommandRegistry`+`BufferSupervisor`+
`Session`+`Reconcile`): `Session.open_file` triggered `Reconcile.watch` (degraded cleanly —
no `inotify-tools` here — logged, no crash); an external write + the injected watch event
reconciled the buffer to the disk content with `history actors: [:external]`, `version: 1`,
**`dirty: false`**; a second geex save + watch event added no new `:external` (echo
suppressed); and `reconcile/2` on a killed buffer returned `{:error, {:buffer_down, :noproc}}`
with the reconciler still alive.

**Good as of:** the commit carrying this entry. Out-of-band disk writes to an open buffer are
now reconciled into the one undo history as honest `:external` commands — the always-on Rung 0
floor under every enforcement rung (ADR-0016) is real.

**Not tested / deferred:** the real `inotify`/`fsevents` event *source* (the library's job;
`inotify-tools` is absent in this env, so the watcher was exercised via injected events and
the live backend smoke awaits a provisioned host); debounce / close-event coalescing for
non-atomic mid-write reads; deletion + conflict ("reload?") merge UX (geex-as-primary); finer
line-level reconcile diffs (pair with the ADR-0020 `edit` tool); a UI consumer for the
surfaced divergence event.

### 2026-06-05 — The `edit` (search/replace) tool — harness-ergonomic editing on the spine

**Scope.** `Geex.Commands.Edit` + the pure `Geex.Edit.Resolve` (ADR-0020): an LLM edits by
quoting old text and giving new text (the way it's trained), and geex compiles that to the
coordinate `Doc.replace` primitive. Two deterministic tiers **apply** — exact-unique
substring (grapheme-correct: positions via string-prefix splitting, no byte math) and a
whitespace-normalized line window with re-indentation — both **unique-or-refuse**. No fuzzy
*apply* beyond that: a line-presence classifier only shapes the refusal (`:stale` re-read /
`:ambiguous` add-context / `:not_found` quote-exact), which is **stricter than Moby** and
deletes the exact path that caused Moby's silent-duplication scar. `Edit` is **one atomic
command**: `run/2` applies blocks sequentially (each re-resolved against the post-edit doc),
and `Buffer`'s untouched-on-`{:error}` semantics give all-or-nothing rollback for free. One
new arg type `:edits` (the first non-scalar) in `Type.cast` + `Schema.json_type`; Protocol
surfaces the self-correction message. **No new dependency** (built-ins only).

**Two deliberate refinements of ADR-0020** (now amended into the ADR + research): the
matcher applies only the two deterministic tiers (the staleness/anchor reasoning informs the
*refusal*, never a fuzzy apply); and `Edit` is one atomic command applying via `Doc.replace`,
not N separately-dispatched `Replace` commands (the latter gave no atomicity).

**Hardened by an adversarial review workflow** (4 dimension finders → per-finding
verification; 17 confirmed). Fixed before commit: ① **self-overlapping-search miscount** —
`String.split` counts non-overlapping, so `"end\nend"` in `"end\nend\nend"` looked unique
and would have silently edited the first of two real (overlapping) matches; now counts
overlapping occurrences and refuses `:ambiguous` (the exact silent-wrong-location failure the
design exists to prevent). ② **CRLF→LF silent rewrite** — tier 2 trimmed `\r`, flipping a
CRLF buffer to LF on edited lines; now preserves the matched window's line endings.
③ **empty `edits: []`** ran as a no-op that dirtied the buffer + recorded a phantom history
entry; now rejected at the cast boundary (clean isError). ④ the ADR/research were stale
(described the abandoned N-Replace + applying-anchor design) — amended. Verifier-refuted /
cosmetic findings (additionalProperties strictness — a pre-existing house pattern;
non-string-description coercion; perf; message ergonomics) left as-is.

**Automated.** `mix test` → **251 tests, 8 doctests, 0 failures** (was 212+8).
`warnings-as-errors` clean. New: [resolve_test.exs](../test/geex/edit/resolve_test.exs) (the
tiers; self-overlap ambiguity; CRLF preservation; tab + over-indent-clamp reindent; refusal
classification; and a **seeded grapheme-correctness property** — 400 random UTF-8 cases
asserting `resolve + Doc.replace == naive String.replace`, the ADR's #1-risk mitigation made
real), [edit_test.exs](../test/geex/commands/edit_test.exs) (parse/cast; sequential apply;
multi-block drift-induced ambiguity; all-or-nothing rollback through the dispatcher; **replay
determinism** of a recorded `%Edit{}`), plus `:edits` cases in the Type and Schema tests and
edit-tool cases in the Protocol test. *(Three of my own test expectations were initially
wrong — tier-1 exact-substring is more surgical than I'd assumed; the implementation was
correct and I fixed the tests.)*

**Manual verification** — a live OTP tree driving `Geex.MCP.Protocol.handle_line/1`: an
`edit` quoting `"def bar, do: 1"` flush-left against a 2-space-indented buffer matched via
tier 2 and applied **re-indented** to `"  def bar, do: 2"` (`isError:false`); an unmatched
block returned `isError:true` with `"...no matching text found — quote the old text exactly
as it appears in the buffer. No edits were applied."`; `tools/list` exposed `edit` with the
array `inputSchema`.

**Good as of:** the commit carrying this entry. An LLM can now edit by quoting code — the way
it's trained to — while every mutation is still a provenance-tagged `%Command{}` in the one
undo history, applied atomically or refused with guidance, never silently mis-located.

**Not tested / deferred:** empty-search "prepend/create" (refused for now); a generated
(vs seeded-random) property harness (no stream_data dep); the anchor/order *applying* tier
(deliberately not built — refuse-and-re-quote is the safe default); a broader line-ending
contract in `Doc` (the edit tool preserves CRLF in tier 2, but `Doc` still treats `\r` as
content model-wide); an `%Edit{}` in the §15c golden cassette (covered by a dedicated replay
test instead).

### 2026-06-05 — File-operation tools (create/delete/rename/close_file) + reconcile baseline (ADR-0019, amends ADR-0017)

**Scope.** The four **operation tools** that complete the write surface (the ADR-0016
coverage gate, so a harness's built-in writers can be denied): `create_file` (pure disk
create — refuse if file *or* buffer exists), `delete_file` (rm + evict any open buffer),
`rename_file` (disk rename + re-key the open buffer), `close_file` (free a buffer, disk
untouched). Orchestration in the serialized `Geex.Session`; buffer re-keying + synchronous
`unregister` in `Geex.Buffer`; `terminate/1` in `Geex.BufferSupervisor`. Operations are
**not** recorded `%Command{}`s (ADR-0003/0019): they never enter a buffer's undo history.
Invariants enforced: **refuse-never-clobber** (create/rename refuse an existing target);
**never-silently-lose-work** (discarding a dirty buffer on close/delete is *reported*, never
silent); **Registry/buffer consistency** (an evict unregisters synchronously so a re-open
right after sees a clean registry, not the dying pid).

**The rename × reconcile interaction → the buffer-baseline model (an ADR-0017 amendment).** A
dirty `rename_file` is the operation whose post-op disk state can fool the always-on reconcile
floor (ADR-0017): `File.rename` moves the OLD bytes to the new path while the buffer holds
unsaved NEW text, so the destination's own file-watch event looked like an *external* change
and reconcile adopted OLD back over the edits (an undoable `:external` revert, but a surprising
one — and asymmetric with delete/create, which are deliberately reconcile-immune). We surveyed
what mature editors do (VS Code / Emacs / JetBrains all re-key the buffer, preserve the dirty
edits, and treat their *own* file ops as not-external) and landed on the **baseline** model:
every `Geex.Buffer` now tracks a **`synced` baseline** — the disk content it is in sync with
(set on load / `save/1` / `mark_synced/1`) — and `reconcile/2` compares disk against **that
baseline, not the live (dirty) text**. An event whose disk still equals the baseline is no
external change, so unsaved edits are never reverted; the re-keyed buffer carries its baseline
along, so a rename echo-suppresses **for free** with zero rename-specific code. This
*strengthens* the singular command pipeline (it removes a watcher-timing-dependent phantom
`:external` command from history, improving replay determinism) and **subsumes a latent bug**:
previously *any* dirty buffer could be reverted by a spurious event on an unchanged file (the
core compared disk to current text); now it cannot. The root insight — reconcile must compare
disk to a per-buffer *baseline*, the editor-standard model — is exactly how VS Code/Emacs/
JetBrains decide "did the file change underneath me?".

**Hardened by three adversarial review-workflow rounds** (multi-dimension finders →
per-finding independent verification). **Round 1** (the operation tools, 5 dimensions, 10
confirmed of 12): fixed ① **`drop_buffer` crash** — `Buffer.unregister` was an unguarded
`GenServer.call`, so a buffer dying mid-evict crashed the whole serialized Session (its
siblings `dirty?`/`buffer_status` already `catch :exit`; `evict/1` now does too); ②
**scratch-buffer leak** — `terminate/1` returns `{:error, :not_found}` for a non-child
(pathless) buffer, which was left *alive* while reported "closed (discarded unsaved edits)" —
a double lie; `evict/1` now stops it directly; ③ **`rekey_buffer` crash** — `Buffer.rename`
unguarded post-`File.rename`-commit (now `safe_rename/2`, degrading a buffer death to the
logged stale-path branch); ④ **never-saved rename** — a buffer opened on a not-yet-saved path
couldn't be renamed (`File.rename` → `:enoent`); now an in-memory re-key. **Round 2** (review
of the fixes, 8 confirmed of 10) found the *first* echo-suppression design (a one-shot
consumed on the first event) was itself buggy — a cross-directory rename whose dest dir isn't
watched at move time never delivers the move event, leaking a stale mask that could later
swallow a genuine write; a coalesced second event could still revert. **Redesigned to the
standing-until-divergence rule above**, which tolerates the move event arriving late, twice,
or never. **Round 3** (focused review of the redesign, 4 confirmed of 6): the standing rule
is *correct* (the one "high" finding was a docstring **over-claim**, not a code bug — the low
verifier confirmed no work is lost; suppression only fires when disk equals the moved bytes,
i.e. no external *change*, and preserves the unsaved edits); narrowed the over-stated
docstrings to be honest about the accepted save-granularity coarseness, and closed three test
gaps including a **mutation-verified** deterministic test for the `safe_rename` crash-guard (a
stand-in process that exits on the re-key call — removing the `catch` now reliably reddens it).

The three rounds converged the rename suppression on a *correct* but workaround-shaped
mechanism (a standing, content-keyed `expect_echo` mask in the reconcile transport). Round 3
made clear it was patching one symptom of a deeper issue — the reconcile core compared disk to
the buffer's **live text**, which is wrong for *any* dirty buffer — so **before commit we
replaced the entire echo-suppression with the buffer-baseline model** above. Net effect: −~40
lines of transport bookkeeping (`expect_echo`, the `expected` map, the rename-seed helpers),
+1 `Buffer` field and a one-line core comparison; late / duplicate / never-delivered events
become non-issues (the comparison is stateless); and the general dirty-buffer revert is fixed
too. Mutation-verified: reverting the core to compare current text instead of the baseline
reddens 4 tests (the dirty-buffer and rename-preservation cases).

**Automated.** `mix test` → **297 tests, 8 doctests, 0 failures** (was 284+8).
`warnings-as-errors` clean; deterministic across seeds. New coverage: a **dirty buffer is not
reverted** by an event for an unchanged file (`disk == synced` baseline) and **adopts** a
genuine divergent change — at the `reconcile/2` core *and* through the watcher glue; `save/1`
**moves the baseline** (the save echo is ignored, a later external change still caught) and an
adopt **re-baselines** (a re-delivered identical event is ignored) — both mutation-verified;
dirty-rename **not** reverted by the reconcile floor (injected `:moved_to`, repeated); a genuine
divergent post-rename write **is** adopted as `:external` (never-miss half); an event for the
unchanged backing file ignored even after further edits; the `safe_rename` crash-guard
(mutation-verified); the scratch-buffer close (honest, no leak); `close_file` on a *dead*
active buffer (clean result, no Session crash); never-saved-path rename.

**Manual verification** — a live OTP tree driving `Geex.MCP.Protocol.handle_line/1`:
`create_file` returned `isError:false "created …"` and refused a recreate with
`isError:true "already exists: … (use open_file to edit an existing file)"`; `open_file` then
an `insert` left the buffer dirty (`"X-hello\n"`); `rename_file` returned `isError:false` and
**`snapshot.text` stayed `"X-hello\n"`** (unsaved edits preserved) while disk held the moved
`"hello\n"`; `delete_file` reported `"deleted … (discarded unsaved edits)"` and cleared the
active pointer; a missing-file delete refused `:enoent`; a never-saved `open_file` + `close_file`
freed the buffer with the disk untouched.

**Good as of:** the commit carrying this entry. A harness can now create/delete/rename/close
files through geex with refuse-never-clobber + honest discard reporting, and a dirty buffer
(renamed or not) is never reverted by the reconcile floor — it compares disk to each buffer's
`synced` baseline, not its live text, so only a *genuine* change to the backing file is adopted.

**Not tested / deferred:** reconcile is exercised by **injected** `:file_event`s, not a live
`inotify` backend (`inotify-tools` is absent on this WSL box, so the watcher degrades to a
logged no-op there); a live end-to-end watcher test awaits a host with the backend. Coalescing
coarseness remains (a disk that flips away from and back to the baseline inside one coalesced
event reads as unchanged — the transient is lost, but disk equals the baseline so there is no
net change and the edits are preserved): the accepted ADR-0017 save-granularity behavior, not
refined here. The `synced` baseline is whole-file (not yet a line-level diff anchor — the
ADR-0020 myers work could refine the adopted `:external` command without touching the
comparison).

### 2026-06-05 — Per-harness presets + the live loopback dogfood (ADR-0016 Rung 1, ADR-0018)

The slice that closes v0.5's *transport* headline: a real external client connects to a
running geex over loopback **Streamable HTTP** (ADR-0018) and edits a real file through the
**one** command path, with provenance. Plus the checked-in **Rung 1 preset** (ADR-0016) that
points a harness at geex and denies its structured writers — shippable now that the write
surface meets the coverage gate (create/edit/delete/rename over MCP).

New surface: a **serve switch** — `config/runtime.exs` reads `GEEX_SERVE=1` to flip
`:start_http_mcp` on and `:start_terminal` off (a serving node runs headless), with the port
from `GEEX_MCP_PORT` (default `Geex.Application.default_http_mcp_port/0` = 4000); `mix geex.serve
[--port N]` is sugar that sets those then delegates to `mix run --no-halt`. The listener still
binds `127.0.0.1` only. The **Claude Code preset** (`presets/claude-code/`): `.mcp.json`
(`type: "http"`, `http://127.0.0.1:4000/mcp`) + `.claude/settings.json`
(`permissions.deny` = `Write`/`Edit`/`MultiEdit`/`NotebookEdit`). `presets/README.md` frames
the enforcement ladder — a preset is **advisory-by-cooperation, not enforcement**; shell/
subprocess writes are deliberately *not* denied (that is the Rung 1 subprocess-write gap, left
to Rung 0 reconcile's `:external` tagging, closed only by Rung 2 OS-sandbox).

**Manual verification — a live `mix geex.serve` on `127.0.0.1:4000`, driven by an external
`curl` process (a separate OS client speaking the real wire):** `initialize` →
`{protocolVersion 2025-11-25, serverInfo geex 0.1.0}`; `notifications/initialized` → HTTP 202;
`tools/list` → all ten tools (`insert`/`delete`/`replace`/`edit` + `open_file`/`save_file`/
`create_file`/`delete_file`/`rename_file`/`close_file`); `open_file` a real file → its text;
`insert` at `line 0 col 5` → the mutated text returned; `save_file` → `"saved …"` and the
**disk file changed** (`hello world` → `hello, geex world`, confirmed by `cat`). A second proof
drove an edit with `curl` and then read the buffer's live undo history in-process: **one
`Geex.Commands.Insert` with `meta.actor: {:llm, "unknown"}`** — the loopback-HTTP edit is a
provenance-tagged `%Command{}` in the one history. (`{:llm, "unknown"}` is the honest stateless
provenance: an MCP tool-call genuinely arrived through the LLM door; the *model* identity is
connection state the stateless `Geex.MCP.Protocol` core does not yet thread — a deliberate
follow-up.)

**Automated.** `mix test` → **302 tests, 8 doctests, 0 failures** (was 297+8).
`warnings-as-errors` clean; formatted. New coverage: `test/geex/presets_test.exs` pins the
preset invariants with teeth — the MCP endpoint is **loopback only** and on geex's
single-source default port (`Geex.Application.default_http_mcp_port/0`, not a bare literal); the
deny-list covers **all four** structured writers (incl. legacy `MultiEdit`, so it can't silently
drop); and it **does not** deny Bash (pinning the ADR-0016 "shell writes are Rung 0's job"
decision — a future `Bash(...)` deny reddens it) nor Read. The serve port parse is defended:
an empty `GEEX_MCP_PORT` falls back to the default, and a non-numeric / out-of-range value (env
*or* `--port`) fails the boot with a message **naming the variable**, not an opaque
`String.to_integer` / `:gen_tcp.listen` `:badarg` (smoke-checked).

**Hardened by an adversarial review** (4-dimension finders → independent per-finding
verification; 8 confirmed, 2 rejected). Fixed: the deny-list test omitted `MultiEdit` (the one
writer it forgot to pin — a drift hole); `MultiEdit` was presented as a *current* Claude Code
tool when it was folded into `Edit` in 2.0 (README now marks it legacy/back-compat); empty/bad
`GEEX_MCP_PORT` and out-of-range `--port` crashed boot opaquely (now validated + named); the
port test hardcoded `4000` instead of the serve default (now single-source); and — the honesty
fix — the README overclaimed Claude Code "verified end-to-end ✅", when `curl` proved the *wire*
but **not the named harness honoring the preset** (Status now reads "wire + tools + provenance +
save verified with an external client; a live claude-code-honoring-the-preset run still
pending"). Rejected: a "guard against copying the preset to geex's own root" (user-error, not a
defect — though the README now cautions against it) and a `{:llm,"unknown"}` provenance nit
(already honestly documented).

**Good as of:** the commit carrying this entry. `mix geex.serve` brings up a loopback MCP
endpoint; an external client connects, opens/edits/saves real files, and every edit is a
provenance-tagged `%Command{}` in the one undo history — dogfood == production for the transport.

**Not tested / deferred (honest scope of this dogfood):**
- **The named harness itself was not run.** The wire was exercised with `curl`/an external HTTP
  client, which genuinely proves the loopback Streamable-HTTP transport, the tool surface,
  provenance, and save. It does **not** prove that *claude-code* — honoring the checked-in
  `.mcp.json` + deny-list — routes an edit through geex. That live preset-honoring run is the
  open item before the Claude Code preset can be called "verified end-to-end."
- **The reconcile / `:external` clause of the v0.5 criteria was not demonstrated live here.**
  The watcher degrades to a logged no-op on this WSL box (`inotify-tools` absent), so an
  out-of-band write was not auto-reconciled end-to-end; the reconcile **core** is unit-tested
  (the 2026-06-05 file-ops entry above) and a live backend awaits a provisioned host.
- **"Sessions replay" is carried by the §15c cassette, not this dogfood.** Deterministic replay
  is proven by `Geex.Dispatch.replay/2` + the golden-pair cassette test (a pure command-list
  replay over an `EditorState`); there is no `Geex.Session`-level replay entry point yet, and no
  replay step ran in this transcript. This slice closes the *connect + edit + provenance + save*
  clauses; replay stands on the earlier, separate proof.
- **Other first-class presets** (Codex, Gemini, Continue, Roo, OpenCode) are not checked in —
  the same two pieces in each harness's own config dialect, added as named consumers appear
  (presets are ongoing, version-sensitive maintenance — ADR-0016).

### 2026-06-07 — Syntax highlighting: tree-sitter-on-wasm engine + Birds of Paradise theme (ADR-0021/0023)

geex's first **host-in** capability. A net-new BEAM package, `tree_sitter_wasm` (sibling repo,
path dep), is the ARCH-1 highlighter: a Rustler NIF (tree-sitter 0.26.9 `wasm` feature → embedded
wasmtime) that loads a **portable grammar `.wasm`** (`tree-sitter build --wasm`, wasi-sdk) via
`WasmStore::load_language` and returns capture spans `{byte_start, byte_end, capture}`. Wired into
geex behind `Geex.Highlight` (the contract), with bundled json + elixir grammars; rendered by a
capture→`Style`→truecolor-ANSI pipeline (`Geex.Theme`/`Geex.Color`/`Geex.Ansi`) and the **Birds of
Paradise** theme (the author's Zed port, the template others follow).

**Verified:** package suite **8 tests** (load, capture contract, cache reuse, large-input/0 ms
**`:timeout`**, the **parser-reset regression**, malformed-bytes/bad-query error tuples); geex suite
**322 tests + 8 doctests** green, `highlight_test` deterministic across 3 seeds. `mix geex.highlight`
renders the elixir sample live in 24-bit truecolor — keyword-red, string-yellow-italic, an
**escape-purple nested inside the string**, number/atom-blue, comment-brown-italic — Birds of
Paradise faithfully in the terminal. Hardened: the compiled grammar (parser+store+query) is cached
in a `ResourceArc` behind a `Mutex`; the parse is bounded by a wall-clock deadline; a cancelled parse
**resets** the cached parser (the bug the determinism run caught). An adversarial-review workflow
(4 lenses, 12 agents, findings verified) confirmed **no critical/concurrency defects**; two real fixes
landed — `Application.app_dir/2` now returns a tagged `{:app_not_loaded, :geex}` instead of raising,
and `mix geex.highlight` `Mix.raise`s cleanly on an unreadable file (was `File.read!`).

**Good as of:** the commit carrying this entry. `mix geex.highlight lib/geex/ansi.ex` (or any
`.ex`/`.json`, or no arg) prints truecolor-highlighted source; `Geex.Highlight.spans/3` is the
synchronous seam the reactor will call.

**Not tested / deferred (honest scope):**
- **The reactor is NOT built** ([ADR-0022](adr/0022-capability-reactor.md)) — *when* highlighting
  fires (async, debounced, viewport-first off the command stream) is its own later slice;
  `spans/3` is synchronous and runs nothing on its own.
- **Not wired to the live display.** `Geex.Ansi` renders a styled *string*; teaching
  `Geex.Renderer` to emit SGR per `Geex.Cell` (so a buffer paints on the `Screen` grid) is the
  connected follow-up — the colour/attr vocabulary already matches `Geex.Cell`.
- **Only json + elixir grammars are bundled;** user/config-path grammars + the theme importers
  (Zed/Helix near-lossless, VS Code lossy) land with the user-config layer ([ADR-0023](adr/0023-theming-and-extension-loading.md)).
- **`tree_sitter_wasm` is unpublished** (local path dep) and ships **no precompiled NIF**
  (`rustler_precompiled`) yet; its `Highlighter`-convenience-wrapper wasm support is untested
  (the NIF uses `Query`/`QueryCursor` directly), and incremental reparse (persistent `Tree`) is a
  noted follow-up.

### 2026-06-07 — The highlight reactor + display wiring (ADR-0022)

Highlighting now **fires off the command stream** and **paints the screen grid**, closing the two
items the previous entry deferred. Two slices + a review pass.

**Reactor.** `Geex.Buffer` gained a post-dispatch change emit (`subscribe/2` + a monitored-subscriber
set; `{:geex_buffer_change, buffer, version}` after each successful dispatch — a plain `send`, never
blocking). `Geex.Highlight.Reactor` is one `:temporary` process per buffer: it subscribes, and turns
each change into an **async, coalesced, latest-wins** whole-buffer pass run in a throwaway task
(`<=1` in flight; a burst collapses to one re-highlight of the newest text), keeping the spans as a
**view-local overlay** (`highlights/1`) — never through `Dispatch`, never in history. It monitors its
buffer and follows its life (crash isolation). Started from `Session.open_file` via `watch/2`, gated
`:start_highlight` (off under `mix test`, like reconcile).

**Display.** `Geex.Sgr` encodes any `Geex.Cell` colour (`:default`/`{:ansi}`/`{:xterm}`/`{:rgb}`) to
SGR. `Geex.Highlight.Paint.to_screen/6` projects text + spans + theme onto a `Geex.Screen` (grapheme
walk tracks the byte offset for multibyte; `scroll` picks the first visible line). `Geex.Renderer`
now emits SGR — one cursor-move + escape + chars + reset per same-style run; a **plain run emits no
SGR**, so all prior renderer output is byte-identical. `Geex.Ansi` was refactored onto the shared
`Paint` + `Sgr` with identical public behaviour.

**Verified:** **339 tests + 8 doctests** green; the reactor + paint suites deterministic across 3
seeds. Reactor tests cover the initial pass, **fires-on-edit** (a dispatched insert re-highlights),
**latest-wins coalescing** (a burst converges to the newest version), buffer-death cleanup, and the
race-free `stop`/`rewatch`. Display tests cover SGR runs/splits/plain-unchanged, projection
(styled/unstyled/scroll/multibyte/CRLF), and **end-to-end** (`Highlight.spans` → `to_screen` →
`Renderer.diff` → truecolor bytes). A 3-lens adversarial-review workflow (concurrency / render /
lifecycle) found **no critical defects**; four real fixes landed: CRLF-as-one-grapheme in the
projection, mid-grapheme style lookup, a stale reactor grammar after a rename (added
`Reactor.rewatch/2` + synchronous-unregister `stop/1`), and a too-broad buffer `:DOWN` clause.

**Good as of:** the commit carrying this entry. In dev, opening a `.ex`/`.json` file starts a reactor
that re-highlights on every edit; `Geex.Highlight.Paint.to_screen/6` + `Geex.Renderer` render it in
truecolor.

**Not tested / deferred (honest scope):**
- **No live editor loop yet** — nothing currently *calls* `to_screen` against an open buffer's
  overlay each frame; the projection + reactor are proven by tests and the `Renderer.diff` path, not
  by an interactive TUI (that is the minibuffer/TUI thread). So a human has not yet *watched* a
  buffer recolour as they type; the wiring underneath it is in and tested.
- **Whole-buffer** highlight + projection — **viewport-first** (reactor) and viewport-scoped
  projection are the paired ADR-0022 tuning refinements, along with a **debounce** interval (today
  coalescing is purely in-flight-gated).
- **`rename` to a different language is re-evaluated, but only when `:start_highlight` is on;** under
  `mix test` the rewatch stops the stale reactor and does not restart (gate off), as the test asserts.

### 2026-06-08 — Dynamic MCP port + themes-as-data (ADR-0018 / ADR-0023 / ADR-0024)

Three threads from a design discussion, built overnight.

**Dynamic MCP port (ADR-0018).** geex stops hardcoding 4000 — it asks the **host** for a free port
(like pharos's `port = 0`). `Geex.MCP.Port.resolve/1` (`0` → a free loopback port via bind-0/read/
close; `N` → `N`), `announce/1` (log `geex MCP: serving <url>` + write `GEEX_MCP_PORT_FILE` when set,
for headless discovery). `Geex.Application` resolves the requested port (default `0`) and orders a
run-once announcer Task **after** Bandit, so a bind failure leaves no stale port file. `mix geex.serve`
/ `GEEX_SERVE` default to auto; `--port N`/`GEEX_MCP_PORT=N` pin; the checked-in presets stay the
pinned-4000 example. **Verified:** 6 `Geex.MCP.Port` tests + **smoke-verified end-to-end twice** —
`mix geex.serve --port 0` bound `:43760`/`:45854`, announced + wrote the port file, and a real MCP
`initialize` round-tripped. The announcer-after-Bandit ordering came from the adversarial review (a
stale-port-file-on-bind-failure finding).

**Themes are data (ADR-0023).** BoP shipped as a hardcoded Elixir module — a violation of ADR-0023
§1 ("themes are data, never code"). Now: a **native JSON theme format** keyed on tree-sitter captures
(bare hex = fg; object adds bg + attrs); `Geex.Theme.load/1`/`from_json/1` (validating, **never raises
on a bad file** — tagged `{:read,_}`/`{:bad_json,_}`/`{:missing,_}`/`{:bad_color,_,_}`), `bundled/1` +
`default/0`; `Geex.Color.parse/2` the safe parser. `priv/themes/birds-of-paradise.json` is the bundled
default **and** the reference. `Geex.Theme.Import.Zed` reshapes a Zed theme onto the native map + reuses
the loader (near-lossless — Zed keys on captures). **Verified:** 16 tests incl. validate/malformed/
missing-field paths and importing the **frozen real Zed BoP fixture**, asserting it matches the native
port for shared captures; the data-file `default()` reproduces the old hardcoded theme exactly (all
prior theme/paint assertions unchanged). Full suite: **357 tests + 8 doctests**.

**TUI extraction + dogfooding ([ADR-0024](adr/0024-tui-core-extractable.md)).** Decision recorded, not
code: the NIF-free `:prim_tty` TUI core is an extractable package candidate but stays in geex until
mature (wcwidth/mouse) + a second consumer; and the **live visual dogfood is gated on the interactive
TUI loop** (not built) — the wiring underneath is tested, the loop is the next visible milestone.

**Not tested / deferred:** config-path **user themes** (the install story — declare a path in config)
land with the user-config layer, now specified in [ADR-0025](adr/0025-user-config-layer.md); the
loader/format here is what they'll use. The dynamic port is
resolved up front (small pre-bind window) rather than read back from Bandit (pharos's `after_start`) —
acceptable on loopback; a Bandit read-back is the zero-window follow-up.

### 2026-06-08 — Display width (wcwidth) + the user-config ADR (ADR-0024 / ADR-0025)

**Display width — `Geex.Width` (ADR-0024 toolkit gap #1).** The render path assumed *one grapheme =
one column*; a single double-width glyph (`字`, wide emoji) desynced every cell after it on the line.
Now `Geex.Width.cells/1 → 0 | 1 | 2`, backed by OTP's pure-Erlang `:unicode_util.is_wide/1` +
`lookup/1` (the same oracle `:prim_tty` falls back to) — **NIF-free**, so the extractable TUI core
stays clean. Wide CJK/emoji → 2, combining marks / controls / explicit zero-width format chars → 0,
ASCII fast path → 1. Wired through a **continuation-cell model**: `Geex.Screen.put_grapheme/4` places
the glyph in a *lead* cell + an empty-`char` *continuation* cell (sharing the lead's style) for the
right half; `draw_text` and `Geex.Highlight.Paint.to_screen/6` advance by display width. The
`Geex.Renderer` needed **no change** — a `""` continuation emits no character and the terminal's own
auto-advance covers column two. **Verified:** 19 tests (width unit — expectations checked against OTP
first, not assumed; `put_grapheme` lead+continuation; Paint wide projection; Renderer emits the glyph
once + the continuation nothing). Full suite **375 tests + 8 doctests**.

**Adversarial review (`width-slice-review`, 2 dimensions × find→refute).** Found **1 critical**, all
else refuted (the width oracle and the lone-continuation invariant held). The critical: a wide glyph
whose **lead is the last column** placed the glyph there while its continuation clipped off-screen —
the renderer then drew a double-width glyph in the final column and overflowed the line (trigger:
`Screen.new(2,1) |> draw_text(0,0,"a中")`). **Fixed:** `put_grapheme/4` now refuses to draw a wide
glyph with no room for its second column — it pads the column blank and advances — with two regression
tests. (The prior test that *asserted* the half-drawn lead was the bug-as-spec; it was removed.)

**User-config layer — [ADR-0025](adr/0025-user-config-layer.md) (Proposed, not code).** Separates the
human's **user config** (theme/grammar/extension paths, later the keymap) from geex's **app/runtime
config** (boot flags/deps). TOML at `~/.config/geex/config.toml` (XDG), precedence `defaults < global
< project < GEEX_* env` cached in `:persistent_term` (pharos pattern). The shipped `Geex.Theme.load/1`
is the path-ready reader; this is the layer that points at it (the userpath-theme install story).
Format **decided: TOML** (comments + pharos parity; the §2a pointer-layer rule — config selects/points
at data files, never inlines them — keeps it shallow so TOML's arrays-of-tables weakness never bites).
The
roadmap gained an **editor-experience** section so this slice is tracked there, not just in ADRs.

**Not tested / deferred:** `Geex.Width` is unit-/render-tested but **not yet seen live** (gated on the
interactive TUI loop, like the rest of the display path); horizontal scroll + a **left-clipped** wide
glyph (its right half at column 0) is a future edge — geex has no horizontal scroll yet. ADR-0025 is a
**decision**, not an implementation: the `Geex.Config` reader, the TOML dep, and the env projection are
the build it specifies.

### 2026-06-08 — The interactive editor loop (ADR-0024), render + input halves

The ADR-0024 milestone: an **event-driven** loop (`Geex.Loop`) that renders the active buffer + its
highlight overlay and accepts typing — the thing that makes the live-highlighting dogfood real.

**Render half (commit `5192f53`).** `Geex.Loop` sits above `Geex.Session` and drives the generic core.
It subscribes to four event sources and coalesces a burst into one repaint (a `repaint?` flag + one
self-posted `:repaint`): **TerminalIO** (resize/keys), **Session** (active-buffer change — new
`Session.subscribe/1` → `{:geex_active_buffer, pid｜nil}`), **Buffer** (text change), and the
**Reactor** (overlay ready — new `Reactor.subscribe/2` → `{:geex_highlights, buffer, version}`, so the
loop wakes on fresh colours instead of polling). A repaint reads `Session.snapshot`, builds the screen
via `Paint.to_screen`, and places a **width-correct hardware cursor** through the new `Renderer.flush/2`
(cell diff + cursor in one write, so the cursor lands after the cells).

**Input half (commit `afb14ba`).** `Geex.Loop.Keymap` maps a key + cursor + text to an action, **purely**:
printable→`Insert`, Enter→newline, Tab→spaces, Backspace→`Delete` (or a `Replace` line-join at column 0,
since `Delete` is single-line), arrows→cursor motion **clamped + wrapping**, Ctrl-Q→quit. Edits dispatch
through `Dispatch.run` on the **one shared path** (human provenance); the cursor moves via the new
`Session.set_cursor/1`. So a human keystroke and an LLM edit travel the identical route.

**Verified:** the pure surfaces — `Loop.cursor_xy`/`frame`, `Renderer.cursor_seq`, the whole `Keymap`
(motion edges, line-join, command coordinates), `Session.subscribe`/`set_cursor`, `Reactor`/`Buffer`
subscribe+unsubscribe. **Full suite 410 tests + 8 doctests.** **Adversarial review** (`loop-slice-review`,
2 dims × find→refute) found **2 confirmed leaks, both fixed**: `Loop.detach` demonitored the old buffer
but never **unsubscribed** from it or its reactor, so across buffer switches the old processes kept the
loop subscribed (sending now-dropped messages) until death — fixed with `Buffer.unsubscribe/2` +
`Reactor.unsubscribe/2` called from `detach` (+ regression tests).

**Still deferred:** vertical/horizontal **scroll** (renders from the top, cursor off-screen-below is
hidden), the **configurable keymap** (this one is hardcoded; the user-config keymap is ADR-0025), mouse,
and truecolor→256/16 degradation.

### 2026-06-08 — Live dogfood, driven autonomously via a tmux pty (commit `cd234e8`)

The `Geex.Loop` GenServer needs a real terminal (raw-mode `:prim_tty`), which this dev box's agent shell
lacks. **tmux supplies one**: run geex inside `tmux new-session` (its own pty), `tmux send-keys` to type,
and `tmux capture-pane -p` (`-e` for ANSI) to read the rendered character grid back — so the TUI is
**drivable and observable headlessly**, no human screenshot needed. The full launch:

    elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("lib/geex/loop.ex")'

**Verified live:** geex paints the file in Birds-of-Paradise truecolor (box-drawing intact), typing
inserts + **re-highlights live**, Enter splits the line, a no-arg launch opens a typeable scratch buffer,
Ctrl-X quits cleanly (terminal restored), and logs land in `<tmp>/geex.log` (no alt-screen splatter).

**Bugs the live run caught — only a real terminal surfaces these — all fixed (`cd234e8`):**
- **Width/height swap.** `:prim_tty.window_size/1` returns `{cols, rows}`; `TerminalIO` + `Loop` read it
  as `{rows, cols}`, so a 100×32 terminal rendered **32 columns wide**. Fixed in the initial size and the
  resize event.
- **Quit keys.** Ctrl-Q is XON (flow control), Ctrl-C is SIGINT — swallowed before a raw-mode app sees
  them. Accept Ctrl-X (reliable) + Ctrl-Q/Ctrl-C; EOF (Ctrl-D) now quits (was: restart the loop).
- **The BEAM break handler.** The runtime reserves SIGINT/Ctrl-C for its `BREAK:` inspect-a-node menu
  (`sigint` isn't in `os:set_signal/2`), so the launch passes **`+Bd`** to disable it; SIGTERM stays
  graceful (so `kill` restores the tty).
- **Log splatter.** Startup `Logger` output painted over the alt-screen; `Geex.run/1` redirects logs to a
  file first (hence `--no-start`, so the redirect precedes the app boot).

**Vertical scroll — added + verified live (commit `54156cb`).** `Geex.Loop.scroll_for/3` (pure) tracks
the cursor: the viewport top edge-aligns when the cursor crosses a boundary, otherwise stays put;
`repaint` threads it through `Paint.to_screen` + `cursor_xy`. Verified in an 80×14 tmux pane on
`loop.ex`: 20 Downs scrolled the view down with the cursor pinned to the bottom row (`cursor_y=13`), 25
Ups scrolled back to the file top (`cursor_y=0`). No scrolloff margin yet (a config knob); horizontal
scroll still deferred.

**Editor chrome — added + verified live (commits `e014d8b` bg-fill, `0c413c8` status+scrolloff, gutter
next).** Three slices, each confirmed in a 100×30 tmux pane on `loop.ex`:
- **Theme background fill** (`Paint.to_screen`): the whole pane carries the BoP editor bg (`{:rgb,55,39,37}`)
  — blank lines + the gaps after short lines + below-buffer all brown; the bg SGR emits once and persists,
  no reset-to-default in the ANSI capture.
- **Status line + scrolloff** (`Loop`): the bottom row shows `loop.ex … line:col` on a reverse-video bar
  (`38;2;55;39;37` on `48;2;230;225;196` — theme fg/bg swapped); `scroll_for/4`'s margin held the cursor
  **exactly 3 rows** off the bottom edge (`cursor_y=25` in a 30-row pane, text rows 0..28) while scrolling,
  with the top-of-file pin riding the cursor above the margin.
- **Line-number gutter** (`Loop.frame` + `gutter_width/1`, [ADR-0027](adr/0027-grid-command-addressing.md)):
  right-aligned 1-based numbers in a width-`f(line count)` left inset (5 cols on the ~370-line file); text
  inset to column 5 and the cursor offset to match (`cursor_x=5` at line start); the **active line's number
  is cream `active_line_number`, inactive ones dim brown `line_number`** (a tmux-capture gotcha: the active
  number inherits the trailing bg-fill's cream and so emits no fresh SGR — confirmed via the top row, which
  has no preceding cell and shows an explicit `38;2;230;225;196`). Numbers track **buffer lines** under
  scroll (showed 9,10,11… not screen ordinals) and restart at 1 at the file top — matching ADR-0027's "the
  gutter number is the command grid's `y`". 431 tests + 8 doctests green.

**SIGWINCH resize — verified live.** `tmux resize-window` on a running geex: 80×24 → 120×30 grew the
status bar from 80 to 120 columns and re-laid-out the pane; → 50×12 shrank it back (status 50 wide, ~11
text rows). Both directions, width and height — the `:prim_tty` resize event reaches `TerminalIO` →
`{:geex_io, {:resize, rows, cols}}` → `Loop` (`Renderer.resize` + repaint). Closes the last unverified
display path.

**Horizontal scroll — added + verified live (ADR-0027-consistent).** `Paint.to_screen` gained an
`hscroll` column offset + a `place/5` helper that clips the **left** edge (which `put_grapheme` doesn't):
a grapheme scrolled past the gutter is dropped, and a wide glyph straddling the left edge shows a blank
in its visible half (the deferred wide-glyph edge from the width slice, now closed; unit-tested with
`中文`). `Loop.frame` reuses the **same `scroll_for/4`** along the column axis (an `@hscrolloff` margin)
and returns the resolved `hscroll` for the loop to persist. Verified in a 50×20 tmux pane on `loop.ex`:
moving the cursor right to column 56 of a long line scrolled the text left by 19 columns (`The
interactive e…` → `ditor loop ([ADR-0024]…`) with the **gutter pinned** and the whole viewport shifting
together (line 1 showed just its tail ` do`); the cursor stayed in the text area (`x=41`); walking back
to the line start **snapped `hscroll` to 0**. 436 tests + 8 doctests green.

**Current-line highlight + vertical scroll bar — added + verified live.** (1) **Cursor-line highlight**:
`Loop.frame` tints the cursor's whole row (gutter + text) with the theme's `active_line_bg` (the last
unused palette colour; BoP `#281C1C66` flattens to ≈`rgb(49,35,33)`, a subtle darkening) — only cell
backgrounds change, the brightened active line number stays. Verified in a 100×30 pane: the cursor row
carried `48;2;49;35;33`; moving down 5 reverted the old row to plain `48;2;55;39;37` and tinted the new
one — the highlight follows the cursor, no bleed. (2) **Vertical scroll bar**: when the buffer overflows
the viewport, the rightmost column is reserved (text renders one column narrower) and shows a dim `│`
track with a bright `█` thumb in the accent/cursor colour (`Loop.vscroll_thumb/3` sizes it ∝ visible
fraction, positions it ∝ scroll). Verified: thumb at the top at scroll 0, travelling to the bottom of the
track after jumping to line 206. The cursor never lands on the bar (it stays in `[gutter, w−1)`). 440
tests + 8 doctests green.

**Horizontal scroll bar — added + verified live.** A **permanently reserved row** above the status line
(row `h-2`; `text_height/1` now `h-2`, so showing/hiding the bar never reflows the text). It fills with the
theme background when there's no overflow and draws a dim `─` track + bright `█` thumb across the text
columns when a *visible* line is wider than the text area (`max_visible_width/3` × `scrollbar_thumb/3`, the
geometry now shared with the vertical bar). Verified in a 60×20 pane: scrolling right to column 71 of a
long line slid the thumb off the left edge (`───████───`); and the **vertical** thumb, after scrolling the
view down to line 163, travelled from the top to the middle of its track — confirming both bars track the
viewport (not the cursor) and move on real scrolling. 442 tests + 8 doctests green.

**Minibuffer (first slice) + Alt keys — added + verified live (ADR-0028).** The bottom row now doubles
as a **modal command input**: `Geex.Minibuffer` (a pure struct — mode / input / grapheme cursor) opened by
**`Alt+M`**, which takes over the status row (a `:` prompt on the plain theme bg, distinct from the
reverse-video status bar) and owns the hardware cursor while open. The `Geex.Input.Parser` learned
**`Alt`/Meta-letter** decoding (`\e`+letter → `{:alt, c}`, atomic so it doesn't clash with bare ESC or
CSI), and the keymap routes `Alt+M` → open and **`Alt+WASD`** → the same motion as the arrows (the
arrow-key alternative). v1 command: a bare line number jumps to that line (clamped); **`0` jumps to the last line**. The motion
keymap grew an arrow-free left-hand Alt cluster: **WASD** (up/left/down/right), **Q/E** (word back/forward,
whitespace-delimited, within-line), and **R/F** (line start/end). (An earlier ERTYUIOP layout was retired
at the user's request in favour of this tighter cluster.)
Cancel is **Alt+N** (paired with Alt+M open) — Ctrl-G dropped at the user's request; Esc still works when it
arrives (a bare ESC otherwise stays in the parser's leftover). Verified live in a 100×30 pane on loop.ex:
`Alt+M`→`:200`→Enter jumped to line 200 (viewport scrolled); `:abc`→**Alt+N** cancelled with no jump,
status restored; `:0`→Enter jumped to the last line (576:1, 575 newlines); from line 1, `Alt+I`→`1:23`
(line end), `Alt+U`→`1:1` (start), `Alt+Y`→`1:11` (word forward, start of `Geex.Loop`). 459 tests +
9 doctests green.

**Still unverified live / not built:** the keymap-capability/Kitty-protocol model
([ADR-0026](adr/0026-terminal-input-model.md)); **mouse** (so the scroll bars can't be dragged yet —
captured as a follow-up); **scroll keybindings** (PageUp/Down, line-scroll, horizontal — part of the
keymap work, [ADR-0026](adr/0026-terminal-input-model.md)); truecolor→256/16 degradation.

### 2026-06-09 — BUG-1 (typing flicker) fixed: atomic frames + conditional cursor

Closed [bugs.md](bugs.md) BUG-1. A research workflow's adversarial pass pinned the root cause against
the code: the renderer already diffs and writes one frame per syscall, but each frame was **not atomic**
(no synchronized-output) and **re-emitted `\e[?25h`** every frame, resetting the cursor blink — *not*
the "cursor teleports across changed runs" theory (refuted by 2 of 3 skeptics: the cursor is emitted
last in a single `:prim_tty.write` *by design*, [renderer.ex](../lib/geex/renderer.ex) `flush/2`). The
wide-glyph continuation-cell `""` one skeptic flagged was checked and is correct-by-design, not a bug.

**Fix** in `Geex.Renderer`: a pure **`frame/3`** wraps each frame's `[diff, cursor-delta]` in
`\e[?2026h … \e[?2026l` (DEC mode 2026 — terminals that lack it ignore the unknown private mode), shows
the cursor (`\e[?25h`) only on a hidden/nil→shown transition, and repositions it only when the diff
moved it or the cursor itself moved — so a settled cursor on an unchanged frame writes nothing. The
GenServer remembers the last-emitted cursor (`cursor:` in state); `flush/1` (cells only) invalidates it
to `nil`.

**Verified.** 8 new `frame/3` unit tests pin every cursor transition + the BSU/ESU wrap (a settled
no-op frame → `[]`; first frame shows+positions; hidden↔shown; reposition-without-show when only the
diff moved). **466 tests + 9 doctests** green, `--warnings-as-errors` clean. **Live (100×30 tmux pane
on loop.ex):** renders normally (gutter / text / vertical scroll bar / status `1:1`); typing `ABC`
advanced the cursor `5:0`→`8:0` and inserted into row 1; `Alt+S`×3 moved it to `8:3` (column preserved)
and it held stable; `Ctrl-X` quit clean; the source on disk was untouched (typed, never saved). The
*visual* "flicker is gone" call is the user's — `capture-pane` shows final cell state, not intermediate
frames — but the byte-level fix is proven by `frame/3` and the live run confirms no render regression.

**Deferred (bugs.md note):** trimming per-keystroke damage (`highlight_line/4` re-tints the active
line's whole-width bg every frame) is a layered perf win on non-2026 terminals, not part of this fix.

### 2026-06-09 — BUG-2 (line-tail flicker) fixed: optimistic highlight-overlay shift

Closed [bugs.md](bugs.md) BUG-2. After BUG-1, the user still saw the **tail of the edited line
shimmer while typing**, and confirmed the tell: a **no-grammar scratch buffer doesn't flicker**,
so it was the **highlighter's two-pass repaint**, not the renderer. The immediate post-keystroke
repaint painted with the *previous* text's spans (byte offsets now shifted by the edit) → colours
past the cursor misaligned for one frame until the async re-highlight landed; the misalignment
clusters at token boundaries near line ends.

**Fix.** The buffer emits the edit's **byte footprint** `%{at, removed, added}` on its change event
(`Geex.Edit.Footprint.of/2` + the new `Doc.byte_offset/2`) — carried on the *event*, so it works
for human, agent, and reconcile edits alike. The reactor shifts its overlay across the footprint
(`Geex.Highlight.Span.shift_all/2`) into an **optimistic** overlay exposed by a new `Reactor.render/1`,
which the loop paints — so the immediate frame is colour-aligned; the exact re-highlight supersedes
it. `highlights/1`/`await/3` stay exact, so nothing else is perturbed. The loop already repaints on
every buffer-change, so pointing it at `render/1` was the whole loop change.

**Adversarial review** (`bug2-optimistic-overlay-review`, 4 dimensions × find→verify, 14 agents):
**5 confirmed of 10, all fixed.** Two `medium` were real residual flicker of the same class — the
span-shift boundary was asymmetric-wrong (a char typed at a token's *start* stretched the token
over it; fixed with `shift_start` strict-`<` / `shift_end` inclusive-`<=`, with the symmetric tests),
and an `:unknown` footprint (multi-block `edit`) regressed the overlay buffer-wide (now retains the
prior overlay, with a reactor test). Two `low`: the loop's two-read text/overlay version-skew window
(documented at the read site — one-frame, self-correcting, reachable only via a concurrent MCP/
reconcile edit) and a stale `subscribe/2` docstring (fixed).

**Verified.** New pure tests pin the shift math (`span_test` incl. the start/end boundary asymmetry
+ the "typed char between two tokens stays neutral" case; `footprint_test` incl. multibyte/CRLF/
cross-line; `doc_test` `byte_offset`) and the wiring (`reactor_test`: `render/1` returns the shifted
overlay while `highlights/1` stays exact; `:unknown` keeps the overlay; `buffer_test`: the 4-tuple
footprint event). **503 tests + 9 doctests** green, `--warnings-as-errors` clean. **Live (100×30 tmux
on loop.ex):** typing `xyz` then a 13-key burst into highlighted Elixir inserted correctly, the cursor
tracked `5:0`→`8:0`→`18:0`, the final colouring was correct, nothing crashed, the source on disk was
untouched. As with BUG-1 the *visual* "flicker gone" is the user's call — `capture-pane` shows only
the settled frame, not the optimistic one — but the shift math is proven by the unit tests.

**Groundwork:** the `{at, removed, added}` footprint is exactly tree-sitter's `Tree.edit` input — the
deferred incremental-reparse optimization (ADR-0022) now has its plumbing.

### 2026-06-09 — Sticky goal column for vertical motion (a user nice-to-have)

Up/down used to clamp the cursor to each line's end and let the column erode toward the front through
short lines. Now vertical motion keeps a **goal column**: pure helpers on `Geex.Loop.Keymap`
(`vertical?/1`, `goal_column/2` → `:eol | col`, `apply_goal/3`) decide what to keep, and `Geex.Loop`
holds the goal in its state (frontend-local, like scroll). The goal **refreshes** after every
non-vertical cursor change (a move/edit/go-to-line) and **persists** across a run of up/down; it is
`:eol` when the cursor sits at a line end, so vertical motion then **tracks the end** of each line
(empty lines included). 5 new pure keymap tests.

**Live-verified** (100×30 tmux, a crafted file `L0=10 / L1="hi" / L2=empty / L3=13`):
- **Goal survives short + empty lines:** col 7 → Down clamps to col 2 (`hi`) → Down to the empty line
  (col 0) → Down **restores col 7** on L3 (`cursor_x` 11→6→4→11).
- **End-stickiness:** `Alt+F` to L0's end (col 10) → Down to `hi`'s end (col 2) → Down to the empty
  line (col 0) → Down to **L3's end** (col 13) (`cursor_x` 14→6→4→17).
- **Horizontal move breaks stickiness:** from L3's end, `Left` refreshes the goal to col 12; Up to the
  empty line then Down returns to **col 12, not 13** (`cursor_x` 16, confirming the `:eol` goal was
  correctly replaced). **508 tests + 9 doctests** green.

### 2026-06-09 — Selection + clipboard (highlight mode, copy/cut/paste)

The Selection primitive (ADR-0029, now **Accepted**) wired into the interactive loop + the clipboard
(ADR-0015), in three verified commits. **A** (`0225098`): `Geex.Clipboard` (global ring register;
push/top/ring, capped, empty-push is a no-op) + `Doc.slice/2` (the read sibling of `replace/3` — text in
a half-open grapheme range; `slice` then `replace`-with-`""` is a cut). **B** (`8d7a4c2`): the loop holds
a live `%Selection{}` (frontend-local, cursor = active end); `Alt+H` starts, motion extends, `Alt+Z`
select-all, `Alt+N`/Esc clear, and edit / go-to-line / buffer-switch / **any buffer change** clear it;
`Paint.to_screen` tints selected cells with `palette.selection`, the cursor-line tint suppressed while
selecting. **C** (`aa47d27`): `Alt+C`/`X`/`V` copy/cut/paste — copy = slice → push (no edit); cut = push
+ a recorded `Replace(range,"")`; paste = `Clipboard.top` baked into an `Insert` (or a `Replace` over a
selection — paste replaces a selection), cursor lands past the inserted text.

**Live-verified in tmux:** Alt+H + Right×6 tints "defmod" (half-open `[0,6)`) with `48;2;92;50;40` while
keeping the keyword-red fg; Alt+Z tints the whole visible buffer + jumps to the end; Alt+N clears (SGR
count 1→0); in a scratch buffer cut→paste round-trips, copy→paste **duplicates** ("hello" → "hellohello"),
paste **replaces** a selection, a partial cut leaves the remainder.

**Adversarial review** (`selection-clipboard-review`, 4 dimensions × find→verify, 15 agents): **8 of 11
confirmed.** Fixed: a **collapsed selection** (Alt+H with no motion) copy/cut pushed `""` and (cut)
recorded a no-op edit + dirty flag → copy/cut now no-op on `collapsed?`, and `Clipboard.push("")` is a
guarded no-op (defense-in-depth, unit-tested); a **stale selection survived out-of-band agent/reconcile
edits** (a later copy/cut would slice the wrong region) → the loop now clears the selection on every
buffer change. Deferred (low, documented in `paint.ex`): a multi-line selection's ragged right edge / no
tint on empty lines' trailing region; the CRLF `\r` selection-vs-render column mismatch (the pre-existing
cursor-vs-Paint CRLF gap). **Re-verified live:** after the fixes, a collapsed-selection copy is a no-op
(paste still yields "abcabc", clipboard not clobbered). **526 tests + 9 doctests** green,
`--warnings-as-errors` clean.

**Scoping:** the **typed** `copy`/`cut`/`paste` verbs ride the later catalog/palette chunk (they need the
command parser); the `Alt` bindings ship now.

### 2026-06-09 — Undo/redo engine (ADR-0031) + the two deferred Paint selection fixes

Two threads in one pass. **(1) The deferred selection-render polish from the 2026-06-09 selection chunk**
(documented in `paint.ex`): `Paint.to_screen` now **splits on `\n` like `Doc`** and walks each line's
graphemes, so a `\r` is content at its Doc column (CRLF lines keep the cursor/selection column model;
`\r\n` is no longer folded into one terminator grapheme) — and a line whose **trailing newline** falls in
the selection fills from its content end to the right edge, so a multi-line selection reads as fully
selected instead of ragged. Byte offsets stay aligned (`+1` per `\n`), so span colouring is unchanged.
New paint tests cover both (the multi-line newline fill + the CRLF `\r` column); the existing CRLF test
still passes (the `\r` is zero-width, so it draws nothing — only the column model moved).

**(2) Undo/redo, freshly built** ([ADR-0031](adr/0031-undo-redo-history-operations.md), **Accepted**) — the
history existed (ADR-0014) but nothing reverted it. `Geex.Buffer.undo/1` / `redo/1` via **replay-from-base**
(an immutable `base` `EditorState` + `Dispatch.replay/2` over the remaining history — the §15c backbone's
second use); a `redo` stack cleared by any fresh `dispatch/2`; `dirty` recomputed against the `synced`
baseline (undoing back to saved is clean); each returns the **affected command** so the *view* places the
cursor (undo → the edit's start, redo → its landing) — the cursor stays view-local (ADR-0014). Undo/redo
emit a `:reset` change; the reactor **drops its optimistic overlay** on `:reset` (undo makes `version =
length(history)` go *backwards*, which would otherwise freeze a stale higher-version overlay across a run
of undos). Keys: `Alt+Z` undo, `Alt+Shift+Z` redo (the one case-sensitive Alt chord); select-all moved to
`Alt+B`.

**Live-verified in tmux** (`/tmp/geex_undo_test.ex`, a real `.ex` buffer → grammar/reactor live): type
`XYZ` → `Alt+Z`×3 reverts char-by-char with the cursor landing at each undone edit's start and highlighting
re-deriving; `Alt+Shift+Z`×3 rebuilds with the cursor at each landing; an extra redo and undo-**past-base**
are clean no-ops (editor stays responsive, types `Q` after); `Alt+B` tints the whole buffer (`48;2;92;50;40`)
incl. the multi-line newline fill while keeping syntax fg; quit via Ctrl-X; the disk file is **never written**.

**Adversarial review** (`undo-redo-paint-review`, 5 dimensions × find→verify, 10 agents): **2 of 5
confirmed** (both medium, both the reactor `:reset` path; the undo mechanism, Paint restructure, loop
cursor, and keymap dimensions found nothing real). Fixed: (a) dropping the optimistic overlay on `:reset`
was only **half** the fix — `render/1` still served the stale pre-undo **`result`** for the *whole* async
re-highlight window (not "one frame"), painting byte-misaligned colours on the reverted region until the
corrective pass landed → a pure `render_overlay/1` now **suppresses a `result` stranded ahead of an
in-flight pass at a lower version** (serves `nil` → unstyled, which beats wrong colours); (b) the `:reset`
path had **no test** → added a `:reset` integration test (mirroring the `:unknown` one) + five pure
`render_overlay/1` branch tests. **Both fixes mutation-confirmed** (reverting either makes exactly those two
tests fail). **541 tests + 9 doctests** green, `--warnings-as-errors` clean.

**Scoping:** the **typed** `undo`/`redo` verbs (agent/palette twin) ride the catalog + view-action build
([ADR-0030](adr/0030-view-action-tool-category.md)); insert **coalescing** (per-keystroke undo for now) and
the `O(n)` replay-per-undo are documented deferrals.

### 2026-06-09 — Undo/redo flicker fix: ride the forward-edit overlay path (ADR-0031 §5 revised)

The user reported a **flicker on undo/redo**. Diagnosis (and honest self-correction): the first cut emitted a
`:reset` change → the reactor dropped its optimistic overlay and re-highlighted from scratch → the reverted
region painted **unstyled** for the whole async re-highlight window. That was *more* visible than the
near-aligned stale frame it replaced — the review fix optimized correctness over flicker. The proper fix makes
undo/redo ride the **same optimistic byte-shift path as forward typing** (which doesn't flicker — BUG-2's win):

- **`Geex.Edit.Footprint.between/2`** — the minimal byte splice between two texts (`:binary.longest_common_
  prefix`/`suffix`, capped so they can't overlap), in the *before* frame. A single undo/redo reverts exactly
  one contiguous command, so this splice is **exact**; undo/redo emit it instead of `:reset`, and the reactor
  shifts its overlay across the revert just like a forward edit.
- **A monotonic `seq` on `Geex.Buffer`** (incremented on every dispatch/undo/redo; *distinct* from `version =
  length(history)`, which goes backwards on undo). The reactor now orders overlays by `seq`, so its
  `keep_optimistic` "newer = higher" assumption survives an undo — which is exactly why the blunt `:reset` was
  needed before. With the byte-shift + the monotonic seq, undo/redo need **no special reactor case**: the
  `:reset` `shift_overlay` clause AND the interim `render_overlay/1` version-guard are both **removed**
  (`render` is back to `optimistic || result`).

**Live-verified** (tmux, demo `.ex` buffer): typing `x` before `defmodule` breaks the keyword (no longer
keyword-red); `Alt+Z` undo **restores** the keyword colour and the text — undo re-highlights correctly through
the normal path. (The flicker itself is an intermediate frame `capture-pane` can't show, so the "flicker gone"
call is the user's — same caveat as BUG-1/BUG-2; the mechanism is proven by the unit tests below.)

**Tests:** 7 `Footprint.between/2` cases (append/inverse/middle/replace/multibyte/overlap-cap/empty); buffer
tests for the byte-footprint emit on undo + `seq` monotonic across dispatch/undo/redo while `version` tracks
history length; reactor tests that an undo-shaped (removing) footprint **shifts** the overlay (not reset) and
that undo re-highlights end-to-end on the monotonic seq (`await(seq=2)` after an undo, comment capture gone).
Removed the now-obsolete `:reset` + `render_overlay/1` tests. **545 tests + 9 doctests** green,
`--warnings-as-errors` clean.

**Adversarial review** (`undo-flicker-fix-review`, 4 dimensions × find→verify, 7 agents): **0 of 3 confirmed**
— all three findings refuted on verification (the `between/2` splice validity, the `seq` increment paths, and
the `optimistic || result` simplification all held up). ADR-0031 §5 rewritten (byte-footprint + monotonic seq;
the `:reset` first cut kept as a revised-from note).

### 2026-06-09 — The typed command surface: `line` view action + minibuffer verbs (ADR-0030 → Accepted)

The user green-lit "commands starting with `line 1` etc." — the ADR-0030 build. **(1) The fourth tool
category is real:** `Geex.MCP.ViewActions` ([view_actions.ex](../lib/geex/mcp/view_actions.ex)), field-spec
→ `tools/list` (now 11 tools: 4 edit + 6 operation + `line`), a fourth `tools/call` route. `line/1` is **the**
go-to-line resolution: 1-based, `0` = last line, clamped; the loop's `run_command` hack is **deleted** — bare
`N`, typed `line N`, and `tools/call line` converge on it (ADR-0030 §3 as decided). **(2) The typed verb
surface:** `Geex.Loop.Verbs` (pure parser) + the loop's extracted `apply_action/4` — chords (`Keymap`) and
verbs share **one action vocabulary**, so `copy` ≡ `Alt+C` by construction. Verbs: `line N`/bare `N`,
`copy`/`cut`/`paste`, `undo`/`redo`, `highlight`/`select` (+ ` all`), `save`, `quit`/`exit`, `no`. **(3)
Parity extras:** `Ctrl-O` = save (the ADR-0026 reserved chord — the TUI previously had *no* save path);
typed `save`/`quit`. **(4) Agent visibility:** `Session.set_cursor` now notifies view subscribers
(`{:geex_cursor, cursor}`, **excluding the setter** so the loop's own moves aren't echoed into double
repaints) — an agent's `line` call repaints the TUI.

**Live-verified in tmux:** `:3`, `:line 1`, `:0` (last) all jump (status 3:1/1:1/4:1); typed
`copy`→`paste` duplicates and `undo` reverts; `Ctrl-O` clears the dirty marker and writes disk; typed
`quit` exits; an in-VM "agent" calling `ViewActions.line(3)` at t+12s moved the cursor 1:1→3:1 **with zero
keystrokes**, and (after the review fix) **cleared a live selection** (tinted rows 1→0).

**Adversarial review** (`typed-commands-review`, 4 dimensions × find→verify, 17 agents): **7 of 13
confirmed** (3 were one defect found thrice). Fixed: (a) MEDIUM — the `{:geex_cursor}` handler only
repainted, leaving the loop's **selection and goal stale** (a following motion would extend a phantom
selection across the jump; a cut would grab anchor→landing) → the handler now mirrors `jump_to_line`
(clear selection, refresh goal); (b) MEDIUM — `ViewActions.line/1` makes bare Session calls, so typed
`line N` **lost the loop's exit-containment** (a dead Session/stale buffer pid could crash the Loop, a
regression vs the deleted hack) → `safe_view_line` catch on the loop door (the MCP door already had
-32603 containment), plus the root hardening: Session's `:snapshot` now **guards the buffer call**
(dead pid → `:no_active_buffer`, never takes Session down) and **clamps the merged cursor to the text**
(the stored view cursor is unvalidated and can be stale-of-range after a race or buffer switch); (c) LOW
— `Verbs` accepted **signed** numbers (`-0` would silently mean "last line", `+5` parse as 5) → digit-
gated; (d) LOW — typed `no` parsed as a plain cancel, so the typed surface **couldn't clear a selection**
→ `no` is now the true `Alt+N` twin (`:select_clear`; degrades to cancel with nothing selected).
**576 tests + 9 doctests** green, `--warnings-as-errors` clean.

**Scoping:** the verb table is hardcoded v1 — it re-bases on the **catalog** when the palette lands
(ADR-0028); `scroll` / coordinate `select` / grid `goto x y` are the next view-action members; typed
`open`/`new`/`close` wait for path completion (the finder).

### 2026-06-09 — Grid commands: the human picking surface (ADR-0027 built)

The differentiator. Coordinate-addressed `copy`/`cut`/`goto` with a display-column **ruler** + **grid-line
overlay**. Two commits. **A** (`11d7af1`) — the pure, replay-safe core: `Geex.Coord` (`%Coord{x,y}` +
`Coord.Range`; `parse/1`, `to_caret/2`, `to_span/2` — inclusive→half-open, clamp-x, EOF-error) +
`Width.col_at_display/2` (display column → 1-based grapheme `x`; a wide glyph owns two display columns, both
map to it) + `Screen.translate_y/2`. All grapheme/pure — the ADR-0027 §2 safety property (a width-table
change can mis-*render* but never mis-*address*). **B** — grid mode: `Alt+G` opens the minibuffer in `:grid`
mode and the repaint shows the **contextual** ruler (top row, `hscroll`-locked, reserved via `translate_y`)
+ the **dotted `┊` grid-line overlay** (every 5th display column, every 10th brightened, two-tone palette-
derived, drawn only on blank cells — indent-guide style, never over a glyph). `Verbs.parse_grid` parses
`copy`/`cut <range>` and `goto`/bare `<coord>`; the loop casts display→grapheme per endpoint, resolves via
`Coord`, and `copy`/`cut` reuse the clipboard ops by setting the resolved span as the (briefly visible)
selection. The key simplification: `y` is the gutter number (already logical, scroll-independent), and the
display→grapheme cast is **pure** (`hscroll` only positions ruler ticks) — so the "viewport-relative" mode
the ADR fretted over is just a pure cast.

**Live-verified in tmux** — incl. the one fragile seam (the display↔grapheme cast, ADR-0027 §"Verification"):
the ruler shows `…7890123…`, the dotted rules land in the blank cells under their ticks; `goto x5 y2` →
status 2:5; `copy x3 y2 - x5 y2` then paste duplicates "def". On a **wide-glyph** line `x中yz hello`:
`goto x4` lands on grapheme 3 (`y`, *not* 4), `x2`/`x3` both map to `中`'s grapheme, and `cut x7-x11` removes
"hello" — the cast honours `中`'s two columns exactly. Chrome clears on submit. (Manual confirmation; the
`cursor_x`-oracle *automated* test stays deferred.)

**Adversarial review** (`grid-commands-review`, 4 dimensions × find→verify, 6 agents): **1 of 2 confirmed**
(live-reproduced). Fixed (medium): `grid_clip` built the selection **unconditionally**, so a range whose
endpoints both overshoot a short line (`copy x5 y1 - x9 y1` on a 2-char line) resolves to a **collapsed**
span; `do_copy`/`do_cut`'s collapsed-guard early-returns *without* nilling it, leaving a truthy-but-collapsed
`%Selection{}` that the next motion turns into a **phantom highlight** → `grid_clip` now nils the selection on
the collapsed path (a real no-op). Re-verified live: a collapsed grid-copy + motion shows **0** selection-
tinted cells. **606 tests + 9 doctests** green, `--warnings-as-errors` clean.

**Scoping:** this is the **human** picking surface only. The **agent/buffer-absolute** grapheme form (a
`Geex.Command.Type` `:coord` cast + a grid edit tool), **block**/**multi** ranges, easy-motion jump labels,
and the `cursor_x`-oracle automated cast test are documented deferrals (ADR-0027 amendment).

### 2026-06-09 — Command palette: `Alt+P` fuzzy browser over the catalog (ADR-0028 §3, commit `62d52e0`)

*Entry written 2026-10-14 from the commit record and session notes — the slice shipped without one.*

The first discovery surface. `Geex.Fuzzy` (pure subsequence `score/2`: greedy O(n) walk, compounding
contiguous-run + word-boundary bonuses, so prefixes beat scattered acronyms — `sa` ranks `save` above
`select all`); `Geex.Command.Catalog` (+ `Catalog.Entry`, its own file) = the one structured
`{name, description, invoke}` list, `invoke` either `{:action, atom}` (→ the shared `apply_action/4`) or
`{:typed, prefix}` (→ hand off to `:command` mode pre-filled, e.g. `line `); `search/1` bands name matches
above description-only ones. The `:palette` minibuffer mode: `input` = filter, a new `sel` field = the
highlighted row (reset on every edit), a candidate popup painted over the rows above the input (no reflow),
`Alt+W`/`Alt+S` + arrows navigate with wrap, Enter runs the pick.

**Live-verified via tmux:** open → filter → `Alt+W`/`Alt+S` → Enter on both an `{:action}` entry and a
`{:typed}` hand-off → `Alt+N` close. **629 tests + 9 doctests** green.

**Not tested / deferred:** Esc-close inherits the documented bare-ESC linger (all modes); path operations
(open/close/create) wait on the fuzzy finder; the `Verbs` table is not yet re-based on the catalog.

### 2026-06-10 — Grid-agent parity: the agent's grapheme-coordinate surface (ADR-0027 amendment, commit `c643941`)

*Entry written 2026-10-14 from the commit record and session notes — the slice shipped without one.*

The agent half of grid: an agent speaks the same `"x5 y7"` / `"x5 y7 - x12 y9"` grammar a human types in
`:grid` mode, resolved as **buffer-absolute graphemes** (no display cast — text readers are already in
graphemes). `Geex.Command.Type` `:coord`/`:coord_range` cast through the same `Geex.Coord.parse/1`; a wrong
shape is a clean argument error; the schema renders both as string args. `Geex.MCP.Grid`: `goto` (move the
active cursor — the 2-D `line`, riding the same cursor-notify repaint path) and `copy` (`Coord.to_span` →
`Doc.slice` → `Clipboard.push` onto the ring the human pastes from with `Alt+V`). A collapsed span is a
clean error, not an empty copy. `Protocol.tool_call` became a `with`-chain (one lookup per category).

**Verified through the real protocol path** (`tools/call` `goto`/`copy` via the JSON-RPC handler) + `Grid` /
`Type` unit tests — **not** live over HTTP at the time. **649 tests + 9 doctests** green. (The 2026-10-14
entry below confirms `goto`/`copy` appear in a live `tools/list`.)

**Not tested / deferred:** agent `cut` (= copy + a recorded `replace`), coordinate `select` (selection is
loop-local), and exposing undo/redo/paste as agent tools (the `Verbs` ↔ catalog unification).

### 2026-10-14 — Project tooling, live reconcile, and a sibling-dep fix (after a four-month gap)

First session back since `c643941`. Suite re-run first: **649 tests + 9 doctests**, clean.

- **Repo tooling, in line with the other projects** (captAInHook, pharos-mcp, DeepSeek Moby):
  `CLAUDE.md` (invariants + where to look) and the skills `/orient`, `/shipshape`, `/dogfood` under
  `.claude/skills/`. The `/dogfood` recipes were run before being written down: a TUI pass in a
  private-socket tmux pty (typed into a scratch file, read the grid + `cursor_x,y` back, Ctrl-X quit) and an
  MCP pass (`mix geex.serve` on an auto port via `GEEX_MCP_PORT_FILE` → `initialize`, `notifications/initialized`
  → 202, `tools/list` → all 13 tools incl. `line`/`goto`/`copy`, `open_file` → the text; foreign `Origin` → 403,
  GET → 405).
- **`inotify-tools` installed on the dev box → the reconcile floor shown live** (the open item from the
  2026-06-05 presets entry). Under `mix geex.serve`: `open_file` a scratch file (`before`), overwrite it from
  the shell, and the server logs `geex reconcile: external change to …/t.txt`; the buffer then reads
  `after (out-of-band)`. First live demonstration of `:external` reconcile against the real watcher.
- **That install exposed a host-dependent test.** `reconcile_test` "degrades gracefully when the watch backend
  is unavailable" only passed because inotify was *absent*. Fixed with a backend seam:
  `Geex.Reconcile` takes a `:start_watcher` option (default: the real `FileSystem.start_link/1`); the test
  stubs it as `:ignore`, and a new test stubs a successful backend to pin the success path (dir recorded once,
  second `watch` is a no-op). **650 tests + 9 doctests**, green twice, now with no inotify noise.
- **`plug` 1.19.2 → 1.20.3** (+ `plug_crypto` 2.2.0), lockfile-only, in-range; suite green twice.
- **Sibling `../tree_sitter_wasm` committed clean** (`6c4d23c`): an uncommitted fix was sitting in the path
  dep — reset the cached parser after a cancelled/failed parse (otherwise the next highlight on the same
  grammar handle resumes the halted parse and returns corrupted spans), with its regression test. Its suite
  green twice before committing; geex now compiles against a committed sibling.

**Not tested:** no TUI-visible geex code changed, so no new TUI behaviour to verify; the live Claude Code
preset run (Handle 3 of `/dogfood`) is still the open v0.5 item; provenance of the reconciled edit was not
read from the in-process history this pass (the log line + buffer text are the evidence).

### 2026-10-14 — Ledger step (a): line-level reconcile hunks + the write-completion quiet period (ADR-0032)

Reconcile no longer adopts an out-of-band write as one whole-buffer `replace`. New pure module
`Geex.Edit.LineDiff`: `List.myers_difference/2` over the two texts' lines → hunks → `Doc.replace/3`
spans ordered **bottom-up** (each stays valid as the ones below it apply); `spans/2` checks that the
spans reproduce the disk text byte for byte and otherwise returns `:error`, and reconcile falls back to
one whole-text replace. New `Buffer.dispatch_group/2`: applies a list of commands all-or-nothing, records
each as its own history entry (so undo walks back hunk by hunk), clears redo, and sends **one** change
notification whose footprint is the whole transition's byte diff. Every command from one reconcile carries
`meta.reconcile = %{group, before_sha256, sha256}`: a shared monotonic group id, the sha256 of the
**baseline disk bytes** the write replaced (`synced`, not the possibly-dirty buffer text), and the sha256
of the **disk bytes read**, both 64 lowercase hex. A future attestation must match both (ADR-0032). The watcher now waits for a per-path
**quiet period** (`settle_ms`, default 50 ms; `0` under test via `config.exs`, so "nothing changed"
assertions can't pass vacuously) before reading, re-arming on each event and dropping superseded timers
by ref. `:crypto` added to `extra_applications`.

**Live-verified:**
- **How Claude Code writes** (the amendment's dogfood question), observed with `inotifywait` on a scratch
  dir while this session used its own tools: both `Edit` and `Write` create `<name>.tmp.<pid>.<hex>`, write
  and close it, then **rename it over the target** (`MOVED_FROM` tmp → `MOVED_TO <name>`). So Claude Code's
  writes reach reconcile as one complete `moved_to`; the quiet period matters for in-place writers (shell,
  other editors). The temp-file events hit no open buffer and are ignored.
- **The ledger end to end, in the TUI:** geex open (tmux pty) on a 6-line file; this session's native
  `Write` changed lines 2 and 5; the TUI showed both live; one `Alt+Z` reverted only line 2, a second
  reverted line 5, cursor landed on the reverted hunk, status `[+]` (buffer ≠ disk). Disk untouched.

**Automated:** `line_diff_test` (table cases at top/middle/end, trailing newline, empty doc, CRLF + wide
graphemes, bottom-up order, a 500-pair seeded randomized round-trip; an ad-hoc 3,000-pair fuzz also gave
zero fallbacks), `buffer_test` `dispatch_group/2` (applies + one notify, all-or-nothing, undo per command),
`reconcile_test` (multi-hunk group shares group + both hashes; `before_sha256` is the synced baseline even on a dirty buffer; separate writes are separate groups; undo
walks hunks; a burst inside the quiet period reconciles once, to the final bytes, never reading the
half-write). **669 tests + 10 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** a write that outlasts the quiet period (adopted in pieces, by design); a large-file
performance check of the line diff; conflict handling on a dirty buffer (step b: still last-writer-wins).

### 2026-10-14 — Ledger step (b): merging a disk change into a dirty buffer (ADR-0032)

The maintainer's rule: **disk wins on overlap, and you're told.** New pure `Geex.Edit.Merge.merge/3`
(base = synced disk text, ours = buffer, theirs = new disk text, all as `LineDiff` hunks in base
coordinates): every disk hunk is applied; each unsaved hunk of yours is kept unless it overlaps one
(intersecting removed ranges, inserts at the same point, or an insert strictly inside the other's range;
adjacent-line changes don't conflict); the count of replaced hunks excludes identical changes.
Reconcile now diffs the buffer text against the merged text (so it lands as the usual hunk group,
stamped with the **disk-bytes** hashes) and passes three new `Buffer.dispatch_group/3` options:
`baseline:` (re-sync `synced` to the disk bytes and recompute `dirty` in the same call), `notice:`
(broadcast `{:geex_buffer_notice, buffer, text}`), and `expect_seq:` (refuse with `:stale` if an edit
landed after reconcile's snapshot; reconcile retries up to 3 times — closes a race the whole-buffer
replace also had). The TUI shows the notice on the status line until the next key; the status line now
keeps at least one space before `line:col` (a long notice had run into it).

**Live-verified in the TUI** (tmux pty, 100×12): typed unsaved edits on lines 1 and 5 (`MINE alpha`,
`epsilalso-mine on`); this session's native `Write` then changed lines 1 and 4. Result: line 1 took the
disk text `ALPHA (agent)` (overlap), line 4 merged `DELTA (agent)`, line 5 kept the unsaved edit, status
`doc.txt [+]  disk changed: 1 of your unsaved hunks took the disk version (Alt+Z restores yours)`; one
`Alt+Z` restored `MINE alpha` (and dismissed the notice) while line 4's agent change stayed.

**Automated:** `merge_test` (disjoint, adjacent, overlap + count, identical change, delete-vs-edit,
same-point inserts, different-point inserts, a 300-case seeded identity check; doctests), `reconcile_test`
(disjoint merge keeps yours and stays dirty with no notice; overlap → disk + notice + undo restores;
disk equal to buffer records nothing and re-syncs; merged group keeps disk-bytes hashes), `buffer_test`
(`expect_seq` refuses stale; `baseline` re-syncs + `notice` reaches subscribers), `loop_test` (status gap).
**684 tests + 12 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** the `:stale` retry under a real keystroke race (the guard itself is unit-tested); a
notice when the buffer isn't the active one (only the attached loop shows it).

### 2026-10-14 — Ledger step (c): the attestation intake (ADR-0032)

`Buffer.attest/2` upgrades the buffer's **newest reconcile group** (every command, once) from `:external`
to `{:agent, %{harness, session, turn, tool_use}}` only when the attestation's `before` and `sha256` both
equal the group's stamped hashes; otherwise the attestation is parked in a per-buffer pending table (64
entries, 10 s TTL), and `apply_group` consumes a matching one as the group is recorded, so the group lands
already attested. A repeat for an already-attested group returns `:ignored`; a message with no `before` (a
created file) is `:ignored`. Subscribers get `{:geex_buffer_attested, buffer, group, actor}`. `Geex.Attest`
validates the v1 message strictly (hashes exactly 64 lowercase hex, absolute path, harness + session
required, unknown fields ignored) and routes it to the open buffer (`:not_open` otherwise).
`Geex.Attest.HTTP` = `POST /attest` (Bearer token, constant-time compare; `Origin` → 403); the listener now
starts on every non-test boot, serving **only** `/attest` in TUI mode (the full MCP router, which hands
`/attest` on, under `mix geex.serve`). `Geex.Attest.Discovery` publishes `$XDG_RUNTIME_DIR/geex/<os_pid>.json`
(`{v, url, token, pid}`, file `0600`, dir `0700`, temp-write + rename) and removes it on a clean stop.
Reconcile's log line names the agent when a parked attestation was consumed.

**Live-verified** (TUI in a tmux pty, real listener + discovery file, this session's native `Write`, curl as
the payload): discovery file `0600` in a `0700` dir with a 64-char token; no token → **401**; an attestation
POSTed **before** the write → `pending`, then the write's group was recorded attested (`geex reconcile:
external change to …doc.txt (attested: claude-code session live-test)`); a second write, attested **after**
→ `attested` (logged `attributed to claude-code session live-test`); the same message again → `ignored`;
quitting removed the discovery file.

**Automated:** `attest_test` (parse: minimal / optional fields / hash format / version / path / identity;
the both-hashes rule: late, early, coalesced sed+agent stays `:external`, identical-bytes never matches,
only the newest group, human edits after don't block, no-`before` ignored, pending expiry, replay unchanged
by an upgrade; `submit` not_open; HTTP 401/403/400/200 incl. end-to-end on an open buffer and via the MCP
router; discovery file modes, contents and cleanup). **705 tests + 14 doctests**, green twice,
`--warnings-as-errors` clean.

**Not tested:** the payload itself (step d) and real captAInHook envelopes; whether Claude Code's
`originalFile` matches the disk bytes for every file (the step-d dogfood check); two geex instances with
the same file open.

### 2026-10-15 — Ledger step (d): the captAInHook payload, and CRLF (ADR-0032)

`integrations/captainhook/geex-attest.sh`, a fail-open oneshot `post-tool-use` handler: for a `claude-code`
`PostToolUse` of `Write` / `Edit` / `NotebookEdit` it POSTs `{v, path, before, sha256, harness, session,
turn, tool_use}` (`before` = sha256 of `originalFile` / `original_file`, `sha256` = sha256 of the disk) to
every live geex discovery entry, in parallel, then exits 0 with empty stdout. Everything else sends nothing.
geex side: reconcile also stamps `before_sha256_lf` (the baseline with each `\r\n` as `\n`) when the baseline
holds `\r\n`, and `Buffer.attest/2` accepts either before hash; `sha256` stays exact. The rule came from the
coordinator's live check on Claude Code 2.1.299 (one left-to-right `\r\n` → `\n`; a lone `\r` stays).
Fixtures: captAInHook `3ddb467`, copied verbatim to `test/fixtures/claude-code/`.

**Live-verified** with the handler registered in `~/.captainHook/handlers.json` (backup
`handlers.json.bak-20261015-090908`; hot reload logged `added 1, kept 7`). Two geex TUIs in a tmux pty, one
on an LF file and one on a CRLF file, so every POST went to two instances. This session's native tools:
- LF `Edit` → `geex attest: … attributed to claude-code session d25a8b6d…`. The reconcile landed first, so
  this was the late path.
- CRLF `Edit` → CRLF kept on disk (`od -c`); the attestation arrived first (`pending`), then `geex
  reconcile: … (attested: claude-code session d25a8b6d…)`.
- `Write` over the CRLF file → rewritten as LF on disk, and attested the same way.
- `sed -i` via Bash → reconciled with no attestation (stays `:external`).
- Quitting both TUIs removed both discovery files.
- captAInHook trail: 20 runs of the handler across this machine's sessions, avg 15 ms, min 4 ms, max 92 ms
  (the first Edit; geex's first `/attest` request), no non-zero exit, no stderr rows.
- Measured beforehand against `mix geex.serve` (stripped env, n=20/20/10): non-writer ~3 ms, small Edit
  ~15 ms, a 2.7 MB file (8 MB envelope) ~250 ms.

**Automated:** `attest_test` (the coordinator's five line-ending rows, with `originalFile` written out
literally; the pending path; the after hash is never loosened; no `\r\n`, no second hash; the residual: a
CRLF→LF conversion coalesced with an agent edit is credited to it). `attest_payload_test`, 16 tests: the
three writer fixtures give the exact message and bearer token; Write-create, Read (text, notebook), Bash, a
`PreToolUse` line, another harness and a NotebookEdit with an `error` send nothing; garbage in → exit 0 plus
a stderr note; no geex → exit 0; discovery: two live instances both receive, while a dead pid, a `localhost`
url and a non-hex token are skipped and a refused POST is reported; the macOS `shasum -a 256` fallback with
no `sha256sum` on PATH; end to end through the real `POST /attest`, an Edit credited with the fixture's
session / prompt / tool-use ids, and a CRLF Write. **730 tests + 14 doctests**, green twice,
`--warnings-as-errors` clean.

**Not tested:** `NotebookEdit` and `MultiEdit` live (NotebookEdit is fixture-tested only); geex on macOS
(its `file_system` FSEvents backend has never run here); a hung but alive geex (the 1 s cap is curl's); two
geex instances with the same file open; harnesses other than Claude Code (they send nothing by design).

### 2026-10-15 — Ledger step (e), display only: who wrote this line (ADR-0032)

`Geex.Blame` (pure): one writer per line, `{actor, reconcile group}`, from the history, `git blame` style
(a command writes the lines between the common prefix and suffix of before/after). `Geex.Buffer` advances
it per applied command (dispatch, group, redo), rebuilds it in undo's replay (`Blame.replay/2`), relabels a
group on a late attestation, and returns it in the snapshot as `blame`. The TUI draws `▌` (theme accent) in
the gutter's left margin on lines an agent last wrote (`{:agent, …}` / `{:llm, …}`), shows `✎
<harness>/<session8> · turn <4>…` left of the position for the cursor's line, and repaints on
`{:geex_buffer_attested, …}`.

**Live-verified** (geex TUI in a tmux pty on a scratch `doc.txt`, the step (d) hook registered):
- This session's native `Edit` of line 3: `▌` appeared on line 3 **with no keypress** (attestation pending,
  then the group landed attested).
- `sed -i` via Bash on line 2: no mark; the status line on line 2 shows only the position.
- Cursor on line 3: `✎ claude-code/d25a8b6d · turn 3466…  3:1`.
- Typing `x` on line 3 removed its mark (now yours); `Alt+Z` restored it. Two more `Alt+Z` undid the `sed`
  and the agent hunk, and the mark went. `Alt+Shift+Z` brought it back, then the `sed` line.
- **Two sessions:** the coordinator session (oof-af, now `oof-41`) changed line 4 with its native `Edit`.
  Line 4 got its own `▌`; the status line read `✎ claude-code/7ccbf3d1 · turn 441b…` on line 4 and
  `✎ claude-code/d25a8b6d …` on line 3.
- Quitting removed the discovery file.

**Automated:** `blame_test` (4 doctests + 10: step for edit / insert / delete / no-op / multi-line;
`replay/2` ends where `Dispatch.replay/2` does with one entry per line; in a buffer: an attested hunk marks
its line and a shell write stays `:external`, attested-first lands marked, two sessions keep their own
labels, typing makes a line yours while Enter at its end doesn't, undo clears and redo restores, your
edits shift an agent line without unmarking it). `loop_test` (`author_label/2`: agent with/without turn,
MCP, none for human/external/loaded/out of range; `agent_marks/5`: agent rows only, accent fg, bg kept,
follows the scroll). **744 tests + 18 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** a late attestation's repaint in isolation (live, the attestation arrived first both times;
the handler is a one-line repaint); blame cost on a very large file or a long history (one O(lines)
prefix/suffix pass per command, plus undo's existing replay); grid mode with marks (the ruler shifts rows,
and the mark is painted before that shift, as the text is).

### 2026-10-15 — Durable ledger build step 1: the pure `Geex.History` (ADR-0033)

`Geex.Buffer`'s history transitions moved into a pure value, `Geex.History` (base, editor, commands
newest-first, redo, blame, synced, dirty, seq): `dispatch/2`, `group/3`, `undo/1`, `redo/1`,
`attest/3`, `sync/1`, plus the group queries `newest_group/1` and `unattested?/2`. The buffer keeps
only the process concerns: path, subscribers and notifications, the pending-attestation table, file
I/O. Its state is `%{path, history: %History{}, subscribers, pending, pending_ttl_ms}`. The snapshot
and every public `Geex.Buffer` function are unchanged. buffer.ex went from 664 to 524 lines. No
behavior change intended. This is the seam the ledger will replay through (ADR-0033 §3).

**Live smoke** (TUI in a tmux pty): typing `hi `, three `Alt+Z` (back to clean, `[+]` cleared), one
`Alt+Shift+Z`. Then this session's native `Edit` of line 2 while line 1 held an unsaved edit: the merge
kept the unsaved `h`, the buffer stayed dirty, line 2 was credited (`attested: claude-code session
d25a8b6d…`), and the `▌` mark and `✎ claude-code/d25a8b6d · turn e2dc…` showed. Quitting removed the
discovery file.

**Automated:** `history_test` (1 doctest + 9): dispatch clears redo, dirties and bumps `seq`; a failing
command changes nothing; a group is all-or-nothing; a baseline re-syncs and recomputes dirty; an empty
group keeps redo; undo onto the synced text is clean and redo re-dirties; nothing to undo or redo;
sync; attest relabels only its group's commands and blame. **The ledger's rule, pinned:** after 300
seeded random dispatch/undo/redo steps with mixed actors, replaying the recorded commands over `base`
rebuilds the same editor and the same blame. The whole existing suite passes unchanged. **753 tests +
19 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** none of the ledger itself exists yet (build step 2). Group ids are still
`System.unique_integer/1` until step 2 makes them durable.

### 2026-10-15 — Durable ledger build step 2: the ledger, write path and restore (ADR-0033)

Every path-backed buffer appends one JSON line per history transition to
`$XDG_STATE_HOME/geex/ledger/<key>.jsonl` (`Geex.Ledger.Codec` / `Restore` / `Ledger`), and replays it on
open. The disk is then checked against the replayed synced text: a match restores everything (unsaved
edits come back dirty); a difference becomes one `:external` gap group. Group ids now come from
`Geex.History.next_group`. Config gate `ledger` (off under test).

**Live-verified** (geex TUI in a tmux pty, `XDG_STATE_HOME` pointed at a scratch dir; the ledger file and
its `jq`-read entries checked at each step):
- **Session 1.** The first keystroke created the ledger (`0600` file, `0700` dir) and its lock. Then this
  session's native `Edit` of line 3 (credited, marked), `Ctrl-O`, and an unsaved `y`. Entries: `open, cmd,
  group, attest, sync, cmd`; quitting added `close` and removed the lock.
- **Session 2.** The status line read `restored unsaved changes from your last session`, the buffer was
  dirty with the `y`, line 3 kept its `▌` and `✎ claude-code/d25a8b6d · turn 74cd…`. `Alt+Z` removed the
  `y` (clean again: equal to the saved file); a second `Alt+Z` undid session 1's agent hunk. Two
  `Alt+Shift+Z`, then quit, leaving the `y` unsaved.
- **Changed while closed.** `sed` rewrote line 2 (`beta`, where the unsaved `y` was) with geex closed.
  Relaunch: `the file changed while geex was closed; recorded as an outside change (1 unsaved hunk(s)
  took disk)`. Line 2 showed the disk text with no author; a `gap` entry was appended; `Alt+Z` brought
  back the unsaved `byeta`.
- **Hard crash.** Typed `CRASH-`, then `kill -9` on the BEAM. The ledger held every keystroke (last entry
  the `-`), no `close`; the lock file and the discovery file were left behind. Relaunch: `restored unsaved
  changes…`, `CRASH-xalpha` back, the stale lock taken over by the new pid and released on quit. (I
  removed the dead instance's leftover discovery file by hand.)

**Automated:** `ledger_test`, 18 tests:
- every entry type round-trips, with every actor kind, a reconcile stamp, an origin and non-UTF-8 bytes;
- other versions, unknown types and garbage are rejected;
- **reopen:** a clean close restores history, blame and undo across sessions; unsaved edits survive a
  crash with a notice; **a crash right after an agent reconcile into a clean buffer finds no gap** (the
  coordinator's case); a closed-file change becomes an `:external` gap (and a second reopen adds
  nothing); a closed-file change merges with unsaved edits; **CRLF + BOM + no final newline rejoins
  with no gap**; group ids continue across a reopen;
- **damage:** a torn last line is dropped and cut off; a corrupt middle line stops replay there, with
  the original kept aside; a tampered `sync` hash stops at the last verified point;
- **file and lock:** nothing is written for a buffer that never changes; `0600`/`0700`; a second buffer
  on the same file doesn't record and says so; a stale lock is taken over; a rename moves the ledger;
- **ADR-0033 §3, pinned:** after 150 seeded random edits, undos, redos, outside writes, credits and saves
  through the real buffer, restoring the ledger gives exactly the live `History` value.

`history_test` gained the group-id tests. **772 tests + 19 doctests**, green twice,
`--warnings-as-errors` clean.

**Not tested:** fsync timing (the timer path ran live, not under test); a power loss; a disk-full write
error (the code turns the ledger off with a notice); very long ledgers (replay is synchronous in the
buffer's init); two geex *processes* racing for one lock (tested within one VM); macOS.

### 2026-10-15 — Durable ledger build step 2b: the spool, plus two crash cleanups (ADR-0033 F)

`geex-attest.sh` now notices whether any geex took the attestation. When none did (no geex running, or
every answer `not_open`) and geex keeps a ledger for the file, it appends the attestation plus an `at` time
to `<ledger dir>/<key>.spool.jsonl` (`0600`, last 256 lines). On reopen, `Geex.Ledger.Spool.chain/3` credits
a gap when one entry, or an exactly linked same-session chain, takes the replayed synced hash to the disk
hash. The spool is then discarded. Also: a ledger left without a `close` (a crash) is verified with one
on reopen, and `Geex.Attest.Discovery` sweeps discovery files of dead pids on start.

**Live-verified** with the real registered hook and the real `~/.local/state/geex/ledger/` (scratch file;
its ledger removed afterwards):
- geex opened the file, `0` + `Ctrl-O`, quit: ledger `b29afff362fca901.jsonl`, the same key the payload
  computes with `sha256sum`.
- **geex closed** (no instance running). This session's native `Edit` of line 2: the payload wrote one
  spool line (session `d25a8b6d`, its `tool_use`, `at`). Reopen: line 2 marked, `✎ claude-code/d25a8b6d ·
  turn 4764…`, the spool gone; the ledger's `gap` entry carried the agent actor and `chain: [toolu_…]`.
- **A chain.** Quit, then two native `Edit`s (lines 3, then 1): two spool lines. Reopen, before any key:
  `the file changed while geex was closed; credited to claude-code/d25a8b6d (2 edits)`, lines 1–3 all
  marked.

**Automated:** `ledger_test` +5: reopening after a crash writes a verifying `close`; one spooled write is
credited (actor with turn and tool_use, `chain`, spool removed, the credit survives another reopen); a
same-session chain with an unrelated entry in between is credited with the last write's ids; a
two-session chain and a missing link stay `:external`; a CRLF file's single write matches through the
`\r\n`-as-`\n` before. `Spool.chain/3` doctest. `attest_payload_test` +4: spooled (`0600`) when no geex
runs and a ledger exists; nothing without a ledger; no spool when a geex answered `pending`, a spool when
the only geex answered `not_open`; **end to end:** the real payload spools while the file is closed and a
real buffer reopening it credits the gap with the fixture's session/prompt/tool-use ids. `attest_test` +1:
a dead pid's discovery file is swept on start, a live one kept. **782 tests + 20 doctests**, green twice,
`--warnings-as-errors` clean.

**Not tested:** the 256-line cap (one `tail`), two hooks appending to one spool at once, a CRLF chain
(stays `:external` by design), `XDG_STATE_HOME` set in geex but not passed to the hook (they would look
in different places), and NotebookEdit through the spool.

### 2026-10-15 — Durable ledger build step 3: per-agent revert (ADR-0033 §7)

`Geex.Revert.plan/3` (pure) takes back the change that last wrote the cursor's line, one hunk (`revert`) or
its whole tool call (`revert-call`), by three-way merging its undo into the current text over the replayed
after-state (`Merge.plan/3`). It is refused, with the lines named, when a later change overlaps. Applied by
`Buffer.revert/3` as a group of `:human` replaces carrying `meta.reverts` (ledger round-trip). Typed verbs
and palette entries; status-line notices; `Alt+U` reverts the hunk under the cursor (the maintainer's pick;
`Alt+R` is the line-start motion).

**Live-verified** (geex TUI in a tmux pty, isolated `XDG_STATE_HOME`). One native `Edit` from this session
changed lines 2 and 4 in one tool call (two hunks, both marked); then `my-` typed on line 1.
- `Alt+M` `revert` on line 4: line 4 back to `four` and unmarked, line 2 still the agent's, `my-one` kept;
  notice `reverted claude-code/d25a8b6d's change (1 hunk)`.
- `Alt+Z` undid the revert (line 4 the agent's again); `x` typed on line 4; `revert-call` from line 2:
  refused, `can't revert: line 4 changed …`, nothing changed. (Its wording was then fixed from "… wrote
  them" to "… changed after claude-code/d25a8b6d's edit".)
- `revert` on line 2 (its hunk alone): reverted.
- The ledger's two revert groups carry `"actor":"human","reverts":{"group":1,"scope":"hunk"}`.
- After binding the key: `Alt+U` on a fresh agent line reverted it (`reverted claude-code/d25a8b6d's change
  (1 hunk)`), and `Alt+Z` brought the agent's line and its mark back.

**Automated:** `revert_test`, 13 tests: revert-call takes back both hunks and keeps your later edit
(commands `:human` with `reverts`, no agent mark left); one hunk only; your edit on the agent's line refuses
the call and names it (exactly `{4, 4}`; two adjacent edits read as `{1, 2}`) while the other hunk alone
still goes; lines shifted by a later insert map to the right hunk; a later agent change on an adjacent line
doesn't block; loaded and human lines are `:not_a_change`; a deletion comes back with revert-call; an
`:external` change reverts too; the verbs parse; through the buffer, undo restores the agent's change and
mark, a refused revert changes nothing, and the revert's provenance survives the ledger (restore == live).
Plus a keymap test (`Alt+U` → revert; `Alt+R` still line start). **796 tests + 20 doctests**, green twice,
`--warnings-as-errors` clean.

**Not tested:** reverting a group that was partly undone; reverting across a ledger gap; MCP `{:llm, _}`
edits (not reconcile groups, so not revertible); `:already_reverted` (defensive, hard to reach from a
marked line).

### 2026-10-15 — Independent live check of step 2b (the coordinator session)

The captAInHook coordinator (session `7ccbf3d1`) checked `05cecdd` from its own session in the real
`~/.local/state`, with `XDG_STATE_HOME` unset. A single native `Edit` to a closed file was credited on
reopen (`credited to claude-code/7ccbf3d1 (1 edit)`, mark, turn on the status line, spool consumed). Three
`Edit`s sent in parallel in one assistant message spooled in a correctly linked order and were credited as
`(3 edits)`, all three lines marked. An agent `Edit` followed by a shell `>>` append broke the chain: the gap
was recorded as an outside change, both lines unmarked, and the leftover spool entry dropped. A lock was
never left behind by a clean `Ctrl-X` (checked after each clean quit). Its scratch ledgers were removed
afterwards.

### 2026-10-15 — Input: special keys no longer type escape-sequence junk into the buffer

**Bug** (found by the coordinator session while checking step 3): `Geex.Input.Parser` recognised only the
four arrow CSIs. Any other escape sequence fell to "ESC + unknown byte": the ESC became `{:key, :esc}` and
the rest was inserted as text. Pressing End in tmux typed `[4~` into the file; Delete typed `[3~`, Page
Up/Down `[5~`/`[6~`, Ctrl+Right `[1;5C`, and F1 (`ESC O P`) fired Alt+O and typed `P`. Confirmed by
parsing each sequence before the fix.

**Fix:** a control sequence is read as one unit: a CSI (`ESC [`, parameter bytes `0x30–0x3F`, intermediates
`0x20–0x2F`, final `0x40–0x7E`) or an SS3 (`ESC O` + one byte). Arrows, Home (`ESC [ H`, `1~`, `7~`, `ESC O
H`), End (`ESC [ F`, `4~`, `8~`, `ESC O F`) and Delete (`3~`) map to keys; every other sequence is dropped.
An incomplete one stays leftover (at most 32 bytes); a byte outside the CSI ranges means it wasn't a
sequence, and the rest is re-read. The keymap gained Home / End (line start / end, as Alt+R / Alt+F) and
Delete (the grapheme under the cursor; at a line's end, join the next line).

**Live-verified** (TUI in a tmux pty, keys sent by name): End → `1:12`, Home → `1:1`, Delete removed the
`h`; then Page Up, Page Down, Ctrl+Right, Shift+Up, F1, F5 and Insert changed nothing; End then Delete
joined line 2 onto line 1.

**Automated:** `parser_test` +7 (the three forms of Home/End and Delete, SS3 arrows; ten unsupported
sequences dropped; text around a dropped sequence; an incomplete sequence across chunks; unbounded garbage
dropped; `ESC [` + a control byte re-read; a lone `ESC O` is Alt+Shift+O). `keymap_test` +4 (Home/End;
Delete mid-line, at a line's end, at the buffer's end). **807 tests + 20 doctests**, green twice,
`--warnings-as-errors` clean.

**Not handled yet (dropped, by choice):** Page Up/Down, modified arrows (Ctrl/Shift), F-keys, Insert. Home,
End and Delete do nothing in the minibuffer (it ignores keys it doesn't know). Alt + a non-letter
(`ESC 1`) still emits ESC and types the character, as before.

### 2026-10-15 — Input: a leftover Esc is delivered after 40 ms (fixes a regression in `ebeca5a`)

**Regression** (found by the coordinator session the same hour): a bare Esc stays leftover until the next
chunk. With whole-CSI parsing, Esc then `[` then `a`, typed as separate keystrokes, built `ESC [ a`, a
complete CSI that was dropped, losing all three. Before `ebeca5a` they arrived as Esc, `[`, `a`. Reproduced
by parsing the three chunks in sequence.

**Fix:** `Geex.TerminalIO` starts a 40 ms timer whenever a read leaves leftover bytes. Any new bytes make it
stale. If nothing followed, the bytes were typed by a person, not sent as one sequence (a terminal writes a
whole sequence at once), so `Geex.Input.Parser.flush/1` delivers them: each ESC as the Esc key, the rest as
ordinary input. This also ends the old lag where a bare Esc waited for your next key.

**Live-verified** (TUI in a tmux pty, keys 200 ms apart): Esc, `[`, `a` typed `[a`; Esc alone closed the
open minibuffer with no further key; End still moved to the line's end.

**Automated:** `parser_test` +3 and 2 doctests (`flush/1`: bare Esc, `ESC [`, an incomplete CSI, two Escs,
and Esc / `[` / `a` as separate chunks). **810 tests + 22 doctests**, green twice, `--warnings-as-errors`
clean.

**Not tested:** the timer under a slow or remote terminal (an SSH link that splits a sequence across more
than 40 ms would now type its tail; raising `@esc_timeout_ms` is the knob).

### 2026-10-15 — Durable ledger build step 4: `mix geex.ledger list | forget | compact` (ADR-0033 §6)

`Geex.Ledger.Compact` rewrites a ledger as a `checkpoint` plus its last N commands (with a `sync` or
baseline entry and a `close`), checked by replaying it against the original before it replaces the file.
`Geex.History` gained `base_blame` / `from_checkpoint/4` so undo after a compaction keeps the checkpoint's
credits. `Geex.Ledger.list/1`, `forget/1`, `compact/2` and the `mix geex.ledger` task. Fix found by the new
`list` test: a rename before the buffer's first write in a session now records the rename in the ledger.

**Live-verified** (geex TUI in a tmux pty, `XDG_STATE_HOME` pointed at a scratch dir, the real `mix
geex.ledger`): typed and saved, then this session's native `Edit` of line 3 (credited), then unsaved
typing.
- With geex open: `list` showed the file with `23 entries, 5.7 KB … [open]`; `compact` was refused: `a
  running geex has this file open (180501 <0.557.0>); close it first`.
- After quitting: `compact --keep 3` gave `5.9 KB -> 1.6 KB; kept the last 3 command(s), folded 18 into the
  checkpoint`; `list` then showed 6 entries.
- Reopen: `restored unsaved changes from your last session`, the text exact, line 3's `▌` and `✎
  claude-code/d25a8b6d · turn 381b…` intact. Five `Alt+Z` undid only the 3 kept keystrokes (`unsaved ` →
  `unsav`) and stopped at the checkpoint, the agent line still credited.
- `forget` without `--yes` only said what it would delete; with `--yes` it removed the ledger; `list` then
  said `no ledgers`.

**Automated:** `ledger_admin_test`, 8 tests: compaction keeps text, blame, synced text and unsaved edits,
writes a checkpoint first line, shrinks the file, and undo stops at the checkpoint with the agent's credit
kept; `--keep 0`, then group ids continue (2 after 1); compacting twice, and recording after a compaction;
`compact` and `forget` refused while a buffer has the file open; a misplaced checkpoint stops replay;
`forget` removes the ledger, spool and set-aside copies; `list` follows a rename and shows `open`,
`spooled 1`, `orphan` (cleared once the file exists); the mix task end to end (list, compact, forget dry
run and `--yes`). `ledger_test`'s round-trip gained two checkpoint entries. **818 tests + 22 doctests**,
green twice, `--warnings-as-errors` clean.

**Not tested:** compacting a ledger whose replay had stopped early (a copy is set aside first); very large
ledgers (compaction replays the whole history once); `--dir` with a key from another directory.

### 2026-10-15 — Holding open buffers, build step 1: fast-forward and save-while-behind (ADR-0034)

An open buffer no longer changes when its file does. The watcher calls `Geex.Buffer.disk_changed/2`, which
marks the buffer behind (`behind disk (Alt+L)` on the status line) or clears the mark. `Alt+L` /
`fast-forward` (`Geex.Reconcile.fast_forward/1`) takes the change in. `Ctrl-O` (`Geex.Reconcile.save/2`)
fast-forwards a buffer that is behind before it writes, and `Buffer.save/1` itself refuses (`:behind`) to
write over a changed disk. A dirty buffer merges with `git merge-file` (`Geex.Edit.GitMerge`): a conflict is
git's `<<<<<<< buffer` … `>>>>>>> disk` block in the buffer, and a save with conflicts doesn't write; a
block left in the buffer refuses `Ctrl-O` until it is pressed twice in a row. Attestations for writes not
taken in yet are answered `held` (the payload then spools them too) and credited at the fast-forward by the
spool chain rule; the 10 s pending table is gone.

**Live-verified** (geex TUI in a tmux pty, `XDG_STATE_HOME` pointed at a scratch dir, the live captAInHook
hook attesting this session's native `Edit` calls):
- an `Edit` of line 3 while geex had the file open: the buffer kept `three`, the status line said `behind
  disk (Alt+L)`, the intake logged `held`; `Alt+L` brought in `THREE (agent, held)` with its `▌` mark and
  `✎ claude-code/d25a8b6d · turn b60e…`;
- typed `MINE ` on line 1 (unsaved), then an `Edit` of line 5: `[+]  behind disk`; `Ctrl-O` merged and
  wrote both, line 5 credited;
- typed ` (mine)` on line 2, then an `Edit` of the same line: `Ctrl-O` put git's block in the buffer with
  `1 conflict with the disk: resolve the marked block, then save`, and the disk kept the agent's version;
  the next `Ctrl-O` said `not saved: a conflict block is left at line 2 (Ctrl-O again saves anyway)`; after
  an arrow key, `Ctrl-O` refused again; two in a row wrote the file with the block;
- a `printf` over the file (no attestation): `Alt+L` said `caught up with the disk`, again `already up to
  date with the disk`; `Alt+Z` gave back the previous text, dirty and not behind.
- `/tmp/geex.log` had no warnings; nothing was written to the real `~/.local/state/geex/ledger`.

**Automated:** `hold_test` (17): behind/in-sync and its notification; fast-forward of a clean buffer as one
undoable group; up to date, and a stale mark cleared; a dirty buffer's clean merge and its conflict block
with the notice; credit for a held write, a same-session chain (`chain: ["u1","u2"]`) and a mixed-session
one (`:external`); a write both held and spooled links once; a spool line landing after the fast-forward
can't link later; a crash while holding credits the write on reopen; a late attestation still upgrades;
`Buffer.save/1` refuses an unreported disk change; save-while-behind clean, merged, conflicting, the marker
refusal and `force`, and a resolved block; `Alt+L` / the verb / the palette entry. `git_merge_test` (6 + a
doctest): clean, a labelled conflict counted, a missing final newline, CRLF blocks, a binary file's error,
no temp files left. `attest_payload_test` +1: the real payload against a held buffer spools the
attestation, and a crash before the fast-forward keeps the credit. `reconcile_test`, `attest_test`,
`blame_test`, `session_test` updated (`held` for `pending`, git blocks for disk-wins, the watcher marks
behind) plus the no-git fallback (`:git_executable` set to a missing binary: disk wins, one undo away).
**844 tests + 23 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** the no-git fallback live (only through the app-env seam); a file deleted while open (left
as is, not behind, as before); two geex instances holding the same file; the frozen MCP `save_file` on a
buffer that is behind (returns the `:behind` error; only reasoned from `Buffer.save/1`); very large files
(each save now reads the file once to compare).

### 2026-10-15 — Fix: a round trip no longer blocks the next session's credit (ADR-0033 F amendment)

Found by the coordinator session's live test of `b764891` (7 of 7 checks passed). After session X wrote a
line and wrote it back while the buffer was held, session Y's next write fast-forwarded as `:external`. Root
cause: `Spool.chain/3` walked one chain; X's round trip linked first and left the walk at X, so Y's entry
(whose `before` was the last known content) failed the same-session test and nothing restarted. The same
failure existed on reopen (ADR-0033). The chain search now keeps the longest chain ending at each
(content, session) and starts one at any entry whose `before` is the last known content. A no-op write
(`before == sha256`) is skipped.

**Live-verified** (geex TUI in a tmux pty, scratch `XDG_STATE_HOME`): this session's native `Edit` changed
line 2 and changed it back (two `held`), then a `printf` changed line 3 and a hand-made attestation for it
from session `ffffffff-…` was POSTed to the intake (`{"status":"held"}`). `Alt+L` said `caught up with the
disk (claude-code/ffffffff)`, `▌` on line 3. Before the fix the coordinator saw `:external` here.

**Automated:** `hold_test` +1 (the held round trip, then another session's write), `ledger_test` +3 (the
same on reopen; `Spool.chain/3` directly: a restart, the round trip continued by the same session as one
longer chain, mixed sessions never linking, time order, a skipped no-op, duplicates linking once). The new
tests fail on the old walk (4 failures). **848 tests + 23 doctests**, green twice, `--warnings-as-errors`
clean.

**Not tested:** a very long spool of interleaved sessions (bounded by entries, not measured).

### 2026-10-15 — More than one buffer, build step 2 (ADR-0034)

`open PATH`, a `buffers` picker and `close`, as typed verbs and palette entries. `Geex.Session` keeps the
buffers that have been active (most recent first, monitored) and each one's cursor; `Geex.Loop` keeps each
one's scroll. `close` (`Session.close_active/0`) refuses unsaved edits and falls back to the previous buffer,
or a new scratch buffer. `Geex.run/1` takes a list of paths or a directory. `Geex.Layout`, panes and `Alt+O`
moved to step 3 (the edits pane is their first consumer).

**Live-verified** (geex TUI in a tmux pty, scratch `XDG_STATE_HOME`, `Geex.run([a.txt, b.txt])`): `a.txt`
shown first. The first try showed a bug: `buffers` typed in the minibuffer opened the picker and the
submit's close shut it, so the following Enter typed a newline into `a.txt`. Fixed (close, then act); then
`buffers` listed `a.txt [+]` and `b.txt` with paths, and Enter went to `b.txt`. Back to `a.txt` via the
picker: the cursor was at `3:12` where it had been left. `open sub/c.txt` (relative to `a.txt`'s directory)
opened a new empty buffer; `close` with typing in it said `not closed: unsaved changes (save them, or undo
them, first)`; after `Ctrl-O`, `close` said `closed c.txt`, showed `a.txt` at `3:12`, and `sub/c.txt` held
the text on disk. `open sub` said `sub is a directory`. The palette filtered by `buf` listed `buffers`
first, and Enter on it opened the picker (the palette's action path had the same close-after-act order,
also fixed); `c.txt` was no longer listed. Incidentally, quitting with the stray newline unsaved and
relaunching brought it back as `restored unsaved changes from your last session` (ADR-0033), as designed.

**Automated:** `buffers_test` (7): the recent list follows switches; a cursor per buffer; `close_active/0`
refuses a dirty buffer, then goes back to the previous one; closing the last leaves a scratch buffer; a
buffer that ends drops out of the list; `open PATH` keeps its case (`buffers`, `close`, `line 3` still
parse); the palette entries. `reconcile_test`'s quiet-period test widened from 40 to 150 ms after one
loaded full-suite run fired the timer before the "nothing read yet" check (a pre-existing race).
**855 tests + 23 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** the loop's picker and the submit order (no automated test drives the loop process; only
the dogfood above); per-buffer scroll (live only, no tall file); `Geex.run/1` with a directory (reasoned:
it opens a scratch buffer); many open buffers (the picker shows 8 rows and scrolls, as the palette does).

### 2026-10-15 — The edits pane, build step 3 (ADR-0034)

`Geex.Edits`: an in-memory list (500 rows) of agent writes (every attestation the intake gets, open
file or not), disk changes to open files (when the watcher marks a buffer behind) and your saves. A
change and its attestation are one row, joined by `{path, sha256}`. `Geex.Layout` puts the pane under
the editor. "Disk is newer" rows are read from `Geex.Buffer.status/1` at each repaint. `Alt+O` moves in
and out, the `edits` verb shows or hides it. The root (`Geex.Session.set_start/1`, the git top level of
the first path given) scopes the pane, and is the base for a relative `open` from a pathless buffer.
That fixes the coordinator's step-2 finding (`geex DIR` then `open a.txt` opened `~/geex/a.txt`).

**Live-verified** (geex TUI in a tmux pty, 90×24, scratch `XDG_STATE_HOME`; the live hook attesting this
session's native `Edit` calls):
- `Geex.run([a.txt, b.txt])`: the pane showed `no edits yet` under the editor.
- An `Edit` of `b.txt` (open, not shown) and a `printf` over `a.txt` (shown): the pane listed `a.txt
  disk is newer`, `b.txt disk is newer`, `a.txt outside`, `b.txt claude-code/d25a8b6d`, all `16:05`
  (local time); the status line said `behind disk (Alt+L)`.
- `Alt+O` (title switched to `Enter opens · Esc back`), Down, Enter on `b.txt disk is newer`: `b.txt`
  shown, fast-forwarded, `caught up with the disk (claude-code/d25a8b6d)`, `▌` on line 2, its pinned
  row gone, focus back in the editor.
- Enter on the agent's `b.txt` row put the cursor on the line that write changed (`2:1`). Typing and
  `Ctrl-O` added `b.txt you`. The `edits` verb hid the pane; `Alt+O` then said `no other pane: the
  edits pane is hidden`.
- After a restart with `Geex.run(multi/)`: `open a.txt` opened `multi/a.txt`, with no stray
  `~/geex/a.txt`. An `Edit` of `b.txt` while it wasn't open listed `b.txt claude-code/d25a8b6d`, and an
  `Edit` of a file outside the root wasn't listed. Enter on the `b.txt` row opened it.
- One adjustment from the run: the highlight kept its old position when re-entering the pane; `Alt+O`
  now starts at the newest entry.
- `/tmp/geex.log` had no warnings; nothing new in the real `~/.local/state/geex/ledger`.

**Automated:** `edits_test` (8 + `Geex.Layout` and `Geex.Loop.EditsPane` doctests): rows newest first
with a notification; a disk change an attestation explains adds nothing; an outside row becomes the
agent's, and a repeat adds nothing; another change to the same file is its own row; the bound; the
pane's entries (pinned first, root-scoped, everything without a root); rows scroll to the selection
and cut long names; the layout drops the band in a short terminal. `buffers_test` +1
(`set_start/1`: a named directory, a file's directory, this checkout's top level) and the `edits` verb
and palette entry; `keymap_test`: `Alt+O` is `:next_pane` now (no longer an ignored letter).
**865 tests + 27 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** the pane's drawing and its keys (no automated test drives the loop process; only the
run above); the scroll of a list longer than the pane; a resize below 12 rows with the pane focused
(reasoned: keys and the hardware cursor go back to the editor while the pane is gone).

### 2026-10-15 — The file tree, build step 4 (ADR-0034)

`Geex.Tree`: the root's files from `git ls-files --cached --others --exclude-standard` (less those
deleted from disk), or a walk outside a repository (dot-directories and symlinks skipped), at most
10,000; `rows/2` turns them and the opened directories into rows. `Geex.Layout` gains the left column
(a quarter of the width, 20–36 columns, none below 60; shown at start from 100 columns), the editor
renders at its own width and moves over (`Geex.Screen.translate_x/2`), and `Alt+O` cycles tree ·
editor · edits. `tree` toggles it. Also fixed: `Geex.Attest.Discovery`'s start-up sweep logged an
"unexpected message" error for each `kill -0` port's exit when stale discovery files existed
(pre-existing; surfaced in this run's log). And a step-3 crash found by the coordinator's live test
of `8e041a6`: `Alt+M` / `Alt+P` with the edits pane focused hit `apply_action/4`, which has no clause
for the openers (`CaseClauseError`); the loop restarted, losing focus, scrolls and the selection.
The tree pane had copied the pattern. Both panels now share one helper (`panel_chord/2`) that opens
them as the editor's keys do.

**Live-verified** (geex TUI in a tmux pty, 120×30, scratch `XDG_STATE_HOME`, `Geex.run("~/geex/mix.exs")`,
navigation only): the tree listed `.claude/ config/ doc/ integrations/ lib/ presets/ priv/ test/` then
`.gitignore CLAUDE.md mix.exs mix.lock` (what git tracks), a `│` divider, the editor beside it with its
scroll bar at the right edge, and the edits pane under the editor only. `Alt+O` twice went editor →
edits → tree (title showed `Enter`); Down ×4 and Enter opened `lib/` (`▾ lib/` with `geex/`, `mix/`,
`geex.ex`); Down ×3 and Enter opened `lib/geex.ex` in the editor, focus back there. `tree` hid it (the
editor took the full width); `Alt+O` ×2 then went editor → edits → editor; `tree` again showed it with
`lib/` still open. Nothing was typed or saved. The log's one error line was the Discovery one above
(every geex logs to the same `/tmp/geex.log`; the coordinator's live geex was running alongside).

**Automated:** `tree_test` (6 + a doctest): the walk skips dot-directories; in a real `git init` work
tree, tracked + untracked, not ignored, not deleted; rows (directories first, an open directory under a
closed one stays hidden); the layout's column bounds; `Screen.translate_x/2`; the `tree` verb and palette
entry. `attest_test`'s sweep test now captures the log and refutes "unexpected message" (fails without
the fix). `loop/panes_test` (6), the first tests that drive the loop's `handle_info/2` (from a state
built by the new `Geex.Loop.new_state/2`, no terminal): `Alt+M` / `Alt+P` open the minibuffer and the
palette from the edits pane and from the tree (with the old routing put back, 2 fail with the
coordinator's `CaseClauseError`); other keys don't reach a buffer, Esc goes back; `Alt+O` cycles
editor → edits → tree → editor; Enter opens a directory. **877 tests + 28 doctests**, green twice,
`--warnings-as-errors` clean.

**Not tested:** the tree's drawing and keys beyond the run above (Right/Left, a list longer than the
pane); a repository with 10,000+ files (the cap is unit-reasoned, not measured); the walk's cap.

### 2026-10-15 — "Edited by you", build step 5 (ADR-0034 §8)

When you edit an agent's proposed change in Claude Code's permission prompt before accepting it, its
`tool_response.userModified` is `true`. The payload now sends `"user_modified": true` then (nothing
otherwise: every other message is byte-identical). The intake reads it as an optional boolean.
`Geex.Attest.who/1` builds the agent actor for the buffer, the edits list and the spool's chain, adding
`user_modified: true` only when set; the ledger codec keeps the key. The status line and the edits pane
say "edited by you". This is the last step: all of ADR-0034 is built.

**Live-verified** (geex TUI in a tmux pty, 100×24, scratch `XDG_STATE_HOME`): a `printf` changed line
2 of the open file, then a hand-made attestation with `"user_modified": true` was POSTed to every
running geex (this one answered `held`, the coordinator's `not_open`). The edits pane listed `hold.txt
claude-code/d25a8b6d, edited by you`; after `Alt+L` the line had its `▌` and the status line read `✎
claude-code/d25a8b6d · turn turn… · edited by you`. The tree beside it was a walk of the scratch
directory (not a repository). Before that, the edited payload script passed `sh -n` and the full
payload suite (the message unchanged when the flag is false), and the coordinator was told before the
live script changed.

**Automated:** `edited_by_you_test` (5): the intake's `user_modified` (true, false, absent, refused
otherwise); the actor keeps it through a held fast-forward, and an unedited write's actor has no such key;
a chain is marked if any write was edited; a reopen keeps it (the ledger); the status-line label and the
edits-pane row. `attest_payload_test` +1 (a real envelope with `userModified: true` sends
`user_modified`); `Geex.Attest.who/1` doctest. **883 tests + 29 doctests**, green twice,
`--warnings-as-errors` clean.

Also from the coordinator's live test of `ea6ec63` (the tree: all checks passed, including Right/Left,
a list longer than the pane, files added while unfocused, ignored and deleted files hidden, 59/60/120
columns, and the `Alt+M` / `Alt+P` fix): Left on a file now goes up to its directory (`panes_test`).
Its "first row never highlighted" report was checked here: with the editor's cursor on line 1, `tmux
capture-pane -e` showed the tree's row 0 with no background code, because it equals the end of the line
above (the editor's current-line tint) and tmux omits it; with the cursor on line 3 the row's
`48;2;49;35;33` is emitted. Not a bug. **883 tests + 29 doctests** after it.

**Not tested:** a real `userModified: true` from Claude Code's permission prompt (this session runs
without prompts; the captured fixtures all say `false`).

### 2026-10-16 — The tree: no cap, read in the background (ADR-0034 amendment)

The coordinator's live test of `a64fb05` passed (a 10,000-file repository listed in about a second,
Left to the parent, the walk outside a repository) and found that the 10,000-file cap cut the list
without saying so, on the git path too. The maintainer chose no cap. Measured first: geex opened in the
home directory (937,594 files, not a repository) froze the loop for 60 s cold, 18 s warm, at launch and
whenever the tree took focus, and each directory open or close took 14 s. Now the tree is read in a
monitored process of its own, in parallel inside it, and the rows come from an index built there.

**Live-verified** (geex TUI in a tmux pty, 140×40, scratch `XDG_STATE_HOME`), `Geex.run("/home/oof")`:
the tree said "reading…" and keys typed 0.8 s after launch landed in the scratch buffer; the tree filled
at 17 s. `Alt+O` into the tree (which starts a re-read; the rows stayed), down to `captAInHook/`, Enter:
it opened in about 60 ms and closed in about 60 ms (the polling's granularity is 50 ms). After the re-read
landed, the open directory and the selection were still there. RSS about 500 MB. No warnings or errors
in the log. Then `mix.exs` in the geex repository: the tree showed 0.8 s after launch.

**Measured** (`mix run`, warm cache, 8 schedulers): the walk 8.0 s in parallel (18.0 s one directory at a
time; 32 or 64 at once were no faster), sort 1.5 s, `Tree.index/1` 4.1 s in parallel (8.5 s in one process).

**Automated:** `tree_test` +1: 11,000 files, all listed by the walk and by git, and indexed;
`Tree.index/1` doctest; the rows tests now go through the index. `panes_test` +2: the loop doesn't wait
(the reader is recorded, no rows yet), a second focus starts no second read, an answer from another
process changes nothing, the answer brings the index; a reader that dies first gives the notice and an
empty index (so no re-read on the next frame). The pane tests deliver the reader's answer. **886 tests + 30
doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** a reader that really crashes (the test hands the loop a `DOWN` from a process that
exits `:boom`); a root too big for memory; the reader outliving a crashed loop (it finishes, and its
answer goes nowhere).

### 2026-10-16 — The coordinator's live check of `6a6e3df`; slow work measured for ADR-0035

**Live-verified by the coordinator session** (from this session's clean tree): it passed.
- **A 100,000-file git repository** (200 directories × 500 files, committed): the editor was up 0.77 s
  after launch; the tree said "reading…", then showed rows about 1 s after launch. `Alt+O` into the
  tree started a re-read; Down Down Enter sent during it opened `d002/`, and the selection stayed on it.
- **The home directory** (not a repository, warm cache): keys were live at once, and typing in the
  scratch buffer during the read worked. With the tree focused and still "reading…" (no rows), Down,
  Enter, Right, Left and Up did nothing, and nothing crashed. The tree filled about 10 s after launch.
  Refocusing started a re-read; during it the old rows, the open folders and the selection stayed, and
  navigation worked; all three were still there when the re-read landed. `Ctrl-X` exited cleanly (the
  BEAM gone within about 2 s). RSS about 0.9 GB there (about 500 MB in this session's run).

**Measured** for [ADR-0035](adr/0035-the-loop-never-waits.md) (`MIX_ENV=test mix run`, a scratch
directory, real `git merge-file`; nothing in the repository): a clean merge and save 93 ms on a 1 MB file
and 759 ms on 10 MB; a fast-forward 29 ms and 445 ms; opening a 1 MB file 5 ms, 10 MB 27 ms; reopening a
file with a ledger of 1,000 entries 9 ms, 10,000 entries 137 ms. Read from the code, not timed: opening
runs no git (`git rev-parse` runs once, from `Session.set_start/1`), and reconcile handles disk changes
in its own process, one file at a time.

No code changed; still **886 tests + 30 doctests**.

### 2026-10-16 — Fix: a highlighted buffer's reactor crashed on the buffer's other notices

Found live by the coordinator session in the maintainer's geex: with `lib/geex/ansi.ex` open, an agent
`Edit` made it go behind, and the log showed `Geex.Highlight.Reactor` terminating with a
`FunctionClauseError` on `{:geex_buffer_behind, …}`. The reactor subscribes to its buffer for
`{:geex_buffer_change, …}` and so receives everything the buffer sends its subscribers:
`:geex_buffer_behind` (since `b764891`), `:geex_buffer_attested` (since `a56cb85`, 2026-10-14) and
`:geex_buffer_notice` (since `36766ed`, 2026-10-14, also sent at subscribe when the buffer opened with a
notice). It had no clause for any of them. It is `:temporary`, so the file stayed uncoloured until it was
reopened (the loop paints no highlights when the reactor is gone; no loop crash). Every hold test and
live run since used `.txt` files, which have no grammar and so no reactor. Fixed with a catch-all
`handle_info/2` in the reactor, as the loop has.

**Live-verified** (geex TUI in a tmux pty, 100×24, scratch `XDG_STATE_HOME`; the maintainer's own geex
left running and the shared log not truncated): a scratch `hl.ex` showed 6 distinct foreground colours
on its 4 lines; a `printf` rewrote line 3 on disk, the status line read "behind disk (Alt+L)", and the
colours were still 6 after a keypress; after `Alt+L` ("caught up with the disk") line 3 read `x + 2` and
the colours were still 6. No `terminating` line from this instance (the two in the log are the
maintainer's, at 09:22).

**Automated:** `reactor_test` +2: a reactor sent `behind`, `attested` and `notice` messages still
highlights the next edit (a comment); a buffer on a real `.ex` file going behind through
`Buffer.disk_changed/2` leaves its reactor running. Both fail with the reported `FunctionClauseError`
without the fix. **888 tests + 30 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** the maintainer's running geex (it still has the old code; it needs a restart, since
reopening the buffer starts the old reactor again).


### 2026-10-16 — The installed binary: Burrito, `mix geex.deploy` (ADR-0036)

Built by the coordinator session at the maintainer's request. Several things changed during the
build because the live checks failed first:

- **Elixir's CLI evaluates the arguments.** Checked with plain `erl … -s elixir start_cli -extra
  foo.txt`: it evaluates `foo.txt`, and with no argument the VM halts right after boot. So the
  binary works inside `Application.start/2` and never returns from it.
- **`System.stop/0` skipped every `terminate/2` under the binary.** The first build quit with
  status 0 but left the alternate screen, the discovery file and a ledger lock. Hence `Geex.stop/0`
  and the orderly stop in `Geex.CLI`.
- **The terminal restore was racy.** After that change, one of two SIGTERM runs still left the
  alternate screen on: `:prim_tty.write/2` is asynchronous, and the halt beat it. Hence the
  synchronous restore in `TerminalIO.terminate/2`.
- **Pointing Burrito's `custom_erts` at the asdf Erlang wasn't used.** Its copy step deletes the
  matching NIF files in the source tree. Burrito's phases are cut down instead.

**Live-verified** on `burrito_out/geex_linux` `0.1.0+797edb8a.dirty` (22 MB), in tmux with scratch
`XDG_STATE_HOME`/`TMPDIR`. The maintainer's running geex instances were left alone.

- **CLI:**
  - `--version` prints `geex 0.1.0+797edb8a.dirty` and exits 0, in 1.6 s on the first run (unpack)
    and 0.24 s after.
  - `-h` prints usage and exits 0; `--frob` prints the error and usage and exits 2.
  - `maintenance directory` names the unpack directory.
- **The trap:** `geex trap.exs a.txt`, where `trap.exs` is `IO.puts("EVALUATED")`, opened both, and
  nothing was printed.
- **TUI:**
  - The Elixir file was coloured, so the NIF loads in the release. The VM's command line has
    `-Bd`.
  - Typing and `Ctrl-O` saved to disk.
  - Bare `geex` in a repo, and `geex repo` from its parent, both showed the tree over a scratch
    buffer.
  - `cd sub; geex n1.txt ../b.txt` opened both; `buffers` listed `sub/n1.txt` and `b.txt`.
  - A clean quit removes the ledger lock and writes the ledger, under the scratch state dir.
- **Quitting:**
  - Three `Ctrl-X` and three SIGTERM runs each exited 0 with the alternate screen off, the cursor
    shown, the discovery file removed and no `terminating`/`error` lines in the log.
  - `mix run` launch, through the new `Geex.stop/0`: `Ctrl-X` exited 0, the terminal was restored
    and the discovery file removed.
- **Attestation through the binary:**
  - With `new.txt` open, the coordinator's own `Edit` went through captAInHook's payload. The log
    said `held` and the status line said "behind disk (Alt+L)".
  - `Alt+L` read "caught up with the disk (claude-code/7ccbf3d1)", and the edits pane listed
    `new.txt claude-code/7ccbf3d1`.

**Found, not fixed:** Ctrl-C hard-kills geex, under `mix run` too ([BUG-3](bugs.md)).
`prim_tty`'s raw mode leaves `isig` on (`stty`: `ixon isig -icanon -echo`).

**Automated:** `cli_test` +8 tests and 5 doctests:
- `parse/1`: paths, `--` anywhere, version and help, unknown options;
- `standalone?/0` off under test;
- `Geex.stop/0` and SIGTERM send `:geex_quit` to a registered `Geex.CLI`;
- other signals are ignored.

**896 tests + 35 doctests**, `--warnings-as-errors` clean.

**Not tested:**
- the install itself (`mix geex.deploy`'s copy, link and rollback), which runs after this commit
  from a clean tree;
- a Mac or another Linux machine (the binary isn't portable, by design);
- `GEEX_SERVE=1` under the binary.

### 2026-10-16 — The first real install, and `mix geex.deploy` prunes old unpacks (ADR-0036)

`mix geex.deploy` was run from the clean tree at `4c31f8c`:
- It built and installed `geex 0.1.0+4c31f8cd` at `~/.local/share/geex/bin/geex`, with the link
  `~/.local/bin/geex`. Neither existed before.
- `which geex` resolves to the link, and `geex --version` prints the commit's version.
- `--no-build` reinstalled and kept `geex.prev`. `--rollback` swapped them and printed the
  version now installed.

**Found and fixed:** Burrito removes only versions that sort *older*, and semver ignores build
metadata. The earlier `0.1.0+797edb8a.dirty` unpack (89 MB) stayed after `0.1.0+4c31f8cd` ran.
`mix geex.deploy` now removes every `geex_erts-*` beside the new version's directory. Checked:
`--no-build` printed "removed the old unpack geex_erts-16.1_0.1.0+797edb8a.dirty", and only the
new version's directory remains. The ADR-0036 consequence that claimed Burrito cleans up was
corrected.

**Live-verified** with the installed `geex` from the PATH, in tmux with scratch
`XDG_STATE_HOME`/`TMPDIR`: `geex b.txt` in the scratch repo showed the tree and the file. `Ctrl-X`
exited 0 with the alternate screen off, the discovery file removed and no `terminating`/`error`
in the log.

### 2026-10-16 — Ctrl-C and the other tty keys reach geex (BUG-3)

`Geex.TerminalIO` runs `stty -isig -ixon` on the tty after `:prim_tty` takes it, and puts the
`stty -g` settings from before back in `terminate/2`. `stty` runs on the VM's stdin device
(`/proc/<pid>/fd/0`): a probe showed that a port's child can't open `/dev/tty` ("No such device
or address"), since it has no controlling terminal. The same probe confirmed BUG-3's flags.
After `:prim_tty.init/1`, the tty read `ixon isig -icanon -echo`; after the `stty`, `-ixon -isig`;
after the VM halted, the shell's `ixon isig icanon` were back.

**Live-verified** under `mix run` in tmux (`runhold.sh`, scratch `XDG_STATE_HOME`), with bash in
the pane as the job-control shell:
- While geex ran, `stty -F <pane tty> -a` read `-ixon -isig`.
- Ctrl-Z: the process stayed `Sl+`, not `T`, and the frame stayed up.
- Ctrl-\\: still running; nothing was inserted.
- Ctrl-S, then `Z`: the `Z` appeared at once, so the screen didn't freeze.
- Alt+M, then Ctrl-C in the minibuffer: exit 0. The alternate screen was off, the discovery file
  and the ledger lock were removed, and the shell had `ixon isig` back.
- `kill -STOP`: bash took the terminal back (`ixon isig` restored, geex a stopped job), so
  `kill -CONT` left geex stopped in the background, as the coordinator saw. `fg` continued it in
  the foreground with `-ixon -isig` set again (the SIGCONT path). Ctrl-Q from the editor then quit
  cleanly.
- The installed binary (`0.1.0+c686550f`, without this fix) has the tty on its VM's fd 0, as
  `mix run` does. Ctrl-X exited 0.

**Automated:** +3 tests.
- `parser_test`: bytes 0 and 28–31 parse as `{:ctrl, ?@ | ?\\ | ?] | ?^ | ?_}`, not text. Ctrl-Z
  and Ctrl-S parse as Ctrl keys.
- `panes_test`: Ctrl-X, Ctrl-Q and Ctrl-C quit from the editor, both panes and the minibuffer.
  The minibuffer took only Ctrl-X before.

**899 tests + 35 doctests**, green twice, `--warnings-as-errors` clean.

**Also in this commit:**
- the shipshape IO gate allows `cli.ex`'s prints, matching CLAUDE.md;
- `rel/vm.args.eex`, `Geex.run/1`'s doc and the dogfood skill no longer say Ctrl-C is a signal
  or that Ctrl-Q and Ctrl-C are flaky quit keys;
- ADR-0036's consequence notes the fix.

**Not tested:**
- the fix under the installed binary, which needs a deploy from a clean tree;
- Windows Terminal, where the maintainer runs geex;
- a terminal where `stty` fails: geex logs a warning and runs with the keys as before (the code
  path is a `with`/`else`, not exercised live).

### 2026-10-16 — `geex 0.1.0+f9e59088` deployed: BUG-3's fix under the installed binary

`mix geex.deploy` from the clean tree at `f9e5908` (899 tests + 35 doctests green twice just
before it). It installed `0.1.0+f9e59088`, kept `0.1.0+c686550f` as `geex.prev`, and removed the
old unpack `geex_erts-16.1_0.1.0+c686550f`. No binary geex was running.

**Live-verified** with `geex` from the PATH in tmux (`-L deploy`), with bash as the pane's shell
and scratch `XDG_STATE_HOME`/`TMPDIR`, in a scratch repo:
- `geex --version` printed the version and exited 0; `geex --frob` exited 2.
- `geex a.txt` showed the tree and the file. The VM had the tty on fd 0, and the tty read
  `-ixon -isig`. The discovery file existed.
- Ctrl-Z and Ctrl-\ left it running (`Sl+`). After Ctrl-S, typed `q` went in, and Ctrl-O wrote
  `qalpha` to disk.
- Ctrl-C exited 0 with the shell's `ixon isig` back and the discovery file gone.
- `geex <dir>`, bare `geex` in the repo, and `geex notes.txt` (holding `IO.puts("x")`, not
  printed) each opened as expected. Ctrl-X exited 0 with the cursor visible and the alternate
  screen off.
- `$TMPDIR/geex.log` had no `terminating` lines.

**The coordinator's check** of the same binary, in its own tmux session with scratch state:
- `-isig -ixon` while running; Ctrl-S didn't freeze.
- Resizes 120×30 → 160×40 → 100×25 redrew at each size; Alt+O twice drew the pane hints right.
- Ctrl-Q exited with the discovery file gone; no `terminating` in the log.
- **Edge case, not a regression:** after an outside `kill -STOP`, `kill %1` (SIGTERM, then
  SIGCONT) left geex stopped again. It resumes in the background and touches the tty (most
  likely `prim_tty`'s raw-mode reset on SIGCONT), so the terminal stops it with SIGTTOU or
  SIGTTIN. `fg` then finished the quit: exit, discovery file gone, the shell back on the main
  screen with `isig`/`ixon`. `0.1.0+c686550f` behaved the same. With Ctrl-Z now a key, only a
  SIGSTOP from outside gets geex there.

**Not tested:** Windows Terminal; `--rollback` this time (it was checked at the first install).

### 2026-10-17 — The pane and file keys (ADR-0037)

The maintainer's keymap, relayed by the coordinator: `Alt+P` next pane, `Alt+I` palette, `Alt+O`
open a file (the minibuffer with `open ` typed, until the fuzzy finder lands), `Alt+K` close,
`Alt+T` tree, `Alt+L` edits pane, `Alt+J` fast-forward. The pane chords work from the tree and the
edits pane, the tree takes `Alt+A`/`Alt+D` as Left/Right, and opening a file gives the editor the
keys.

**Live-verified** under `mix run` in tmux (120×30, scratch `XDG_STATE_HOME`, a scratch git repo
with `a.txt`, `notes.txt`, `sub/s.txt`):
- `Alt+P` went editor → edits → tree; the edits pane's header reads `Alt+P`, and the tree's
  `Enter` hint showed when focused.
- In the tree, `Alt+W`/`Alt+S` moved, `Alt+D` on `sub/` opened it (`▾ sub/`, `s.txt` under it),
  and `Alt+A` closed it.
- From the tree: `Alt+I` opened the palette, whose `open` entry names `Alt+O`; `Alt+O` showed
  `geex:open `. Typing `notes.txt` and Enter opened it, and the next key typed into it, so the
  editor had the keys.
- `Alt+K` (after `Alt+Z` undid the typing) said "closed notes.txt" and showed `a.txt`.
- `Alt+J` said "already up to date with the disk". After `a.txt` changed on disk, the status line
  read "behind disk (Alt+J)", and `Alt+J` caught up and showed the new line.
- `Alt+L` hid and showed the edits pane; `Alt+T` hid and showed the tree.
- Ctrl-X exited 0, with no errors in the log.

**Automated:** +6 tests: `keymap_test` (the seven keys, both cases), `panes_test` (`Alt+O`,
`Alt+T`, `Alt+L` and `Alt+P` from each pane; the tree's `Alt+A`/`Alt+D`; `Alt+O` then Enter
focuses the editor; `Alt+K` closes). The `Alt+O`/`Alt+P`/`Alt+L` tests moved to the new keys.

**904 tests + 35 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** Windows Terminal (where the maintainer runs geex); `Alt+K` on a buffer with
unsaved edits live (the refusal is the `close` verb's, unchanged and tested).

### 2026-10-17 — `Alt+O`, the fuzzy file finder (ADR-0028 amendment)

A `:files` minibuffer mode over the tree's file list, ranked by `Geex.Finder` (a file-name
match above any match across directories, then the shorter path), each query searched in a
monitored process that the next key kills. The list is packed into one binary so a search gets it
by reference. Enter before the answer (or before the read) waits and opens the top match.

**Measured** (`MIX_ENV=test mix run`, a million synthetic paths, 49 MB packed, 8 schedulers):
pack 150 ms; a query 208–303 ms; the first 100 of a blank query 12 µs; spawning a process that
holds the list 1 µs.

**Live-verified** under `mix run` in tmux (120×30, scratch `XDG_STATE_HOME`):
- In geex's own repo: `Alt+O` listed the files (name, then directory). `keym` put `keymap.ex`
  (`lib/geex/loop`) and `keymap_test.exs` first; `Alt+S` moved the highlight; Enter opened
  `keymap_test.exs` with the editor focused. `finder.ex` typed and Enter sent at once opened
  `lib/geex/finder.ex`. `qqqzzz` showed "(no files match)", and Enter said "no file matches
  “qqqzzz”". Ctrl-X exited 0, with no warnings or errors in the log.
- In the home directory (not a repository; the walk, about 937k files): `Alt+O` at once showed
  "(reading the files…)" while the tree said "reading…". Once read (about 33 s under load), typing
  `geex/lib/geex/finder.ex` and Enter opened it 0.8 s later, typing included. `keymap` kept the
  last results until its search answered (under 2 s), then listed `keymap.ex` and
  `keymap_test.exs` first. RSS was about 760 MB with the home directory loaded.

**Automated:** `finder_test` (3 tests + 4 doctests: matches the slow reference ranking over
30,000 paths and more than ten byte ranges; blank queries; the name band and tie order) and
`loop/finder_test` (9: the background read and blank listing; search then Enter; Enter before the
search; Enter before the read; a new key kills the old search and its late answer is ignored; Esc
stops it; no match; a search that dies; the `open` and `find` verbs). `panes_test` and
`buffers_test` moved to the new `open`.

**916 tests + 39 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** Windows Terminal; a path containing a newline (it would split into two rows; git
quotes such names, the walk doesn't).

### 2026-10-17 — `geex 0.1.0+e0beef53` deployed (the keys and the finder)

`mix geex.deploy` from the clean tree at `e0beef5` (916 tests + 39 doctests green twice just
before it). It installed `0.1.0+e0beef53`, kept `0.1.0+f9e59088` as `geex.prev`, and removed the
old unpack. No binary geex was running.

**Live-verified** with `geex` from the PATH in tmux (`-L deploy`, scratch `XDG_STATE_HOME`/
`TMPDIR`, a scratch repo): `--version` printed it and `--frob` exited 2; `geex a.txt` showed the
tree and the file with the discovery file present; `Alt+O`, `s.txt`, Enter opened `sub/s.txt`;
typing and Ctrl-O wrote it; Ctrl-X exited 0 with the cursor visible, the alternate screen off and
the discovery file gone. `geex <dir>`, bare `geex` and `geex notes.txt` (holding `IO.puts("x")`,
not printed) opened as expected. The log had no `terminating` lines.

**Not tested:** Windows Terminal; `--rollback` (checked at the first install).

### 2026-10-17 — Split panes, each with its own tabs (ADR-0038)

File panes split the editor evenly (`Alt+-` top/bottom, `Alt+=` side by side), each with its own
tabs (`Alt+,`/`Alt+.`, `Alt+1..9`, a tab bar). The same file in two panes is one buffer with a
cursor per pane. Session's active buffer is the current pane's shown tab. `Alt+K` closes a tab;
an emptied pane closes; the only pane falls back to the buffer before. `Geex.Loop.Panes` is the
pure model, `Geex.Layout.split/2` the rectangles, and `Session.close_buffer/1` the one new Session
call.

**Adversarial review** (three reviewers, in parallel, read-only, each refuting its own
candidates against the code before reporting; nine findings survived, all fixed with tests):
- *Hand-off with Session:*
  - an edits-pane jump onto a background tab was overwritten by the tab's old cursor;
  - a key queued behind an open acted on the old tab (Alt+K could close the file just opened).
  Both fixed: an open now shows its tab in the same step. Also:
  - a tab left by an outside switch kept a stale cursor (fixed: each repaint copies the current
    tab's cursor);
  - `geex a b c` gave one to three tabs in reverse order, depending on scheduling (fixed:
    `Geex.Loop.open_tabs/1` makes them tabs a, b, c, a shown);
  - the only pane emptied by a crashed buffer stayed empty (fixed: it falls back to another
    open buffer or a scratch one).
- *Model and layout:*
  - a zero-width pane crashed the loop (also found by the render lens): splitting is now refused
    below 12×4 per half ("no room to split this pane"), and a pane a resize leaves under 3×3
    isn't drawn;
  - splitting an empty pane made an unclosable empty pane (fixed: it isn't split);
  - a buffer ending showed the next tab, not the one before (fixed).
- *Rendering:* a notice from another tab's buffer read as about the current file (fixed: it
  names its file).
- *Refuted* (checked, no defect): Panes invariants over 3,000 × 30 random operations; Layout
  tiling over 5,000 random trees; the parser's new Alt chords against CSI/SS3 and a lone Esc;
  the verbs' `tab` prefixes; the row arithmetic and hardware cursor; the tab bar with CJK and
  emoji names; subscription leaks.

**Live-verified** under `mix run` in tmux (scratch repo):
- `Alt+=` then `Alt+-`: three panes with dividers and tab bars.
- `Alt+O` opened `notes.txt` as tab 2 of the current pane.
- `Alt+P` went tree → each pane → edits.
- Typing in one pane showed in the other pane on the same buffer.
- `Alt+K`:
  - closed a tab whose buffer was in another pane, leaving the buffer open;
  - refused a dirty buffer;
  - after undo, closed the buffer;
  - closed a pane by its last tab;
  - closed the only pane's last tab to a scratch buffer.
- `geex a.txt notes.txt sub/s.txt` showed tabs 1–3 in order with `a.txt` shown.
- A third `Alt+=` in a narrow pane said "no room to split this pane".
- A resize to 20×6 and back drew without a crash.
- Ctrl-X exited 0, with no warnings or errors in the log.

**Automated:** `panes_model_test` (9: show, step/select, split, closing panes, the only pane, a
buffer ending, elsewhere?), `split_test` (14: the frame read back from the Renderer for side-by-side
panes and the tab bar; a cursor per pane; tabs; every Alt+K case; a buffer ending; a stale event;
an agent's edit in both panes; the verbs and palette; the size limit; an open showing at once;
startup tabs; another buffer's notice), plus `Layout.split/2`/`dividers/2` doctests.

**939 tests + 41 doctests**, green twice, `--warnings-as-errors` clean.

**Not tested:** Windows Terminal (`Alt+digit`, `Alt+-`, `Alt+=` there); the MCP surface driving
opens while the TUI runs (not served together today); a cursor in another pane shifting with an
edit above it (deferred: it is clamped, not moved).

### 2026-10-17 — `geex 0.1.0+f4ea2e76` deployed (split panes and tabs)

`mix geex.deploy` from the clean tree at `f4ea2e7` (939 tests + 41 doctests green twice just
before it). It installed `0.1.0+f4ea2e76`, kept `0.1.0+e0beef53` as
`geex.prev`, and removed the old unpack. No binary geex was running (a `pgrep -f` check matched
only its own shell; `ps` confirmed none).

**Live-verified** with `geex` from the PATH in tmux (`-L deploy`, scratch `XDG_STATE_HOME`/
`TMPDIR`, a scratch repo):
- `--version` printed it, and `--frob` exited 2.
- `geex a.txt notes.txt` showed tabs `1 a.txt  2 notes.txt`, with the discovery file present.
- `Alt+=` split the pane, and `Alt+O` `s.txt` opened as tab 2 of the new pane. Typing and Ctrl-O
  wrote it, and `Alt+.` switched to tab 1.
- Ctrl-X exited 0 with the cursor visible, the alternate screen off and the discovery file gone.
- `geex <dir>` and `geex notes.txt` (holding `IO.puts("x")`, not printed) opened as expected.
- The log had no `terminating` lines.

**Not tested:** Windows Terminal; `--rollback` (checked at the first install).

### 2026-10-17 — The coordinator's step 3 review: two nits fixed

The coordinator approved `f4ea2e7` after its own live test of the installed binary:
- tabs from the command line, splits, `Alt+O` into a pane, tab switching;
- shared-buffer typing, every `Alt+K` case, `Alt+P`;
- the split limit, a resize to 20×6.

It also read the maintainer's Windows Terminal settings: the only Alt binding added is
`alt+shift+d`, and the terminal's own pane and tab keys all need Shift or Ctrl, so `Alt+digit`,
`Alt+-`, `Alt+=`, `Alt+,` and `Alt+.` should reach geex there.

Fixed:
- The notice now reads "closed the tab; … is still open in another pane": a pane holds a
  buffer in one tab at most, so "another" always meant another pane.
- At 20×6 with four side-by-side panes, the two narrowest showed a stale `──` on their top row.
  A pane too small to draw was skipped, and after a resize the renderer assumes a blank
  terminal, so whatever the terminal showed there before stayed. Skipped panes are now filled
  with the theme background. Live: four panes, a resize to 20×6 drew the narrow ones blank, and
  back to 140×34 they came back.

**Automated:** `split_test` asserts the notice and the filled background. Both assertions fail
without the fix. **939 tests + 41 doctests**, green twice.

### 2026-10-17 — `geex 0.1.0+426290c1` deployed (the step 3 nits)

`mix geex.deploy` from the clean tree at `426290c` (939 tests + 41 doctests green twice). It
installed `0.1.0+426290c1`, kept `0.1.0+f4ea2e76` as `geex.prev`, and removed the old unpack; the
only BEAM VMs running were pharos's (checked by executable path, not `pgrep -f`, which matches its
own shell). Live with `geex` from the PATH: `geex a.txt notes.txt`, `Alt+=`, then `Alt+K` on the
new pane's tab closed the pane with "closed the tab; a.txt is still open in another pane"; Ctrl-X
exited 0, and the log had no `terminating` lines.

### 2026-10-17 — The mouse, step 1: the foundation in the file panes (ADR-0039)

Live in tmux (`-L geexdf`, 100×30, `set-clipboard on`, a scratch `XDG_STATE_HOME`), with the
mouse sent as raw SGR reports through `send-keys -l`:
- At start tmux showed mouse modes on (`mouse_any_flag`, `mouse_sgr_flag`, `mouse_button_flag`).
- A click on "baz" put the cursor at 2:9. A drag from the line's start over "foo_bar baz", then
  `Alt+C`, put `foo_bar baz` in tmux's buffer: the OSC 52 copy arrived.
- In a 200-line file: four wheel notches scrolled to line 13 with the cursor left at 1:1. A
  double-click on "number" selected the word (copied, it read `number`). A drag held on the
  scroll-bar row for half a second scrolled 9 lines and selected lines 21 to 38.
- A drag held on a long line's last column scrolled right. After the wheel, Delete edited line 1
  and the view came back to it.
- `mouse` turned the modes off, with its notice, and on again.
- The modes were reset by hand while geex was stopped, and bash's `fg` brought them back
  (SIGCONT). An outside `kill -STOP`/`-CONT` from a shell job stops geex again on its next read,
  as bash has taken the terminal; that is job control, not geex.
- Ctrl-X and SIGTERM both left the modes off and the alternate screen closed.

Reviewed adversarially (two agents: the loop and model; the terminal, parser and docs). Fixed:
- a click on the vertical scroll bar's column placed the cursor on text hidden under it;
- a drag to the right edge of a pane against the terminal's edge never scrolled right;
- a drag outlived a tab switch, an outside open or an edit, and selected from a stale anchor;
- a click's held scroll survived a split or a resize, leaving the cursor out of view (`hold`
  now carries the pane's size);
- after the wheel, a key that edits in place (Delete) acted out of view (any key in the editor now
  ends the hold);
- the auto-scroll kept going under the palette (a key now ends a drag; a tick checks the
  minibuffer);
- a double-click on a byte that isn't UTF-8 crashed the loop;
- Shift+wheel stopped short of the widest line's end when there was a vertical scroll bar;
- a mouse report split across reads more than 40 ms apart was typed into the buffer after the
  Esc timeout (now waited for, `Parser.mouse_report?/1`);
- the loop and TerminalIO could disagree on the mouse after a restart (the loop now sets it on
  init); modes 1005/1015 are turned off at start; a buttonless move decodes as `:move`;
- the ADR claimed tmux needs `mouse on` (it passes the mouse either way) and that the `at_exit`
  hook covers a halt (it doesn't run on one).

**Automated:** `test/geex/loop/mouse_test.exs` (22 tests: clicks by display column, focus, drag,
Shift+click, double-click, the wheel under the pointer, the held scroll, auto-scroll both ways,
the minibuffer, the verb, OSC 52 through a stand-in TerminalIO, and the review's cases) and the
parser's "mouse reports" (SGR, past 223, the wheel, modifiers, extra buttons, split reads, the old
form). **968 tests + 46 doctests**, green twice.

**Not tested:** Windows Terminal (its Shift+drag bypass, its OSC 52); a real mouse (reports were
typed in as bytes); the installed binary (next, with /deploy).

### 2026-10-17 — `geex 0.1.0+3647bb7c` deployed (the mouse, step 1)

`mix geex.deploy` from the clean tree at `3647bb7` (968 tests + 46 doctests green twice). It
installed `0.1.0+3647bb7c` and removed the old unpack; no other geex was running (checked by
executable path). Live with `geex` from the PATH in tmux (`-L deploy`, 120×30, scratch state):
- `--version` printed `geex 0.1.0+3647bb7c` (exit 0); `--frob` exited 2.
- `geex a.txt notes.txt` showed both tabs, and `notes.txt` (holding `IO.puts("x")`) opened
  without printing. Mouse modes were on, and the discovery file was present.
- A drag over `foo_bar` and `Alt+C` put `foo_bar` in tmux's buffer (OSC 52). Typing and Ctrl-O
  wrote the file.
- Ctrl-X and SIGTERM both left the mouse modes off, the alternate screen closed and the cursor
  visible. The discovery file was gone, and the log had no `terminating` lines.

**Not tested:** Windows Terminal; a real mouse; `--rollback` (checked at the first install).

### 2026-10-17 — The mouse, step 2: everything clickable (ADR-0039 §6)

The coordinator approved step 1 (`3647bb7`) after its own live test of the installed binary:
clicks on the right grapheme (after `日本語`, on the second half of `本`), drag, Shift+click and
double-click copies through OSC 52 (`日本語` too), the wheel, a held drag to line 54. It asked for
Alt+click to extend a selection as well, since Windows Terminal keeps Shift+click; built here.

Live in tmux (`-L geexdf`, 120×30, the tree and the edits pane shown), with raw SGR reports:
- Clicking the tree's `long.txt` opened it as tab 2, and a click on tab 1 showed `a.txt`.
  Clicking `sub/` opened it, and a second click closed it.
- Tab 2's `×` closed it ("closed long.txt"). `Alt+=` drew a `×` at each pane's right end; the
  second pane's `×` closed it ("closed the pane").
- `Alt+I`, `vsplit`, and a click on its row split the pane.
- After a save, the edits list's `a.txt  you` entry opened `a.txt` on a click.
- `a.txt` was written from outside. A click on "behind disk (Alt+J)" said "caught up with the
  disk" and showed the new line.
- Ctrl-X left the mouse modes off.

Reviewed adversarially (one agent). Fixed:
- a pane too small to draw closed from its invisible `×`;
- the wheel's hold on the tree or edits list survived a key that moved nothing, and focusing the
  list (`Alt+P`), so the highlight stayed out of view; Shift+wheel held a list it didn't scroll;
- a double-click on a folder opened and closed it;
- a dirty tab's `×` switched to the tab before refusing (now refused in place, naming the file);
- a click on the edits list read the entries again, so an edit arriving since the last frame
  shifted the rows (it now uses the rows drawn);
- a pane's `×` on another pane moved the current pane to its heir;
- a click on the tab already shown dropped the selection.

**Automated:** `test/geex/loop/mouse_click_test.exs` (20 tests: tabs, both `×`s and their
refusals, the tree, the edits list, the status line, the pickers, Alt+click, the review's cases);
`split_test` reads the new tab bar. **988 tests + 47 doctests**, green twice.

**Not tested:** Windows Terminal; a real mouse; the installed binary (next, with /deploy).

### 2026-10-17 — `geex 0.1.0+5370ea4c` deployed (the mouse, step 2)

`mix geex.deploy` from the clean tree at `5370ea4` (988 tests + 47 doctests green twice). It
installed `0.1.0+5370ea4c`; no other geex was running. Live with `geex` from the PATH in tmux
(`-L deploy`, 120×30, scratch state):
- `--version` printed `geex 0.1.0+5370ea4c`; `--frob` exited 2.
- `geex a.txt notes.txt` drew `1 a.txt ×  2 notes.txt ×`, with the discovery file present.
- A click on tab 1 showed it. A click on the tree's `long.txt` opened it as tab 3. `Alt+=`, then
  the new pane's `×`, closed the pane ("closed the pane").
- Typing and Ctrl-O wrote the file.
- Ctrl-X left the mouse modes off, the alternate screen closed and the cursor visible. The
  discovery file was gone, and the log had no `terminating` lines.

**Not tested:** Windows Terminal; a real mouse.

### 2026-10-17 — The mouse, step 3: resizing by drag handles (ADR-0038 §6)

The coordinator approved step 2 (`5370ea4`) after its own live test of the installed binary,
with nothing to fix. It noted that an `outside` edits entry opens where the cursor was (only
tool-call entries jump to their line), as Enter does; that is on the roadmap as a later nicety.

Live in tmux (`-L geexdf`, 120×30, the tree and the edits pane shown), with raw SGR reports:
- `Alt+=` then `Alt+-` drew `⠿` on the divider's middle, on the lower right pane's tab bar just
  before its `×`, on the tree's edge, and in the edits title's rule.
- Dragging the stacked handle from row 10 to row 5 moved pane 3's tab bar to row 5.
- Dragging the divider from column 74 to 59 narrowed the left pane; a double-click on it put it
  back to even.
- Dragging the tree's edge to column 40 and the edits title up to row 14 resized them (seen
  before the review fixes).
- The terminal resized to 90×24 kept the proportions.
- Ctrl-X left the mouse modes off.

Reviewed adversarially (two agents: the layout and model math, with sweeps over hundreds of
split trees and every size up to 110×45; the loop's mouse interplay). Even splits lay out as
before wherever the old layout kept panes at least 12×4. Fixed:
- short of room, a dragged split could collapse a pane to 0 rows or columns, and `ratio_at`
  could pass 1 (the least sizes now shrink in proportion);
- a dragged tree or edits pane could squeeze the editor below what its splits need
  (`Layout.least/1` now bounds them);
- a drag whose split changed under it (a pane closed) moved another split;
- the stacked handle was drawn on any blank cell, a tab's space included, where a press didn't
  take it, and a full tab bar left no cell to grab (each bar on a boundary now keeps a handle
  cell, drawn and hit-tested by `TabBar`);
- a press where a handle had been dragged from, or on a tab bar blanked by a `×`, counted as a
  double-click (presses now carry their kind);
- the edits handle vanished under the focused title's longer hint; a press on the tree's edge
  stopped focusing the tree; hiding a panel mid-drag reset its size.

**Automated:** `test/geex/loop/resize_test.exs` (15 tests: dividers, clamps, double-click, a
stacked and a nested split, a terminal resize, the tree and edits sizes, the drawn handles, a
full tab bar, the review's cases), Layout doctests (`ratio_at/3`, `handles/2`, `least/1`,
`resolve/3`'s sizes), `Panes.set_ratio/3`. **1003 tests + 51 doctests**, green twice.

**Not tested:** Windows Terminal; a real mouse; the installed binary (next, with /deploy).

### 2026-10-17 — `geex 0.1.0+839c64cb` deployed (the mouse, step 3)

`mix geex.deploy` from the clean tree at `839c64c` (1003 tests + 51 doctests green twice). It
installed `0.1.0+839c64cb`; no other geex was running. Live with `geex` from the PATH in tmux
(`-L deploy`, 120×30, scratch state):
- `--version` printed `geex 0.1.0+839c64cb`; `--frob` exited 2.
- `geex a.txt notes.txt` opened, with the discovery file present.
- `Alt+=`, then dragging the divider from column 74 to 54 and the tree's edge from 29 to 39,
  resized both. The press on the tree's edge focused the tree, so the next keys went there.
- In a second run, typing and Ctrl-O wrote `a.txt`.
- Ctrl-X and SIGTERM left the mouse modes off and the alternate screen closed. The discovery
  file was gone, and the log had no `terminating` lines.

**Not tested:** Windows Terminal; a real mouse.

### 2026-10-18 — Apache-2.0: LICENSE, NOTICE and a README

geex had no licence; it is now Apache-2.0 (`LICENSE`, the standard text, byte-identical to
captAInHook's), with a `NOTICE` for the third-party material in the tree. Checked by hand:
- `priv/grammars/{elixir,json}/parser.wasm` are byte-identical to the `.wasm` built in
  `~/tree-sitter-elixir` (commit 7937d3b, Apache-2.0 with MIT generated parser, per its own
  NOTICE) and `~/tree-sitter-json` (001c28d, MIT), and each `highlights.scm` to that commit's
  `queries/highlights.scm`. NOTICE names the commits and carries their licences.
- `priv/themes/birds-of-paradise.json` is the Zed port's palette; NOTICE carries the BSD
  3-Clause text from `~/birds-of-paradise-zed/LICENSE` (Joe Bergantine 2010, and the port).
- `mix.exs` has no package block, so there is no `licenses` field to set.
- The new top-level `README.md` says to clone `tree_sitter_wasm` beside geex (the path dep).

`~/tree_sitter_wasm` moved from MIT to Apache-2.0 in its own commit (0bcc4ac): LICENSE, a NOTICE
for its tree-sitter-json test fixtures (the same build, MIT), and the licence in `mix.exs` and
`Cargo.toml`; its 8 tests green. geex: **1003 tests + 51 doctests**, green twice.

**Not tested:** nothing runs differently; the clone-and-build steps in README.md were not run on
a fresh machine.

### 2026-10-18 — A deploy keeps the unpack a running geex uses (BUG-4); `geex 0.1.0+5b995d0f` deployed

Three deploys:
- **`dcce38b`** installed a binary that printed `0.1.0+839c64cb`: the commit changed no module,
  so Mix kept the old `geex.app` (the release directory said `+dcce38ba`). Its prune also
  removed `+839c64cb`'s unpack under the maintainer's open geex, which crashed (BUG-4; the
  coordinator session stopped it with SIGTERM, cleanly).
- **`9a366ef`** removes `geex.app` before building. It installed `0.1.0+9a366eff` and was
  checked live (`--version`, `--frob` exit 2, `geex a.txt notes.txt` with the discovery file,
  typing + Ctrl-O wrote `a.txt`, `notes.txt`'s `IO.puts` not run, Ctrl-X left the alternate
  screen and the mouse modes off, the discovery file gone, no `terminating` lines). No geex was
  running.
- **`5b995d0`** is the BUG-4 fix. Live, with scratch state in tmux (`-L deploy`): one geex
  from `geex.prev` (unpack `+dcce38ba`, which the deploy would not keep as prev) and one from
  `~/.local/bin/geex` (`+9a366eff`, about to become prev), both running through the deploy. It
  printed `kept geex_erts-16.1_0.1.0+dcce38ba, in use by pid …` and installed `0.1.0+5b995d0f`;
  all three unpacks stayed. Afterwards both geex opened `notes.txt` with `Alt+O`, toggled the
  tree, and quit with Ctrl-X: exit 0, alternate screen and mouse off, no `terminating`, `undef`
  or crash lines in either log, both discovery files gone.

One of the two, started in the same second as the other, printed Burrito's "Failed to load the
metadata file" for `+dcce38ba` before taking the screen: its start-up cleanup
(`do_clean_old_versions`) read that directory while the other was still unpacking it. It skips
such a directory. It never removes a geex unpack itself (semver ignores `+<sha>`).

**Automated:** `test/geex/deploy_test.exs` runs a process from a fake unpack and reads it back
from `/proc`; the `stale_unpacks/3` doctest. **1004 tests + 52 doctests**, green twice.

**Not tested:** a dirty deploy over a running geex of the same dirty version (it stops, by
reading the code); `--rollback` to the kept `geex.prev` unpack.

### 2026-10-18 — The tree follows files coming and going (ADR-0034 amendment)

The maintainer saw `NOTICE` and `README.md` never appear in an open `geex .`'s tree.
`Geex.Tree.Watcher` now watches, without recursion, the root, the directories holding listed
files and their immediate subdirectories, and the loop reads the files again on a create,
delete or move.

**Live** (`mix run` in tmux, `-L geexdf`, 120×30, a scratch repository with `lib/m.ex`, `a.txt`
and an ignored `_build/dev`):
- `inotifywait` ran with no `-r`, over the root, `_build` and `lib`.
- `echo n > NOTICE` from outside: `NOTICE` showed within a second.
- `mkdir notes`, then a file in it: `notes/` showed. The watch was restarted over the root,
  `_build`, `lib` and `notes`, one `inotifywait` at a time. A second file in `notes/` raised no
  error.
- `rm a.txt`: gone from the tree. `mv lib/m.ex lib/n.ex`, and later (with `lib/` opened by a
  click) `renamed.ex` to `again.ex`: the open folder showed the new name in place.
- A `touch _build/dev/x.beam` changed nothing.
- After Ctrl-X no `inotifywait` was left, and the log had no warnings or errors.

**Automated:** `test/geex/tree/watcher_test.exs` (7 tests + a doctest): the directories it
watches, a burst being one message and edits none, a new set starting a new worker before the
old one stops, a stopped worker asking for a read and giving up after two, no backend, and,
where `inotifywait` exists, a real watch (a new file, a file in a new directory after the next
read, a deletion, nothing from `_build/dev`). `panes_test.exs`: a change reads again, a change
during a read reads once more, and the highlight keeps its file when a row comes in above it.
**1012 tests + 53 doctests**, green twice.

**Not tested:** a root past 4096 directories; reconcile's watch, now non-recursive, beyond the
suite (each open file's directory still has its own watch).

### 2026-10-18 — An agent's created file reaches the edits pane (ADR-0032); a new directory is watched at once

Two follow-ups:
- **Created files.** The payload now sends `created: true` for a `Write` that created its
  file, and geex lists it as the agent's.
- **Nested directories.** The coordinator's live check of `31a56fa` found that `mkdir -p e1/e2`,
  then a file in `e1/e2` a second later, never showed. A directory made is now watched at once
  with what's under it that git doesn't ignore.

**Live** (`mix run` in tmux, 140×34, a scratch repository with `/_build/` ignored, scratch
`XDG_RUNTIME_DIR` and state):
- `geex-attest.sh` with the real `write-create.jsonl` envelope, aimed at a new
  `made-by-agent.txt` (`GEEX_ATTEST_DIR` set to this geex's discovery directory), exited 0. The
  tree showed the file, and the edits pane a row `made-by-agent.txt  claude-code/56544d6f`.
- `mkdir -p e1/e2 _build/prod/x`, 1.5 s, `echo hi > e1/e2/late.txt`: `e1/` appeared. The watch
  covered `e1` and `e1/e2`, not `_build/prod`.
- After Ctrl-X: no `inotifywait` left, and no warnings in the log.

**Automated:**
- `attest_payload_test.exs`:
  - `write-create.jsonl` sends `created`, `sha256` and the ids, with no `before`;
  - a writer with null prior text that isn't a create sends nothing;
  - through the real `POST /attest`, an unopened created file is an agent row;
  - a fresh empty buffer credits the create on fast-forward;
  - a buffer that held text keeps `:external`.
- `ledger_test.exs`: a spooled `created` line starts from `""`.
- `watcher_test.exs`:
  - `new_dirs/2` skips dot-directories and git-ignored ones;
  - a directory-create event restarts the watch over its subtree, which outlasts the next read;
  - the real-inotify test now covers the late nested file.
- **1017 tests + 54 doctests**: the new tests passed 30 repeats. Of 30 full-suite runs, one had a
  failure whose test I didn't capture; 28 further runs were clean.

**Not tested:** a real Claude Code `Write` creating a file through captAInHook (the envelope is
the captured fixture); the flaky failure above.

### 2026-10-18 — `geex 0.1.0+658e67d5` deployed (the tree watcher, created files)

`mix geex.deploy` from the clean tree at `658e67d` (1017 tests + 54 doctests green). It installed
`0.1.0+658e67d5`, removed the `+9a366eff` and `+dcce38ba` unpacks (none in use) and kept
`geex.prev`'s `+5b995d0f`. Live with `geex` from the PATH in tmux (`-L deploy`, scratch state):
- `--version` printed `geex 0.1.0+658e67d5`; `--frob` exited 2.
- `geex a.txt notes.txt` opened both, with the discovery file present. `notes.txt` holds
  `IO.puts("x")`; nothing was printed.
- `NOTICE` created from outside, and `d1/` (`mkdir -p d1/d2`, then a file in `d1/d2` 1.5 s later),
  showed in the tree.
- Typing and Ctrl-O wrote `a.txt`.
- Ctrl-X: alternate screen and mouse off, discovery file gone, no `terminating` lines, no
  `inotifywait` left.

**Not tested:** Windows Terminal.

### 2026-10-18 — Compiled grammars cached on disk (ADR-0040 step 2)

`tree_sitter_wasm` 0bc6629 adds wasmtime's compilation cache (`load_grammar/4`, `cache_dir:`).
geex passes `$XDG_CACHE_HOME/geex/wasm`.

**Measured** (8 cores, release NIF):
- **The NIF alone,** five loads per VM:
  - Elixir's `parser.wasm`: 141–145 ms each with no cache, 5 ms from the cache. That held in a
    second VM, so the cache is on disk and not in memory.
  - JSON: 9 ms with no cache, 0.4 ms from the cache.
  - Timing each phase put the rest of Elixir's load (~67 ms) in `Query::new` (its
    `highlights.scm`), which isn't wasm.
- **Through `Geex.Highlight.Grammars.handle/1`,** a new VM each time with a scratch
  `XDG_CACHE_HOME`: Elixir 154 ms, then 72 ms; JSON 3 ms, then 0.

**Read, not run:** that a wasmtime upgrade misses the cache. The key hashes
`Config::module_version`, and loading a cached artifact checks the version again. The test
"an entry wasmtime can't load is compiled again" damages every entry, and the next load compiles
and highlights the same.

**Automated:**
- `tree_sitter_wasm`, 11 tests:
  - the cache's files appear, and a cached load highlights the same;
  - a damaged entry is recompiled;
  - a file where the directory should be, or a path under that file, loads with no cache;
  - a bad grammar is still an error.
- geex: `grammars_cache_test.exs` (where the cache goes; off under test). **1018 tests + 54
  doctests**, green twice.

**Not tested:** the installed binary's first start with an empty cache against a warm one (next,
with the deploy); a wasmtime version bump for real.

### 2026-10-18 — `geex 0.1.0+10439898` deployed (the wasm cache, a stripped NIF)

**Two deploys from `1043989`**, both from a clean tree with 1018 tests + 54 doctests green:
- The first had the cache, with the NIF unstripped.
- The second followed `tree_sitter_wasm` 89a8723 (`strip = true`).

Both are `0.1.0+10439898`, since the version names geex's commit only. So `geex.prev` is now the
first of the two and shares the new one's unpack directory name: a `--rollback` to it would run
from the stripped build's files. That is harmless here, since the code is the same, but a
version doesn't name a changed sibling dependency.

**Sizes:**
- **The NIF:** 17.1 MB before (the coordinator's measurement), 18.7 MB with wasmtime's cache
  feature, 14.5 MB stripped.
- **The installed binary:** 22.6 MB, then 22.1 MB.

**Live** (`geex` from the PATH in tmux, `-L deploy`, scratch state, `TMPDIR` and
`XDG_CACHE_HOME`):
- `--version` printed `geex 0.1.0+10439898`.
- `geex a.ex b.json` highlighted `defmodule` in Birds of Paradise's keyword orange.
- After the first run, the cache held three compiled modules (tree-sitter's stdlib, Elixir,
  JSON). A second run added none.
- Ctrl-X both times: alternate screen and mouse off, no `terminating` lines, the discovery file
  gone.

**Not tested:** how much sooner the first frame is highlighted with a warm cache; the
measurement is the step's NIF and `Grammars` numbers above.

### 2026-10-18 — The built-in terminal theme, and the terminal's background (ADR-0040 step 3)

`Geex.Theme.Terminal` (the terminal's own colours), the OSC 11 query and the parsing of its
answer, the palette's `mark` fallback, and the `theme` verb.

**Live** (`mix run` in tmux, 120×30, `a.ex`):
- `theme terminal` drew in 16-colour SGR only: `defmodule`/`do`/`def` in 35, `A` in 36, `f` in
  34, the string in 32, the comment in `3;90`. The divider and the line numbers were in 90.
- tmux with no client attached doesn't answer OSC 11, so this was the fallback: select-all
  showed `ESC [7m` on the text.
- Sending `ESC ] 11 ; rgb:1e1e/1e1e/2e2e ESC \` into the pane, as a late answer would come:
  the selection turned `48;2;80;80;92`. Sent again with BEL: the cursor's line took
  `48;2;46;46;61`.
- No character of either answer reached the buffer.
- Birds of Paradise, the default, still shows its active line (`48;2;49;35;33`).
- Ctrl-X was clean, and the log had no errors.

**Automated:**
- `parser_test.exs` "OSC answers":
  - BEL and ST endings, with keys around;
  - an answer split at every byte, held and read whole;
  - a late answer after a key, and another OSC;
  - Alt+] held, then flushed as keys;
  - an ESC inside that isn't ST;
  - an endless OSC dropped past its cap;
  - the `osc_reply?/2` doctests.
- `theme_test.exs`:
  - every capture Birds of Paradise styles has a 16-colour or default style;
  - the SGR it draws in;
  - light and dark, and the tint;
  - `Theme.names/0`;
  - the `Theme.Terminal` doctests (the tint numbers, `parse_rgb/1`).
- `loop/theme_test.exs`:
  - `theme`, `theme terminal` and an unknown name;
  - an answer tints the terminal theme and is only kept under another;
  - a bad answer or OSC 10 changes nothing and types nothing;
  - with no answer, the picked tree row and the selection are reversed in the Screen;
  - Birds of Paradise has no mark.
- **1031 tests + 58 doctests**, green twice.

**Not tested:** Windows Terminal's answer to OSC 11 (the maintainer's terminal; the ADR's
"verify" item); a light terminal live.

### 2026-10-18 — `geex 0.1.0+4a5b7268.89a87236` deployed (the terminal theme; the version names the NIF)

`mix geex.deploy` from the clean trees at geex `4a5b726` and `tree_sitter_wasm` `89a8723`
(1031 tests + 58 doctests green twice).
- **The version:** it installed `0.1.0+4a5b7268.89a87236`, the first version of the new shape
  (`60dadc9`). Its unpack sits beside `geex.prev`'s `+10439898`; no other was left to prune.
- **Live** with `geex` from the PATH in tmux (`-L deploy`, scratch state):
  - `--version` printed it; `--frob` exited 2.
  - `geex a.ex notes.txt` opened, with the discovery file present; `notes.txt`'s `IO.puts` didn't
    run.
  - `theme terminal` redrew in 16-colour SGR (`defmodule` 35, `A` 36).
  - Typing and Ctrl-O wrote `a.ex`.
  - Ctrl-X: alternate screen and mouse off, the discovery file gone, no `terminating` lines.

**Not tested:** Windows Terminal.

### 2026-10-18 — The step 3 review's fixes, and the catalog builder (ADR-0040 step 4)

**The review's fixes (`da47ac9`):** an adversarial review of `60dadc9..4a5b726` (a subagent; it
ran parser probes, and `isatty` under a pty) found these, each fixed and, where it can be
tested, tested:
- the status line drew no bar under the terminal theme;
- with stdout not a terminal, Alt+] was held about 18 years;
- a held `ESC ] 11 ;` had no timeout;
- "not an OSC after all" lost the `]` or a paste;
- `build_id` read the shell's directory and lost geex's sha without a git sibling;
- a failed theme took the theme's name;
- ANSI 8 comments vanish in Solarized Dark.

**The builder:** `mix geex.catalog`, from scratch, with an empty `_build/catalog/src`.
- It cloned the 15 repositories (TypeScript and TSX share one), checked each tag's commit, built
  16 grammars with the tree-sitter CLI 0.26.9, and loaded each in the NIF. It packed them and
  Birds of Paradise and wrote `catalog/catalog.json`, in 40 s.
- A second run wrote a byte-identical `catalog.json`, so the wasm build and the zips are
  deterministic.
- Seven packages, unzipped and loaded, highlighted a sample with the expected captures:
  - TypeScript got JavaScript's `function` and `keyword` from the merged queries;
  - TSX got `tag` and `attribute`;
  - HEEx, Erlang, YAML, Python and Markdown each got theirs.
- Each grammar package holds `parser.wasm`, `highlights.scm`, `manifest.json` and its licence
  files (Elixir's NOTICE too).

**Automated:** `catalog_test.exs`:
- every recipe is in the catalog, and nothing else;
- each entry has a 64-hex sha256, an asset named by it, an https URL ending in it, a size and a
  licence;
- each grammar has endings or file names, an ABI in 13–15 and a 40-hex commit;
- no ending is claimed twice;
- file names map to the right grammar (`.ts` and `.tsx`, `rebar.config`, `.bashrc`,
  `index.html.heex`; a bare `.md` is none);
- the `Package` doctests: a deterministic zip, sha256, the asset name, the ABI.

**1036 tests + 63 doctests**, green twice.

**Not tested:** the packages from the release host (it doesn't exist yet); installing them
(step 5).

### 2026-10-18 — Windows Terminal answers OSC 11 (step 3, hand-verified by the maintainer)

The maintainer ran `theme terminal` in Windows Terminal (`0.1.0+4a5b7268.89a87236`) on
`lib/geex.ex` and sent the coordinator session a screenshot:
- the cursor's line (104) was tinted, which needs the terminal's answer to OSC 11;
- the syntax was in the scheme's own ANSI colours.

This closes step 3's "Windows Terminal" item. In the same screenshot:
- the edits pane listed `NOTICE`, `CLAUDE.md`, ADR-0040 and `testing.md` as this session's
  (`claude-code/d25a8b6d`), through the live captAInHook path;
- the tree showed `catalog/` as it was being made.

### 2026-10-18 — `geex 0.1.0+7b5a2931.89a87236` deployed (the review's fixes, the catalog)

`mix geex.deploy` from the clean trees at `7b5a293` and `tree_sitter_wasm` `89a8723` (1036
tests + 63 doctests green). It installed `0.1.0+7b5a2931.89a87236` and removed the unused
`+10439898` unpack. Live with `geex` from the PATH in tmux (`-L deploy`, scratch state):
- `--version` printed it; `--frob` exited 2.
- `geex a.ex notes.txt` opened, with the discovery file present; `IO.puts` didn't run.
- `theme terminal`: the comment drew dim and italic (`2;3m`), the status line in reverse video
  (`7m`).
- Ctrl-X was clean: no discovery file left, no `terminating` lines.

**Not tested:** installing a package (step 5; the catalog is embedded, nothing reads it yet).

### 2026-10-18 — Installing grammars and themes, and loading what's installed (ADR-0040 step 5)

**Live, against the real release** (`v0.1.0`, created by the coordinator session), with scratch
`XDG_DATA_HOME` and `XDG_CACHE_HOME`:
- **`Install.install/1`:**
  - `rust` installed; the download went through GitHub's 302 to the asset CDN, with full TLS
    verification.
  - `birds-of-paradise` installed in 147 ms.
  - `nope` was `{:not_in_catalog, "nope"}`.
- **Afterwards:**
  - `rust`'s directory held `parser.wasm`, `highlights.scm`, `manifest.json`, `LICENSE` and
    `installed.json` (sha256, `source: catalog`, time).
  - `language_for_path("a.rs")` was `{:ok, "rust"}`, and Rust highlighted.
  - `grammar_status("a.py")` was `{:available, "Python"}`.
- **`Install.fetch/1` against badssl.com:**
  - `wrong.host`, `self-signed` and `expired` were each refused at the TLS handshake
    (`handshake_failure`, `bad_certificate`, `certificate_expired`);
  - `badssl.com` itself fetched;
  - a missing GitHub asset was `{:http_status, 404}`.
- **`geex install --list`** (as `Geex.CLI.install(["--list"])`) printed the 17 packages with
  kind, size and status: available, installed, or bundled for elixir and json.
- **The TUI, without a restart:**
  - `a.py` was open as plain text in a `mix run` geex.
  - `geex install python` ran in a second process with the same data directory.
  - About 2 s later the open file showed Python's colours, and the status line said "Python
    highlighting installed".
  - The first try didn't colour: the loop subscribed to the new reactor with
    `Reactor.subscribe(r) && r`, and `subscribe` answers the overlay, `nil` before the first
    pass, so the loop kept `nil`. Fixed, with a test.

**Automated:**
- `install_test.exs` (15 tests and a doctest):
  - a local grammar directory installs, is used and is recorded as local, then is replaced in
    place by a zip;
  - a local theme zip installs, and `theme` lists and loads it;
  - entries are refused: `../evil`, `sub/…`, `run.sh`, `/abs`;
  - a "symlink" entry lands as a plain file;
  - more than 64 MB unpacked is refused;
  - a manifest naming another kind or a bad name is refused;
  - a grammar of ABI 16 is refused;
  - an installed one of ABI 16 is `needs_update`, with no language and `{:abi, 16}`;
  - opening such a file shows the hint, and a later install gives it a reactor the loop
    follows;
  - a catalog download whose sha256 differs is refused (`GEEX_CATALOG_URL=file://`);
  - `update?/1`;
  - over loopback HTTP (Bandit): a redirect, a redirect loop, a 404, a 40 MB body cut off;
  - the `redirect/2` doctests (no https→http);
  - another geex's install is noticed once per burst, and not again for the same sha256, with
    a stub and with inotify;
  - only `Geex.Install` reaches the network (the import tables).
- `catalog_test.exs`, the CLI doctests (`install`, `-- install`).
- **1051 tests + 66 doctests**, green twice.

**Not tested:** the installed binary's own download (next, with the deploy: the release must
carry `:inets` and `:ssl`); a zip whose headers lie about sizes (the heap cap is there, not
exercised).

### 2026-10-18 — Step 5 in the binary; the step 5 review's fixes; a flaky-test fix

**In the binary** (`0.1.0+743a7fc7.89a87236`, then the `.dirty` builds of the halt fix):
- **The release:** `geex.rel` lists `{inets, "9.4.2", load}`. The first try failed to build:
  Mix refuses `:load` for a dependency of a permanent app, and `:ssl` is ThousandIsland's.
- **Installing:** `geex install go nope` installed Go from the real `v0.1.0` release in 1.06 s.
  It said "nope isn't in this geex's catalog" and exited 1. `--list` then showed go installed.
- **Pipes:** `geex install --list | head -1` hung (exit 124 under a 15 s timeout). The fix is
  one write for the table, and a halt with `flush_timeout: 2_000`, since the default halt waits
  to flush a closed pipe. After it: exit 0.
- **The TUI:** `geex m.go r.rs` (Rust not installed), then `geex install rust` in another
  terminal, then `r.rs`: `fn` turned keyword-orange with "Rust highlighting installed". The same
  held installing first and then `open r2.rs` at once. Python and Go files highlighted from
  their installs.

**The review** (an adversarial subagent over `73b3120`, with probes): its findings are in
ADR-0040's step 5 notes, each fixed. They have tests in `install_test.exs` "review fixes":
- a live lock means busy, and a dead one's lock is taken over, leaving nothing beside the
  package;
- a manifest listed over 64 KB is refused;
- null, empty or non-string file names are refused, and `match/2` ignores them;
- a package directory ignores other files, refuses a link, and writes 0644;
- reserved names and wrong types are refused;
- a stale cached grammar is compiled again.

**Flaky tests:** a full-suite run failed in `tree/watcher_test.exs` twice, in different tests,
seed 291424 the second time. Both were an `assert_receive` with ExUnit's default 100 ms, which
the watcher's restart (a `git check-ignore`, a new worker) can exceed under the full suite's
load; 30 runs of the file alone passed. `test_helper.exs` now sets `assert_receive_timeout:
1_000`, and 10 full runs in a row passed. This is likely also the earlier failure whose name
wasn't captured.

**1057 tests + 66 doctests**, green 10 times in a row.

### 2026-10-18 — `geex 0.1.0+2ec264e7.89a87236` deployed (step 5 and its review's fixes)

`mix geex.deploy` from the clean trees at `2ec264e` and `tree_sitter_wasm` `89a8723`. Live with
`geex` from the PATH, scratch `XDG_DATA_HOME`, `XDG_CACHE_HOME` and state:
- `--version` printed it; `--frob` exited 2.
- `geex install --list | head -1` exited 0.
- `geex install typescript birds-of-paradise` installed both from the real release, exit 0.
- `geex a.ts notes.txt` highlighted `const` and `x` from the installed TypeScript grammar, with
  the discovery file present.
- Ctrl-X was clean: no discovery file left, no `terminating` lines.

**Not tested:** Windows Terminal with the new binary.

### 2026-10-18 — `Alt+Y`, the settings view (ADR-0040 step 6)

**Live** (`mix run` in tmux, 110×26, scratch `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and
`XDG_CACHE_HOME`, `a.js` holding a template string):
- **The hint:** opening `a.js` said "JavaScript highlighting available: Alt+Y".
- **Languages:** `Alt+Y` showed the four tabs and the 16 languages (sizes; elixir and json
  "bundled"), with JavaScript already highlighted.
- **Installing:** Enter installed it from the real release; the row turned "installed", and the
  message line said "installed JavaScript". After Esc, `export` and `function` were in keyword
  colour.
- **Themes:** a click on "Themes" (SGR press at column 16, row 1) switched tabs. ↑ previewed
  `terminal`, its row in reverse video (tmux doesn't answer OSC 11). Esc put Birds of Paradise
  back.
- **Keys:** typing `split` listed `Alt+-  Alt+=` and the ⠿ handle.
- **Nothing kept:** nothing had been chosen, so no `settings.json` was written. The log had no
  errors.
- **A wrong label, fixed:** the bundled Birds of Paradise showed "available"; it says "bundled"
  now.

**Automated:**
- `loop/settings_test.exs` (10 tests and the `KeyHelp` doctest):
  - Languages rows and statuses, and Enter installing only what's available;
  - tabs, moving, closing and quitting, and Keys' search with Backspace;
  - Themes: the preview on moving, choosing on Enter, "in use";
  - the mouse on a tab, a row (acting as Enter), the wheel;
  - in the editor: `Alt+Y` full screen (the reversed tab, the rows), keys not reaching the
    buffer, Esc and `Alt+Y` closing;
  - a previewed theme put back on Esc, a chosen one kept in `settings.json` and applied at the
    next start;
  - the mouse and tree toggles kept and applied, a malformed value ignored;
  - an install from the view running off the loop, its "installing…" status and its error
    message (a `file://` catalog with wrong bytes);
  - the hint once, and `Alt+Y` opening on that language;
  - an up-to-date install fetching nothing, while `force: true` does fetch.
- **1067 tests + 67 doctests**, green twice.

**Not tested:** Windows Terminal; the view at very small sizes (under ~40×10).

### 2026-10-18 — `geex 0.1.0+ae9b714f.89a87236` deployed (the settings view)

Live with `geex` from the PATH, scratch XDG directories:
- `geex install go` installed it; again, it said "go is already installed (up to date; --force
  installs it again)" and fetched nothing.
- `geex a.py m.go` said "Python highlighting available: Alt+Y".
- `Alt+Y`, Tab, ↑, Enter chose `terminal`: "✓ in use", "theme terminal kept", and
  `settings.json` held `{"theme":"terminal"}`.
- Ctrl-X was clean, with no `terminating` lines.

**Not tested:** Windows Terminal.

### 2026-10-18 — geex is bare (ADR-0040 step 7)

`priv/` is gone. The Elixir and JSON grammars and Birds of Paradise are test fixtures, installed
into the test data directory by `test_helper.exs`.

**Live** (`mix run` in tmux, scratch XDG directories, so nothing installed and no settings):
- `a.ex` drew in the terminal's own colours (39/90, no truecolor), as plain text. The status
  line said "Elixir highlighting available: Alt+Y".
- `geex install elixir` from another process: about 2 s later `defmodule`/`do` were magenta
  (35) and `A` cyan (36), in the terminal theme.
- The log had no errors.

**Automated:** every test that used the bundled grammars or theme now uses the fixtures (as
installed packages, or via `Geex.Fixtures.birds/0` for the colour checks). New: `default/0` is
the terminal theme; `named/1` loads an installed theme and refuses one that isn't. **1067 tests
+ 67 doctests**, green twice.

**Not deployed yet:** held, at the coordinator session's request, until the step 6 review's fixes
are in. After it lands, the maintainer's geex shows plain text until `geex install elixir`.

### 2026-10-18 — The step 6 review's fixes; General's paths

An adversarial review of `ae9b714` (a subagent with probes) found three state bugs, one latent
bug that step 7 made reachable, and smaller ones. ADR-0040's step 6 notes list them; each is
fixed. `loop/settings_test.exs` "review fixes" has a test each:
- a slow install no longer chooses its theme after the user chose another;
- Tab to Themes highlights the theme in use;
- General shows and turns over what's kept, not the session (`{"tree": true}` with the tree
  hidden reads "on", and Enter keeps false);
- a `settings.json` that isn't JSON is left alone, and the view says so;
- a hint from a file opened behind the view is kept for later;
- a 3-row screen's help line takes no click, and drawing at 10×2 doesn't crash;
- `--force` alone, or with `--list`, lists;
- General's paths keep their file name at 40 columns, cut from the left with "…".

**BUG-5:** a new flake, the reconcile quiet-period test finding the buffer behind an empty
file, happened once in ~13 full runs (seed 125550; not reproduced in 3 runs of that seed). It is
in `bugs.md` with what is known. Nothing in this run's code explains it.

**1075 tests + 67 doctests.** One run of three hit BUG-5; ten more had one hit (that one), the
rest green.

### 2026-10-18 — `geex 0.1.0+1cbe3f34.89a87236` deployed: geex is bare (step 7)

- **First deploy:** `99cd35eb`, from the clean tree at `99cd35e` (steps 7 and the review's
  fixes), as the coordinator session asked: after the step 6 review's fixes, with the release up.
- **Live with the binary,** scratch XDG directories, nothing installed:
  - `--version`, `--frob` (2).
  - `geex install --force` listed the catalog, exit 0.
  - `geex a.ex notes.txt`: plain text in the terminal's colours, with "Elixir highlighting
    available: Alt+Y".
  - `Alt+Y` opened on Elixir ("available"); Enter turned it "installed" with "installed Elixir".
    After Esc, `defmodule` was magenta (35).
  - Ctrl-X was clean, with the discovery file gone.
- **The binary showed a layout bug:** General's "Compiled grammars" label overflowed its column,
  and its path was cut on the right. `1cbe3f3` fixed it.
- **Redeploy:** `1cbe3f34`. General at 100 columns aligned, each path cut from the left with
  "…", ending in `settings.json`, `geex` and `wasm`. Ctrl-X was clean, with no `terminating`
  lines.

**For the maintainer:** their installed geex now shows plain text until `geex install elixir`
(or `Alt+Y`). The coordinator session told them beforehand.

**Not tested:** Windows Terminal with the bare binary.

### 2026-10-18 — BUG-6: one release in the binary; `geex 0.1.0+bf7ccc25.89a87236` deployed

The coordinator session found 23 geex releases in the bare binary's unpack, some carrying the old
`priv/grammars` and `priv/themes` (BUG-6). After `bf7ccc2`'s deploy:
- **The unpack:** `lib/` holds one `geex-*` directory, and
  `find <unpack> -name '*.wasm' -o -name 'birds*'` finds nothing.
- **Sizes:**

  | | Before (`1cbe3f34`) | After (`bf7ccc25`) |
  |---|---|---|
  | Unpack | ~114 MB | 86 MB |
  | Binary | 22,334,760 bytes | 21,938,408 bytes |

  The old releases compressed well, so the binary shrinks less than the unpack.
- **Burrito:** no `/tmp/burrito_build_*` was left after the build. 15 from earlier deploys,
  about 1.8 GB, were removed by hand; each held a geex release.
- **Live** (`geex` from the PATH, scratch XDG directories):
  - `--version`; `--frob` (2);
  - `geex install elixir`, then `geex a.ex notes.txt`, with `defmodule` magenta (35);
  - Ctrl-X clean: no discovery file left, no `terminating` lines.

**1075 tests + 67 doctests**, green twice.

### 2026-10-18 — `Alt+A` / `Alt+D` change tabs in the settings view

**Live** (`mix run` in tmux): `Alt+Y`, then `Alt+D` reversed "Themes". Three `Alt+A` reached
Keys, with its search still empty. The footer read "← → or Alt+A Alt+D tabs".

**Automated:** `settings_test.exs` (`Alt+D`/`Alt+A` in both cases, wrapping, never typed into
the search; KeyHelp lists them). **1076 tests + 67 doctests**, green twice.

**Deployed** as `0.1.0+ce000aec.89a87236`. In the installed binary (tmux, scratch XDG directories)
`Alt+Y` then `Alt+D` reversed "Themes", and Ctrl-X was clean.

### 2026-10-18 — BUG-5: the quiet-period test assumed a deadline (fixed), and its kin

**Reproduced.** The method, the coordinator session's:
- CPU load: `yes > /dev/null` ×8, then ×16, on 8 cores;
- `mix test test/geex/reconcile_test.exs --repeat-until-failure` alongside.

It failed on the second pass. A temporary copy of the old test alone, repeated under ×16, failed
again; this time the buffer was behind the sha256 of "v2 done\n".

**The verified cause:** the test's own reconciler, doing what it should. The test writes "v2 half",
sends an event, writes "v2 done\n", sends another, then checks it is "still quiet", assuming the
150 ms quiet period outlasts all that. Under load the test process is descheduled past 150 ms:
- **after both writes:** the reconciler reads the final bytes (the reproduction);
- **mid-`File.write!`**, after the truncate and before the bytes: it reads `""` (the first
  sighting).

A temporary probe in `Buffer.disk_changed/2`, logging any call with `""` and its caller,
recorded none in the reproduction, so no other process read the file. `lib/` was put back
byte-for-byte.

**The fix:** the test no longer races a clock.
- Its reconciler's quiet period is an hour, and the test delivers the reconciler's own
  `{:settled, path, ref}` timers itself. The superseded first one must read nothing, the last
  must read the final bytes, once.
- A new test checks that a real 20 ms quiet period runs out by itself, waiting up to 5 s for the
  result instead of asserting a deadline.
- `session_test.exs` started the global reconciler three times with the real `inotifywait`
  backend on the shared temp directory, while saying "no real inotify". That was a hazard but
  not the cause; they use the stub now.

**Its kin, found by the same load:** at ×8 load, three more tests assumed an idle machine.
- `tree/watcher_test.exs` slept 300 ms for `inotifywait` to set its watches. It now creates
  probe files until one's event arrives.
- It also waited 1 s for a restart that runs `git check-ignore` (now 10 s), and checked "no
  restart" with a 50 ms `refute_receive` (now `:sys.get_state/1`, then `refute_received`).
- `Reactor.await/3` (tests only) gave a first pass, which compiles a grammar, 1 s. It now
  defaults to 10 s, returning as soon as it's there.
- At ×16, `tree_test.exs`'s 10,000-file test passed ExUnit's 60 s per-test limit. It has 300 s.

**Checked:**
- under ×16, `reconcile_test.exs` repeated with no failure;
- under ×8, four full suites (random seeds) green;
- unloaded, green twice;
- under ×16 the full suite takes over 140 s, past what I ran it for: oversubscribed twice over.

**1077 tests + 67 doctests.**

### 2026-10-18 — a frame costs the screen, not the file (ADR-0035 amendment)

Every key was slow in `lib/geex/loop.ex` (141 KB, 27,772 spans). `:eprof` showed the frame
doing whole-file work:

- `Paint.to_screen` walked all 686,000 graphemes, and its byte → style map covered every span;
- `max_line_width/1` and `line_count/1` split the whole text;
- `Reactor.render/1` copied every span to the loop.

Now:

- Paint slices out only the visible rows (`Paint.visible_lines/3`, one `:binary.matches/2`
  scan) and resolves only the spans over their bytes.
- The reactor indexes each overlay once (`Geex.Highlight.SpanIndex`), and `Reactor.render/3`
  answers a byte window by binary search.
- `line_count/1` counts newline offsets, and `max_line_width/1` stops at the first line too
  short in bytes to be wider.

**Measured** in-process: a scratch script started the app with highlighting on, opened loop.ex
at 120 × 40, and took the median of 10 runs.

| | Before | After |
|---|---|---|
| a frame | 323 ms | 9.8 ms |
| Down and its frame | 1,388 ms | 10.6 ms |
| a typed `x` and its frame | — | 13.8 ms |
| `Alt+1` tab switch and its frame | — | 8.8 ms |
| a typed `x` alone | — | 0.18 ms |
| `render/3` alone | — | 0.012 ms |

**Guard:** `test/geex/loop/frame_cost_test.exs`. It paints loop.ex three times over (~420 KB,
over 50,000 spans) from line 5,568, through `Loop.handle_info/2`. The best of five runs for a
frame, Down plus a frame, and `x` plus a frame must each be under 150 ms. With `lib/` stashed
(the old code) it fails at 1,264 ms for a frame; with the new code it passes.

**Also tested:**
- `span_index_test.exs`: two doctests, plus 200 random windows over 2,000 random spans, each
  equal to a walk over all of them;
- `reactor_test.exs`: `render/3` equals `render/1` filtered to the window, exact and across an
  optimistic shift;
- `Paint.visible_lines/3` doctests, wired in through `doctest Paint`.

**Folded in:** the coordinator session's follow-up to BUG-5. The inotify test of
`tree/watcher_test.exs` asserts that `_build/dev` is not in the watcher's directories, and
drains late events before writing there.

**Not checked here:** the key-to-screen time in the installed binary, through a terminal. That
goes in the deploy entry.

**1081 tests + 70 doctests**, green twice.

**Deployed** as `0.1.0+571a2782.89a87236` and timed in the installed binary. Setup: tmux at
120 × 40 with scratch XDG directories, in a scratch repository holding a copy of loop.ex. The
time runs from `send-keys` until `capture-pane` shows the new cursor position on the status
line, so it includes tmux's round trip. Medians of 11 runs:

| | Time |
|---|---|
| Down at line 1,200 of loop.ex | 15 ms (12–24) |
| a typed character there | 19 ms (15–24) |
| the same round trip on a one-line file (the floor) | 10 ms (8–12) |
| Down in the previous binary (`geex.prev`, `0.1.0+ce000aec`), 7 runs | 364 ms (360–392) |

So geex's own share of a key on loop.ex is about 5 ms for Down and 9 ms for typing.

**Also checked:**
- `--version`, and `--frob` exits 2;
- `geex notes.txt` (holding `IO.puts("x")`) opened the file, and typing and `Ctrl-O` saved it;
- `geex .` showed the tree and a scratch buffer;
- `Ctrl-X` gave the shell back;
- the attestation file was there while geex ran and gone after;
- the log had no `terminating` lines.

**Not checked:** a terminal other than tmux.

### 2026-10-18 — the scroll bars take the mouse; the edits handle stays put (ADR-0039 §7)

**What changed:**
- A press on a file pane's vertical or horizontal bar takes the thumb. On the track, the thumb
  jumps to centre on the pointer.
- Dragging scrolls live, and the release ends it. The cursor stays where it was until a key
  moves it.
- `Geex.Loop.ScrollBar` is pure: the layout, the thumb, the hit test and the exact inverse. The
  drawing and the mouse share it.
- The coordinator session relayed the maintainer's bug report and its cause: the edits pane's
  `⠿` jumped about 8 columns when a click focused the pane, because it was centred in a rule
  whose length depends on the hint. It now sits at the pane's centre, clamped into the rule.

**Automated:**
- `scroll_bar_test.exs` (7 tests + 5 doctests):
  - the bar the mouse finds is where the frame draws the thumb;
  - a track press jumps there (the thumb's middle on the pointer) and leaves the cursor;
  - a thumb dragged row by row keeps the grabbed row under the pointer;
  - a drag past the ends stops at the top, or with the last line at the bottom, off the bar too;
  - a key brings the cursor back into view;
  - the horizontal bar jumps and drags;
  - a press on the other pane's bar focuses that pane;
  - with no bar, the last column is text.
- `resize_test.exs`: the handle at the pane's centre, focused and not; a click on the title
  leaves it under the pointer (the old code moved it to column 67); a narrow pane keeps it
  between the name and the hint.

**Live, dev build in tmux** (120 × 30, scratch XDG directories, loop.ex), with raw SGR reports
sent by `send-keys -l`:
- a press on the track's last row jumped to the end (line 3,713 at the bottom);
- a drag to row 10 put line 1,740 at the top, with the thumb at row 10;
- a drag off the bar to row 2 went back to line 1;
- the cursor stayed at 1:1 throughout;
- the edits handle stayed at column 60 when a click on it focused the pane and swapped the hint;
- the log had no errors.

**Not checked:**
- the horizontal bar live (loop.ex had no line wider than the pane);
- a real mouse in Windows Terminal.

**1090 tests + 75 doctests**, green twice.
