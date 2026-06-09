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
keymap grew two arrow-free Alt clusters: **WASD** (up/left/down/right) and **ERTYUIOP** (E/R char back/fwd,
T/Y word back/fwd, U/I line start/end, O/P line up/down; word motion is whitespace-delimited, within-line).
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
