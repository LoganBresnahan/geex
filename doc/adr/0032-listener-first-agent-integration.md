# ADR-0032: Listener-first agent integration — agents edit natively, geex records, captAInHook attributes; MCP frozen

- **Status:** Accepted (amended 2026-10-14: attestation safety + write completion; 2026-10-18: a
  created file is sent as `created`; 2026-11-09: an attestation credits the group's undone
  commands too, and can match the newest write's group when fully undone; 2026-11-12: a command
  that keeps the line count marks only the lines it changed; 2026-11-13: each agent session's
  marks and edits rows in its own colour; 2026-11-18, accepted 2026-11-19: an agent's Bash
  changes credited "while", not built). For open
  buffers, step b's disk-wins merge and the pending table are superseded by
  [ADR-0034](0034-panes-tree-edits-hold.md) (buffers hold; `git merge-file`; held attestations)
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
     **Amended 2026-10-19:** skipping isn't enough once the OS hands the pid out again. Then
     the stale file looks live, and the payload POSTs its token to a port that may now be
     someone else's. So stale files are removed in two places:
     - **geex, at the attest listener's start, before writing its own file.** It removes only
       a `<digits>.json` that is a regular file (not a link), owned by this user, whose pid
       `kill -0` can't signal (the ledger's stale-lock test). It never touches a live pid's
       file or any other name, and logs one line with the count when it removes any.
     - **The payload**, when it skips a dead pid: only a plain file of ours (not a link) named
       `<that pid>.json`.

     A pid reused by another process of the same user before either sweep runs still looks live;
     the token and the loopback-only URL check are what's left in that window.

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

## Amendment — 2026-11-12: a command that keeps the line count marks only the lines it changed

**Context.** Step (e)'s rule gives a command every line between the common prefix and suffix. A
trim-on-save of a whole file as one replace (ADR-0054 §4), or Tab over a selection with a blank
line in it (ADR-0050 §3), would then claim lines it left as they were: every line between the
first and last it touched. mod-verify's review of `save-undo` found the per-line commands that
avoided this quadratic (20,000 lines took 29 s), and the coordinator chose one replace and a
finer blame.

**Decision.** After the common prefix and suffix, when the middle has as many lines after the
command as before, a line the command left equal keeps its writer, position by position; only
the lines that differ take the command's. A middle that grows or shrinks is marked whole, as
before. Still linear in the lines, still pure (`Geex.Blame.step/4`). Blame is derived, so a
history replayed (an undo, a reopened ledger, a checkpoint's base) gets the finer marks too: a
checkpoint's stored `base_blame` keeps the marks it was written with.

**Consequences.** A trimming save, Tab and Shift+Tab over a selection, and any replace that
rewrites a block line for line mark only the lines they changed. An older history's blame can
become finer on replay; nothing stored changes.

## Amendment — 2026-10-18: a file the agent creates is sent, as `created`

The maintainer watched an agent create files with an edits pane open and saw none of them listed.
The payload sent nothing for a created file (step d above: "a message without `before` could only
be ignored"). Since the edits pane (ADR-0034 §6) lists an attestation for any file, open or not,
with no hash match needed, a created file has a use after all. Relayed by the coordinator session.

- **The payload** sends a `Write` whose `tool_response.type` is `"create"` and whose
  `originalFile` is `null` (the `write-create.jsonl` fixture) as `"created": true`, with no
  `before`. Any other writer with no prior text still sends nothing.
- **The intake** (`Geex.Attest.parse/1`) takes `created` (a boolean; given with `before`, the
  message is rejected) and sets `before` to the empty text's sha256. So:
  - the edits pane lists the file as the agent's;
  - a buffer open on the path credits the write only if it held nothing (a fresh buffer on a
    path that didn't exist), by the usual both-hashes rule or the spool's chain rule;
  - a buffer that held text can't link it, so the change stays `:external`. Still fail-safe.
- **The spool** reads a `created` line the same way (`before` = the empty text). A created file
  has no ledger, so this only arises when the agent recreates a file geex once kept one for.
- A message with neither `before` nor `created` (an older payload) is still accepted and still
  ignored by a buffer.

## Amendment — 2026-11-09: an attestation credits the group's undone commands too

An attestation credits a reconcile group as a whole, including the group's commands that are
undone and waiting on the redo stack, so step (e)'s "an undone hunk loses its mark, and redo
restores it" also holds after a late attestation (BUG-8, [bugs.md](../bugs.md), found by a
property test, [ADR-0044](0044-property-tests-with-stream-data.md)):

- **Which group a late attestation may match.** The newest undone group (its commands on the
  redo stack, everything there being newer than everything applied), then the newest applied
  group, which was the only one before. Both hashes must match, as always; the first that
  matches **and is still unattested** is credited, once, so an attested undone group with the
  same hashes never shadows the applied one. So an attestation that lands after the user undid
  every hunk of the agent's **newest** write still credits it, and one for the newest applied
  group still matches while a newer group is undone (`History.attestable_groups/1`,
  `Buffer.attest/2`). Only the newest undone group is tried: undo two groups in full, and a late
  attestation for the older one is held and lost, as "only the newest group" already said.
- **What crediting does.** `History.attest/3` relabels the group's commands, applied and undone,
  and its lines, including those a compacted ledger's checkpoint carries for commands it folded
  in (`base_blame`, which an undo rebuilds the blame from; BUG-9); `unattested?/2` counts applied
  and undone commands, so a repeat attestation is ignored either way. A group whose every command
  a compaction folded into the checkpoint has no stamp left, so a late attestation can't find it.
- **Revised the same day.** The first version relabelled undone commands but matched only the
  newest applied group, so a fully undone group stayed `:external`; a verify pass (session
  geex-d3) found it. Its recheck found the second version stopping at the first matching group
  even when attested (`:ignored`), which lost a credit the first version gave; hence "still
  unattested".

## Amendment — 2026-11-13: each agent session in its own colour

The maintainer, 2026-11-13: a colour per agent session (roadmap item 8's first idea), "in the
edits list as well so entries are color coated".

- **The colour comes from the writer, never from timing** (invariant 6). Only an attested
  writer (`{:agent, %{harness, session, …}}`) or an MCP edit (`{:llm, name}`) has one;
  `:external`, `:human` and a line as loaded get none and no mark, as before.
  `Geex.Theme.agent_colour/2` hashes the harness and the session id (`:erlang.phash2`) into
  the theme's agent colours, so a session keeps its colour across frames and restarts.
- **The colours are the theme's own:** `Geex.Theme.agent_colours/1` takes the foregrounds of
  `keyword`, `string`, `function`, `type`, `number` and `tag`, each once, leaving out the
  theme's foreground and background. They are drawn readable on the background by every theme
  already. Under the terminal theme they are ANSI colours (magenta, green, blue, cyan, yellow),
  never truecolor, and none is red; a theme whose keywords or tags are red (gruvbox's keyword,
  One Dark's and Tokyo Night's tag) gives that red too, so a session can be drawn red there.
  Whether to filter reds out is left to the maintainer. A theme with none of the captures gives
  its cursor colour, the old mark colour.
- **Where:** the gutter's `▌` (`Loop.agent_marks/5`) and the edits pane's who column for an
  agent row (`EditsPane.who_at/3` says where the column is); the rest of the row keeps the
  pane's foreground, and the focused, highlighted row keeps the accent.
- **Two sessions can share a colour** (five colours under the terminal theme): the status line
  and the edits row still name the session. Blame stays pure; the colour is chosen at paint.


## Amendment — 2026-11-18: an agent's Bash changes, credited "while"

*Drafted at the maintainer's ask ([geex#3](https://github.com/LoganBresnahan/geex/issues/3), roadmap
item 8's "Labelling shell writes"), reviewed by mod against stack.md and captAInHook's contract,
accepted 2026-11-19 with the maintainer's answers below; not built.*

**The gap.** A file an agent changes through its Bash tool (`sed -i`, a formatter, a generator,
`git checkout`, a script) stays `:external`: a Bash response carries stdout and stderr, no file
and no text from before, so the payload has nothing to hash. captAInHook's ADR-0019 addendum
names the way: a before-hash from "a PreToolUse snapshot the payload takes itself".

**What a hash can and can't prove here.** For Write and Edit the harness reports the text its own
tool read and wrote, so a match proves the tool wrote the file. Around a Bash call the payload
can only bracket the call in time: a match proves **the file went from X to Y while the call
ran**, not that the command did it. A `--watch` build, another editor or a subagent writing in the
same window would match too. Invariant 6 forbids inferring an actor from timing, so this credit
**never claims authorship: it says "while"**. It is still hash-proved (both hashes, exactly, as
every attestation), and a wrong, late or duplicate claim still leaves the change `:external`.

1. **A PreToolUse step in the same payload.** `geex-attest.sh` gains a second registration, on
   `PreToolUse`, and tells the two apart by the envelope's `type`. On a `claude-code` `Bash` call
   it takes a **snapshot** of each git work tree the call may touch: the sha256 of every file
   `git status --porcelain=v1 -z --untracked-files=normal` names there (modified, staged,
   untracked; "absent" for a deleted one), with the session, the roots and the time, in
   `<discovery dir>/bash/<tool_use_id>.snap` (`0600`, the directory `0700`). A subdirectory,
   because the payload and geex read the discovery directory's `*.json` as live instances.
   **The work trees** are the one holding the envelope's `cwd`, plus the one holding each
   directory the command names with `cd DIR` or `git -C DIR`, and each absolute path in it. Agents
   often work in another worktree (`cd ~/geex-tonight && python3 - <<'EOF' …` is a common shape
   in the transcripts), and the envelope's `cwd` is the session's, not the command's. Reading the
   command only chooses **where to look**, never who gets the credit: a change still has to match
   both hashes, so looking in one more place can't make a wrong claim, only cost one more
   `git status` (within the same time budget). At most a few work trees per call; past the
   budget, the rest are skipped.
   **It always exits 0 with empty stdout**: a PreToolUse answer can approve or deny the call,
   and this one must never steer (captAInHook ADR-0010: empty stdout is a Noop, and its merge is
   first-deny-wins, so a recording handler can neither approve nor deny). **It sits in the
   call's critical path:** its time budget is latency added to every Bash call. captAInHook
   registers a handler by event, not by tool, so the script runs on every tool call's
   PreToolUse and exits at once for anything but a `claude-code` `Bash` call (a cheap check of
   the envelope before `jq`). captAInHook's own `budgetMs` and `failMode` "open" are the outer
   guard on the payload's budget. Snapshots older than an hour are removed (a denied call never
   reaches PostToolUse).

2. **The PostToolUse step compares.** On the same call's PostToolUse it runs `git status` again
   and takes the union of the snapshot's paths and the new list. For each path:
   - **before** is the snapshot's hash; for a file that was clean, git's index copy as a
     checkout would write it (`git cat-file --filters`), so line-ending conversion and filters
     don't make the hash miss; "absent" makes it `created`;
   - **after** is the disk now; a path that no longer exists sends nothing (geex has no deletion
     attestation);
   - equal hashes send nothing; otherwise the **existing v1 attestation** goes out, POSTed and
     spooled exactly as a Write's, with two new optional fields:
     `"during": "Bash"` (the tool; present only on a credit by time) and `"program"` (the name
     of the program the command runs: its first word past any `cd …`, `env`, `export` or
     `VAR=value`, as a basename: `sed`, `python3`, `prettier`, `git`). Only the name, never the
     command line: a command can carry a token, and the ledger and edits list are durable.
   The snapshot is then removed. No snapshot (the PreToolUse step didn't run, timed out or isn't
   registered): nothing is sent, as today.

3. **geex shows it as "while".** `Geex.Attest.parse/1` keeps `during` and `program`; the
   message stays `v: 1` (older geex versions aren't a concern, the maintainer, 2026-11-19). The
   matching is unchanged. The actor carries them, so
   the blame, `revert-call` and replay work as for any credit, and the display says what was
   proved:
   - the status line: `✎ claude-code/1a2b3c4d · turn … · while python3`;
   - the edits pane's who column: the session, then `(while Bash)`;
   - the gutter: a lighter `╎` in the session's colour in place of `▌`, so a weaker claim reads
     as one at a glance (`▌` stays for a credit "by");
   - `revert-call` takes back the call's changes in the file, which is what undoing a bad `sed`
     wants; on a credit "while" that is everything that changed in the file during the window
     (see Limits). Every revert now shows what it takes back first
     ([ADR-0033](0033-durable-ledger.md)'s amendment of this date).
   A spool chain that mixes a Bash link with a Write link of the same session is credited
   "while" (the weaker claim wins). [ADR-0033](0033-durable-ledger.md)'s amendment of this date
   keeps the fields in the ledger and the spool.

4. **Limits, all misses rather than wrong claims:**
   - The PreToolUse step runs **before the permission prompt**. In a mode that asks, anything
     written while the human decides falls inside the window and is credited "while". The label
     keeps that honest; geex's own saves never produce an `:external` change, so they are never
     swallowed.
   - **Background Bash** (`run_in_background`): its PostToolUse comes at launch, so the payload
     sends nothing for it and removes the snapshot. Its changes still reach geex as reconcile
     sees them: recorded `:external`, in the edits pane, undoable, just not credited.
   - **Overlapping calls** (parallel tool calls; subagents run asynchronously but carry the
     parent's session id, Claude Code 2.1.328): a change in the overlap is claimed by both, and
     the first attestation to arrive takes it. Both labels are true.
   - **A work tree the command reaches some other way** (a variable, `pushd`, a script that
     changes directory itself) isn't snapshotted, so its changes are missed.
   - **Outside a git work tree, ignored files, files inside an untracked directory that
     `--untracked-files=normal` shows as one entry, files outside the repository:** no credit.
     The softer, unproved "changed while" for any open file in the window (roadmap item 8) stays
     a later step, if ever.
   - **`revert-call` on a credit "while" reverts the window,** not just the command: a
     `--watch` build's or another editor's change to the same file in the same window goes too.
     The revert's preview (ADR-0033's amendment) shows it before anything changes.
   - **Cost:** a `git status` (plus hashing the files it names) before and after every Bash call.
     Measured on a large repository before it ships; past a time budget the step skips quietly
     (fail-open, as the rest of the payload).

5. **What the maintainer does:** adds `"pre-tool-use"` to the existing `geex-attest` entry's
   `events` in `~/.captainHook/handlers.json` (same script, `failMode` "open", `passEnv` with
   `XDG_RUNTIME_DIR`, and `XDG_STATE_HOME` if set); geex gives the exact entry and a `budgetMs`
   from the measurement. Never edited by geex.

6. **Tests:** the payload against the verbatim `test/fixtures/claude-code/bash.jsonl` (PreToolUse
   and PostToolUse, Claude Code 2.1.299) in a scratch git repository: a `sed -i` on a clean file,
   a modified file, a created file, a deleted file, a CRLF file under `core.autocrlf`, a denied
   call's stale snapshot, a background call, no snapshot, no git, a `cd` into a second work tree,
   a `git -C` and an absolute path; geex's parse, display, ledger
   and spool with `during`; and a live run with a real Claude Code session.

**Wording elsewhere** (both the maintainer's to decide; stack.md its owner's to change). The rule underneath: timing may only ever produce a credit "while", and a credit "while"
is never shown as "by".
- stack.md rule 3, replacing its last sentence (mod's wording): "A shell call that changes files
  is bracketed instead: the payload hashes the work trees before and after the call and attests
  each changed file as `during` that call, a weaker claim that it changed while the call ran. No
  tool infers authorship from timing (geex invariant 6): a bracketed credit says "while", never
  "by", and nothing is credited outside a call's own window."
- CLAUDE.md invariant 6: "Attribution comes only from an attestation that matches the exact
  content hash; a Bash call's attestation is bracketed by its window and is shown as "while",
  never "by"."

**Alternative, complementary:** the transcripts suggest Claude Code's bypass-mode prompt pushes
agents toward shell edits. `presets/claude-code` could ask agents to prefer Edit and Write for
file changes, which earns a full "by" credit at no cost. It doesn't replace this: other modes,
harnesses, formatters and scripts still change files through the shell.

**Decided 2026-11-19 (the maintainer):**
1. **The words:** "while" on the status line, `(while Bash)` in the edits pane.
2. **The gutter:** a lighter `╎` in the session's colour for a credit "while".
3. **The command text:** only the program's name (`program`), never the command line (mod's
   suggestion).
4. **Background Bash:** skipped; its changes stay `:external` (Limits).
5. **Older geex versions** aren't a concern: the message stays `v: 1` with optional fields,
   the simplest form for the new work.
6. **Every revert shows what it takes back first**, for any credit, not only "while"
   ([ADR-0033](0033-durable-ledger.md)'s amendment of this date).

The time budget isn't a question: the PreToolUse step runs before every tool call and holds
the agent until it ends, so it gives up on a call (a missed credit) rather than slow the agent.
The number comes from measuring `git status` on a large repository at build time.

*Checked at build time, not a question:* whether the envelope's `cwd` follows a `cd` an earlier
Bash call left in Claude Code's shell. The work-tree rule in step 1 covers both answers.
