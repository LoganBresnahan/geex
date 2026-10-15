# ADR-0032: Listener-first agent integration — agents edit natively, geex records, captAInHook attributes; MCP frozen

- **Status:** Accepted (amended 2026-10-14: attestation safety + write completion)
- **Date:** 2026-10-14
- **Amends:** [ADR-0016](0016-external-harness-integration.md) (the ladder's recommended
  path), [ADR-0017](0017-reconcile-file-watch.md) (reconcile becomes the primary agent path;
  its attribution open question is answered), [ADR-0018](0018-mcp-transport-streamable-http.md)
  (the MCP server is frozen)
- **Defers:** [ADR-0008](0008-pharos-not-bundled.md) / [ADR-0010](0010-disk-truth-lsp-v05.md)'s
  MCP-client→pharos work off the critical path

## Context

geex's thesis ([vision.md](../vision.md)) is one attributed undo history: every edit — a
keystroke, an agent's change, an out-of-band disk write — is a `%Command{}` on one path,
tagged with who made it. For agents, v0.5 built two doors:

1. **The front door — MCP** ([ADR-0018](0018-mcp-transport-streamable-http.md)): the agent
   edits *through* geex's tools; a per-harness preset ([ADR-0016](0016-external-harness-integration.md))
   denies the harness's built-in writers to push it there.
2. **The floor — reconcile** ([ADR-0017](0017-reconcile-file-watch.md)): whatever skips the
   door is caught by the file watcher and recorded as an anonymous `:external` command.

After living with both, and with the maintainer's other tools maturing alongside, the front
door is the wrong main path:

- **It fights the harness.** Agents fall back to the tools they were trained on — the
  founding observation of [captAInHook](https://github.com/LoganBresnahan/captAInHook) ("agents
  underuse the tools you give them"). geex's `insert`/`replace`/`edit` are exactly such
  tools; Claude Code's native `Edit`/`Write` are the habit. The preset only wins by *denying*
  the habit, and it can never deny shell writes (`sed -i`, scripts) — the subprocess-write
  gap ADR-0016 documents.
- **Its attribution is thin anyway.** Every MCP edit is `{:llm, "unknown"}`: the stateless
  protocol core has no model, session, or turn identity.
- **It costs upkeep per harness.** Each harness needs a preset in its own config dialect,
  and those keys move between harness versions.

Meanwhile **captAInHook already sits in the loop.** It receives every lifecycle hook of every
harness it supports — `PostToolUse` included — with the session, the turn, and the tool
call's input (the file path and the change). That is *more* attribution than geex's door
could ever capture, and it exists for captAInHook's own reasons: geex installs nothing.

ADR-0017's open question leaned **no** on attribution beyond `:external` because "strong
attribution comes from being **in the loop**" and a hook "puts geex back in the loop." The
new fact: the hook layer is already there, owned by a separate tool. geex doesn't need to be
in the loop — it needs to **listen to the thing that is**.

## Decision

1. **Agents edit with their native tools; reconcile is the primary agent path.** geex stops
   asking harnesses to route edits through it. An agent's write lands on disk, the
   reconcile watcher picks it up, and it enters the one undo history as `%Command{}`s — the
   same path every other edit takes ([ADR-0003](0003-one-shared-path.md)). The unified
   timeline (your keystrokes and the agent's edits interleaved, each undoable) is
   geex's product; the door was only one way to fill it.

2. **The division of labour.**

   | tool | answers |
   |---|---|
   | **captAInHook** | *who and why* — harness, session, turn, tool call |
   | **geex** | *what changed, in what order, and undo it* — in the editor you work in |
   | **git** | what was committed |

   geex never reads captAInHook's internals (trail, mail, config); captAInHook never learns
   geex exists. They meet at one small, versioned message.

3. **Attestation, joined by content hash — not by time.** A captAInHook **exec payload**
   (a geex-owned script, registered by the user in `~/.captainHook/handlers.json` on
   `post-tool-use`) reads the tool call's file path from the envelope, hashes the file as it
   stands after the call, and sends geex an **attestation**:

   ```json
   {"v":1, "path":"/abs/file", "sha256":"…",
    "harness":"claude-code", "session":"…", "turn":"…", "tool_use":"…"}
   ```

   `path`, `sha256` and `harness`/`session` are required; `turn` and `tool_use` are sent
   when the harness's envelope carries them (it varies by harness and version) and are
   otherwise omitted, not invented. Reconcile already holds the exact text it recorded, so it stamps each reconciled command
   with the **post-state hash** of that text. An attestation **upgrades** the matching
   command's actor from `:external` to `{:agent, %{harness, session, turn, tool_use}}` when
   (path, sha256) match exactly. The join is deterministic: no time windows, no guessing.

   - **The ordering is the expected case.** The write fires inotify in milliseconds; the
     `PostToolUse` hook runs after the tool returns. So reconcile **dispatches immediately**
     (the human sees the agent's edit live, no settle delay) and the attestation arrives
     after. Attesting is a **history operation** — like undo/redo
     ([ADR-0031](0031-undo-redo-history-operations.md)), neither an edit nor a view action:
     `Buffer.attest/2` finds the most recent `:external` command whose post-state hash
     matches and upgrades its `meta.actor`. Replay is unaffected: `meta` never feeds a
     command's `run/2`, so the state a replay produces is identical with or without the
     upgrade.
   - **Fails safe.** If the file changed again before the hook hashed it, or two writers
     coalesced into one reconcile, the hash doesn't match and the command **stays
     `:external`**. ADR-0012's rule holds: never promote a guess to `actor`. A hash match is
     an attestation from a party in the loop about exact bytes, not an inference.
   - **Scope, honestly.** Only tool calls that name a file path attest. Shell writes
     (`Bash`) carry no path, so they stay `:external` — still recorded, still undoable, just
     anonymous. Session-correlation for those stays the cheap later option ADR-0017 named.
   - **Only once, only upward.** An attestation upgrades `:external` once; it never touches a
     `:human` command or rewrites an already-attested one.

4. **The intake.** The attestation endpoint is a loopback HTTP route on geex's existing
   Bandit listener (`POST /attest`), started in **TUI mode too**, not only under
   `GEEX_SERVE`. Each running geex writes a `0600` discovery file (URL + a per-instance
   token) under `$XDG_RUNTIME_DIR/geex/` (tmp-dir fallback). The payload sends to every
   live instance; each instance ignores paths it doesn't have open. The token keeps another
   local user's process from mislabelling commands. A same-user process could forge one, but
   it could write the file itself anyway, so the token is hygiene, not a security boundary.

5. **MCP is frozen, not removed.** The MCP server (ADR-0018), its tool categories (edits,
   operations, view actions [ADR-0030](0030-view-action-tool-category.md), grid
   [ADR-0027](0027-grid-command-addressing.md) agent half), and the presets
   (`presets/`, ADR-0016) stay in the tree, stay tested, and stay working. **No new tools,
   categories, or presets.** `mix geex.serve` keeps working for anyone who wants the door.
   The "agent looks at the editor" read surface (per-participant views, a Screen snapshot
   tool) is parked with it.

6. **pharos leaves the critical path.** The MCP-client→pharos LSP work (ADR-0008/0010) was
   v0.5's remaining ship. pharos serves *agents*; LSP for the human editor is a
   nice-to-have, not part of the ledger. Deferred until the editor wants go-to-definition.

7. **v0.5 is redefined around the ledger:** (a) reconcile emits **line-level diffs** as
   minimal `replace` commands (so undoing an agent's change undoes that hunk, not the whole
   file); (b) a **conflict UX** for a disk change on a dirty buffer; (c) the **attestation
   intake** + post-state hash + `Buffer.attest/2`; (d) the **payload** script; (e)
   **surfacing** attribution in the TUI (who wrote this hunk; undo by author). Order and
   detail live in [roadmap.md](../roadmap.md).

## Consequences

- **Any harness, no preset.** Every harness captAInHook supports gets attributed edits; every
  harness at all — Cursor, aider, a shell script — gets recorded, undoable `:external` edits.
  Nothing to install in the target project.
- **Richer provenance than the door ever had** (harness + session + turn + tool call vs.
  `{:llm, "unknown"}`), with the honest floor intact for everything else.
- **Reconcile's deferred work becomes the main work.** Its "for now" whole-buffer replace and
  missing conflict UX were tolerable on a floor; on the main path they're the product.
- **Two projects now meet at a contract.** The attestation message is versioned (`v`); geex
  must ignore unknown fields (the captAInHook house rule).
- **The enforced regime fades.** Nothing forces an agent through geex any more; "removing the
  other ways in" ([vision §5](../vision.md)) is no longer pursued for external agents. The in-VM
  agent (the other enforced regime) is unaffected and still far off.
- **Only open buffers are recorded.** Reconcile watches the files geex has open. Edits to other
  files are captAInHook's and git's to record. geex is the ledger for what you're looking at.
- **Frozen code keeps its tests.** The MCP suite stays green as a regression net; a change
  that breaks it is still a finding.

## Alternatives considered

- **Keep the MCP door as the main path, add identity to it.** Fixes the `{:llm, "unknown"}`
  gap but not the core problem: the agent still has to be steered off its native tools,
  per harness, and shell writes still escape.
- **Delete the MCP layer.** Simplest, but throws away working, tested code and the
  "agent looks at the editor" option. Freezing costs nothing.
- **Correlate by time window instead of hash.** Racy under load and two concurrent writers;
  turns attribution into a guess. Rejected per ADR-0012.
- **Hold the reconcile until the attestation arrives (a settle delay).** Avoids amending
  history, but delays every agent edit on screen and still needs a fallback for writes that
  never get an attestation. Amending meta via a history operation keeps the edit live and
  replay-neutral.
- **geex reads captAInHook's trail or mail bus directly.** No payload to maintain, but it
  couples geex to captAInHook's internal formats. A payload plus a small message keeps both
  sides free to change.
- **Linux `fanotify` for the writing PID** (ADR-0017's middle option). Privileged,
  platform-specific, and yields a process, not an agent turn. Still rejected.

## Revisit triggers

- A harness captAInHook can't hook becomes a daily driver → the MCP door (or a preset) earns
  its way back for that harness.
- Shell-write attribution becomes a real need (debugging, audit) → add session correlation as
  a confidence-tagged side field, never as `actor`.
- A concurrent-edit need (human and agent typing in the same region at once) appears → that's
  the OT/CRDT question, parked in the agent-view direction notes.
- The editor wants go-to-definition / diagnostics → un-defer the pharos client.

## See

[vision.md](../vision.md) §1/§5, [ADR-0003](0003-one-shared-path.md),
[ADR-0005](0005-provenance-on-every-command.md), [ADR-0012](0012-trust-and-enforcement.md),
[ADR-0016](0016-external-harness-integration.md), [ADR-0017](0017-reconcile-file-watch.md),
[ADR-0018](0018-mcp-transport-streamable-http.md), [ADR-0031](0031-undo-redo-history-operations.md);
captAInHook's ADR-0010 (exec handlers: the envelope and payload model the attestation rides).

## Amendment — 2026-10-14: attestation safety, arrival order, write completion

Gaps found by checking this ADR against captAInHook's actual code and config (a
coordination review) and against geex's watcher dependency. Each refines a Decision item;
none changes the direction.

1. **Only writer tools attest (refines Decision 3).** Read and Grep carry file paths too.
   Without a filter: an external write (`sed -i`, another editor) is recorded `:external`
   with hash H; the agent then *reads* the file; the payload sends (path, H); and an edit the
   agent never made is upgraded. So the **payload** attests only tool calls on a per-harness
   **writer allowlist** (Claude Code: `Edit` / `Write` / `MultiEdit` / `NotebookEdit`, to be
   confirmed against captAInHook's real-envelope fixtures). An unknown harness or tool sends
   **nothing**, which fails toward `:external`. The harness comes from the exec envelope's
   `event.harness` (being added on the captAInHook side); the tool name and file path come from
   the raw harness JSON in `event.payload`.

2. **The hash is of disk bytes, and attest matches only the newest reconcile group (refines
   Decision 3).**
   - **What is hashed.** "Post-state hash" in Decision 3 means **`sha256` of the disk bytes
     reconcile read** (`File.read/1`), exactly what the payload hashes. It is *not* a hash of
     the buffer's resulting text. Today the two coincide, but once step (b) merges an agent's
     write into a dirty buffer, the buffer equals disk *plus* your unsaved edits and its hash
     would never match. Any future normalization between disk bytes and `Doc` text (trailing
     newline, CRLF, BOM) would break it the same way.
   - **What is matched.** Step (a) turns one write into one minimal `replace` per hunk,
     dispatched as one atomic group, so a single agent `Edit` can yield several `:external`
     commands. Every command from one reconcile carries the **same group id and disk-bytes
     hash**. `Buffer.attest/2` considers only the buffer's **newest reconcile group**, and
     upgrades **all of its commands together, atomically, once**, only if the group is
     unattested and its hash equals the attestation's. Older groups are never touched. Human
     commands recorded after it don't block it: they change the buffer, not the disk the hash
     describes.
   - **Residual hole, stated honestly:** an agent write whose bytes equal the file's current
     contents changes nothing on disk, so nothing is reconciled, yet its attestation (path, H)
     still matches the newest reconcile group if that group read H, for example a
     `sed -i` just before. The exact fix is a **before/after hash pair**: the payload also
     hashes at `pre-tool-use`, correlates the two by tool-call ID, sends nothing when they are
     equal, and geex matches the group's pre-write disk hash as well. That depends on the envelope
     carrying a per-call ID; decide once the fixtures show whether it does. Until then the hole
     stays open and is **pinned by a test** so it can't widen silently.

3. **Arrival order isn't guaranteed: a bounded pending table (refines Decision 3).** The ADR
   assumed inotify beats the hook. It usually does: the hook path is shim → daemon → spawn →
   hash → POST. But it doesn't always, and the settle in item 4 makes reconcile later still. An
   attestation that finds no matching command is held in a **pending table keyed (path,
   sha256)**: capped in size (on the order of hundreds of entries) with a short TTL (seconds).
   When reconcile records a group whose disk-bytes hash matches, it **consumes** the entry and
   records the whole group already attested. The join stays exact; the TTL and size cap only
   garbage-collect. Residual: a stale entry (from an identical-bytes write, item 2) could attach
   to an unrelated later write of the very same bytes within the TTL. That window is bounded by
   the TTL, and the before/after pair closes it too.

4. **Write completion: a per-path settle, folded into step (a) (refines Decision 7a).**
   Reconcile's moduledoc admits that a non-atomic write can be adopted mid-write as a partial
   `:external` command and corrected by the next event. On a floor that was tolerable; on the
   main path with line diffs it leaves an **unattributable half-edit hunk** in history.
   Filtering on close-write isn't available as-is: `file_system` 1.1.1's inotify backend
   subscribes to `close_write` but **maps both `MODIFY` and `CLOSE_WRITE` to the same
   `:modified` atom**, so the two can't be told apart through the library. Decision: reconcile
   waits for a **per-path quiet period** (no further event for that path for tens of
   milliseconds; configurable) before diffing. An atomic rename (`moved_to`) delivers complete
   content either way. This settles *write completion* only; the edit still renders as soon as
   the write completes, and attestation still arrives after (Decision 3 is unchanged).
   Rejected for now: forking the backend to expose `close_write`, or running `inotifywait`
   directly. Revisit if the quiet period proves too slow or too loose. **Dogfood check:**
   whether Claude Code's `Write`/`Edit` write in place or via an atomic rename; log the finding
   in testing.md.

5. **The payload answers after it POSTs (refines Decision 4).** captAInHook's exec contract
   allows replying first and continuing to work. The attest payload does **not** use that: it
   hashes and POSTs (with a short timeout, failing open) **before** printing its answer
   (`{"effect":"noop"}`, or empty stdout + exit 0), so the attestation is in flight before the
   agent's next tool call. The handler's `budgetMs` must cover hash + POST.
   - **Stale discovery files.** POSTing to every live instance before answering means a dead
     geex's leftover discovery file would add latency to every agent edit. The discovery file
     records geex's OS pid; geex removes its file on clean exit, and the payload **skips any
     entry whose pid is gone** (crashes skip cleanup), with a short connect timeout either way.

## Amendment — 2026-10-14 (later): the before/after match, fixture-verified fields, arrival order

From captAInHook's real-envelope fixtures (captAInHook commit `3ddb467`,
`examples/fixtures/claude-code/`, Claude Code 2.1.299), the step (a) build, and a further
coordination review. This note **supersedes the residual holes** stated in the previous
amendment's items 2 and 3.

1. **An attestation must match both hashes.** The message gains `before`: the sha256 of the
   file's contents *before* the tool call. Every reconcile group already records
   `before_sha256` (the synced baseline the write replaced) and `sha256` (the disk bytes read).
   `Buffer.attest/2`, and the pending-table consumption, upgrade the buffer's newest reconcile
   group only when **both** match. That one rule covers every case the earlier notes
   handled with residuals:
   - **Coalesced writes.** Two writes to one path inside one quiet period reconcile as one
     group whose `before` is the earliest baseline. No single writer's `before` equals it, so
     the group stays `:external`. That holds for two agent writes, and equally for an agent
     write merged with a non-attesting writer (`sed -i` H0→H1, then an agent `Edit` H1→H2: the
     group is H0→H2, and the agent's attestation is H1→H2). A rule based on counting pending
     attestations would miss the second case.
   - **Identical-bytes writes.** A no-op write attests `before == sha256`; a group exists only
     when disk differs from its baseline, so it never matches. No payload-side check is needed.
   - **Stale pending entries.** An entry must match both hashes too, so a later unrelated write
     of the same bytes doesn't pick it up.

   **Where `before` comes from (claude-code):** the sha256 of the UTF-8 bytes of
   `tool_response.originalFile` (`Edit`, `Write` update) or `tool_response.original_file`
   (`NotebookEdit`), all present in the `PostToolUse` envelope. No `PreToolUse` handler, no
   `tool_use_id` join. A `Write` that **creates** a file has `originalFile: null`: send no
   `before`, and geex can't match it (fails safe; revisit only if "the agent creates a file you
   already have open" turns out to matter). A `NotebookEdit` whose response carries a non-null
   `error` sends nothing.

   **Exactness caveat:** `originalFile` is Claude Code's decoded text, not raw disk bytes. If
   they ever differ (CRLF, BOM, encoding), the hashes miss and the group stays `:external`.
   That fails safe, never wrong. A **dogfood check** confirms a plain UTF-8/LF file round-trips.
   The fallback, if it doesn't, is the `PreToolUse` disk hash joined by `tool_use_id` (present
   and identical on Pre and Post).

2. **Fixture-verified fields (claude-code).** Envelope:
   `{"v":1,"dispatchId","event":{"type","harness","sessionId","cwd","payload":<raw hook JSON>}}`.
   `harness` = `event.harness` (`"claude-code"`). Path = `payload.tool_input.file_path`
   (`Write`/`Edit`/`Read`) or `payload.tool_input.notebook_path` (`NotebookEdit`); `Bash` carries
   none. Writer allowlist observed: `Write`, `Edit`, `NotebookEdit` (`MultiEdit` stays listed,
   unverified on 2.1.299). `tool_use` = `payload.tool_use_id`. `turn` = `payload.prompt_id`
   (constant within one user prompt; that it changes on the next prompt is assumed, not yet
   observed). Envelopes carry **whole file contents** (`content` / `originalFile`), so they can
   be megabytes: the payload parses with `jq`, never shell regex.

3. **Arrival order is attestation-first.** Decision 3's "the ordering is the expected case"
   (inotify before the hook) no longer holds. Claude Code writes atomically: observed via
   `inotifywait`, both `Edit` and `Write` write `<name>.tmp.<pid>.<hex>` and rename it over the
   target. So reconcile reads once, after the 50 ms quiet period. Meanwhile the `PostToolUse`
   hop measures ~12–14 ms warm, plus the payload's hash and POST. The **pending table is the
   primary path**, and step (c) tests it as such. (Skipping the quiet period on `moved_to`,
   which is complete by definition, is possible but deferred; either order is handled.)

4. **The message, pinned.**
   `{"v":1, "path", "before"?, "sha256", "harness", "session", "turn"?, "tool_use"?}`.
   `before` and `sha256` are **exactly 64 lowercase hex characters** (what `sha256sum` and
   `Base.encode16(case: :lower)` both print). The intake **rejects** any other shape with a 400,
   rather than accepting a hash that could never match. `before` is absent only for a created
   file. geex ignores unknown fields.

## Amendment — 2026-10-14: step (b) decided — on overlap, disk wins and you're told

The conflict rule for an out-of-band write to a **dirty** buffer (Decision 7b), chosen by the
maintainer. Reconcile three-way merges base = the synced disk text, ours = the buffer, theirs =
the new disk text (`Geex.Edit.Merge`):

- **Every disk hunk lands.** Disk is the writer's ground truth for its next tool call, so geex
  never lets the buffer silently disagree with what an agent just wrote.
- **Your unsaved hunks that don't overlap are kept**, and the buffer stays dirty: the merge
  re-baselines `synced` to the disk bytes and recomputes `dirty`, atomically with the apply.
- **An overlapping hunk of yours takes the disk version.** It stays one undo away, and the
  human gets a status-line notice (`{:geex_buffer_notice, …}`): "disk changed: N of your
  unsaved hunks took the disk version (Alt+Z restores yours)". The identical change on both
  sides is not counted.
- The merge lands as an ordinary reconcile group (buffer text → merged text, hunk by hunk)
  stamped with the **disk-bytes** hashes, so attestation is unaffected by your unsaved edits.

Rejected: "you win" (the agent's overlapping text would never enter the history, so a save
would overwrite it, a hole in the ledger) and "ask each time" (it blocks the human while the
agent keeps writing against disk). Also added: hunks are applied with `expect_seq`, so a
keystroke landing between reconcile's snapshot and its apply makes the buffer refuse
(`:stale`) and reconcile retries on a fresh snapshot. This closes a race the whole-buffer
replace had too.

## Amendment — 2026-10-14: step (c) as built

Implementation choices made building the intake, within the decisions above:

- **The pending table lives in each buffer process**, not in a global table keyed by path:
  the buffer is already the one place a group is recorded, so parking an attestation and
  consuming it as a matching group is applied happen in one process, with no window between
  the check and the record. Size 64 and a 10 s TTL per buffer; both only garbage-collect.
- **A repeat is ignored, not parked.** An attestation matching the newest group when that
  group is already attested returns `:ignored`. Parking it could let it match a later,
  unrelated write of the same transition (a revert and re-apply) within the TTL.
- **In TUI mode the listener serves only `/attest`** (`Geex.Attest.HTTP`); the frozen MCP
  surface still needs `mix geex.serve`, where the MCP router hands `/attest` on. Opening the
  editor does not expose the edit tools.
- **Statuses:** `attested` / `pending` / `ignored` / `not_open` (200); `400` invalid, with the
  reason; `401` token; `403` any `Origin` header (the payload is never a browser). The token is
  compared in constant time.

## Amendment — 2026-10-15: step (d) as built — the payload, and line endings

1. **A CRLF file's `before` matches too (supersedes the earlier "Exactness caveat" for line
   endings).** Claude Code reports a file's prior text (`originalFile`) with each `\r\n` turned
   into `\n`, in one left-to-right pass: a lone `\r` stays, and `\r\r\n` becomes `\r\n`. The
   coordinator verified this live on 2.1.299 against five files (CRLF with a stray `\r`, mixed,
   LF with a stray `\r`, a CRLF `Write`, `\r\r\n`). An Edit to a CRLF file therefore never matched
   the exact baseline hash. Decided (maintainer): **geex** accounts for it, not the payload.
   - When the baseline holds `\r\n`, reconcile also stamps `before_sha256_lf`, the hash of
     `String.replace(baseline, "\r\n", "\n")` (else `nil`). An attestation's `before` may equal
     either before hash. **`sha256` (after) is always exact.**
   - geex holds the real pre-write bytes, so this covers `Edit` *and* `Write` (which rewrites a
     CRLF file as LF, leaving the payload nothing to rebuild from) and mixed endings. Rejected:
     rebuilding CRLF in the payload (Edit only, guesses which lines had `\r`), a `PreToolUse`
     disk hash joined by `tool_use_id` (exact, but a second handler plus cleanup), and leaving
     CRLF `:external`.
   - **Residual, pinned by a test:** another writer converts *only* CRLF to LF, then an agent
     edits, inside one quiet period. The coalesced group's baseline converts to the agent's
     `before`, so the agent is also credited with the conversion. A change to any other byte
     keeps the group `:external`.
   - Also from the live check: BOM, non-ASCII UTF-8 and a missing final newline round-trip
     exactly. Edit/Write refuse invalid UTF-8, so such writes come through Bash and stay
     `:external`. Claude Code's `Edit` rewrites a mixed-ending file to one ending, so hunks can
     land on lines the agent didn't target; they are credited to the agent, correctly, since
     its tool wrote them.

2. **`NotebookEdit` reports success as `error: ""`**, not `null` (fixture-verified). Only a
   non-empty `error` sends nothing. This corrects the earlier "non-null `error`".

3. **The payload, `integrations/captainhook/geex-attest.sh`** (POSIX `sh`; jq, curl, and
   `sha256sum` or macOS `shasum -a 256`):
   - Acts only on a `PostToolUse` envelope from `claude-code` for `Write` / `Edit` /
     `NotebookEdit` (`MultiEdit` allowed if a version still has it) with an absolute path and a
     string prior text. A created file sends **nothing**: a message without `before` could only
     be ignored.
   - Discovery: `$XDG_RUNTIME_DIR/geex`, else `/run/user/<uid>/geex`, plus
     `${TMPDIR:-/tmp}/geex-$USER` (`GEEX_ATTEST_DIR` overrides, for tests). It skips a file or
     directory not owned by the user, a `url` not starting `http://127.0.0.1:`, a non-hex token,
     and a dead pid.
   - The token reaches curl as a header on fd 3, never on argv (`ps` shows argv to every local
     user). POSTs run in parallel, each capped at 1 s (0.3 s to connect), and the script waits
     for them before exiting 0 with empty stdout (a Noop). Every failure is fail-open, with a
     note on stderr (captAInHook's trail).
   - Measured against a live `mix geex.serve`: ~3 ms for a non-writer call, ~15 ms for a small
     Edit, ~250 ms for a 2.7 MB file (an 8 MB envelope).
   - **Registration** (the user's step, in `~/.captainHook/handlers.json`): `events
     ["post-tool-use"]`, `mode "oneshot"`, `failMode "open"`, `budgetMs 1500`, `passEnv
     ["XDG_RUNTIME_DIR"]` (captAInHook strips a handler's environment to an allowlist).
   - Tested against captAInHook's real envelopes, copied verbatim to
     `test/fixtures/claude-code/` (captAInHook `3ddb467`).
   - **macOS:** the payload runs there (shasum fallback; the tmp-dir discovery matches
     `System.tmp_dir!/0`'s `TMPDIR`). geex itself has never run on macOS: its watcher's FSEvents
     backend (`file_system`) is untested here.

## Amendment — 2026-10-15: step (e), display only — who wrote this line

Chosen by the maintainer: make attribution visible while editing, with **no undo changes**.
Undoing one agent's hunk without touching later edits needs its own design, because the
ADR-0031 history is linear. Built to the approved mockup:

- **A gutter mark.** `▌` in the line-number gutter's left margin column, in the theme's accent
  (`palette.cursor`; no new palette key), on each line an agent last wrote: an attested write
  (`{:agent, …}`) or an MCP edit (`{:llm, …}`). `:external` (shell, other editors, unattested)
  and your own lines stay unmarked.
- **The author on the status line**, for the line under the cursor, just left of the position:
  `✎ <harness>/<session, 8 chars> · turn <4 chars>…` (MCP: `✎ llm/<model>`). The
  `harness/session8` tag is the one captAInHook's agent-shell-history writes into shell history,
  so one session reads the same in both places.
- **Derived from the history, never stored as line numbers.** `Geex.Blame` (pure) keeps one
  writer per line, `{actor, reconcile group}`, the way `git blame` does: a command writes the
  lines between the common prefix and suffix of the document's lines before and after it. The
  buffer advances it on every applied command, rebuilds it in the same replay undo already does
  (`Blame.replay/2` folds `Dispatch.apply_command/2` like `Dispatch.replay/2`), and relabels a
  group's lines in place when a late attestation lands. So lines shifted by later edits keep
  their mark, an undone hunk loses it, and redo restores it. The snapshot carries it as `blame`.
- **Typing on an agent's line makes it yours** (its mark goes; the maintainer chose `git blame`
  semantics over "marked until the agent's text is gone"). Enter at the end of an agent's line
  marks only the new line.
- **A late attestation repaints at once:** the TUI now handles `{:geex_buffer_attested, …}`.
