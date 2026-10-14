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
