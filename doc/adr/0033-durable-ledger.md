# ADR-0033: The durable ledger — an append-only history log per file, and per-agent revert

- **Status:** Accepted 2026-10-15 (decisions A–F as recommended; not yet built)
- **Date:** 2026-10-15
- **Relates to:** [ADR-0005](0005-provenance-on-every-command.md) (provenance on every command),
  [ADR-0014](0014-editor-state-and-dispatch-ownership.md) (the buffer owns the one history; it
  was ephemeral by design), [ADR-0031](0031-undo-redo-history-operations.md) (undo/redo as
  history operations, replay-from-base), [ADR-0032](0032-listener-first-agent-integration.md)
  (attestation by content hash; the step (e) blame), [ADR-0002](0002-commands-as-values.md) /
  [ADR-0004](0004-neutral-field-spec.md) (commands are serializable values),
  [ADR-0017](0017-reconcile-file-watch.md) (out-of-band writes enter history)

## Context

ADR-0032 made geex's one history the record of who wrote what, and its step (e) shows that on
screen. All of it lives in ERTS memory. Quitting (`Ctrl-X` stops the VM; it doesn't even check for
unsaved changes), a crash, or closing a buffer loses the history, the blame, and any unsaved
edits. The files on disk are the only durable state. For an editor whose point is provenance,
that's the gap.

`doc/notes.md` § "Persistence & durable state" already framed this as "decide before v1" and
leaned toward an append-only command log replayed through the existing machinery, not a
snapshot blob. The last open v0.5 exit criterion, **undoing one agent's change without touching
your later edits**, also changes the history model. Both are decided here so the model changes
once.

The constraints are the sacred invariants: one shared path (every mutation is a `%Command{}`
through dispatch), provenance on every command, a pure core with deterministic replay,
attribution only by content hash (never by timing), and world-not-brain.

## Decision

### 1. One append-only ledger per file, as JSON Lines, outside the repo

- **Where:** `$XDG_STATE_HOME/geex/ledger/` (default `~/.local/state/geex/ledger/`), directory
  `0700`, files `0600`. One file per buffer path, named by the first 16 hex characters of the
  sha256 of the absolute path (`<key>.jsonl`); its header records the path.
- **Not a `.geex/` directory in the repo.** The ledger holds file contents, including text you
  deleted (a secret pasted and then removed stays in it). A directory inside the repo invites
  committing it.
- **Plain JSONL, no new dependency.** Append-only matches the model, a torn last line is easy to
  detect, and it greps alongside captAInHook's trail, which is also JSONL. Rejected: SQLite (a NIF
  dependency to store an append-only list); `:dets` / CubDB / mnesia (opaque files, no gain for a
  single-writer log); the §15c cassette format (Elixir terms loaded with `Code.eval_file/1`, which
  executes code, and isn't appendable).
- Scratch buffers (no path) aren't logged.

### 2. An entry is one history transition

| `t` | when | carries |
|---|---|---|
| `open` | first line | `v`, path, the base text and its sha256, geex version, `at` |
| `cmd` | a dispatched command | `name`, `args`, `meta` |
| `group` | an atomic group (reconcile hunks, a revert) | its commands; plus the disk text, only when the group leaves the buffer dirty (the step (b) merge), so `synced` can be rebuilt |
| `undo` / `redo` | Alt+Z / Alt+Shift+Z | nothing |
| `attest` | an attestation took effect | group id, actor |
| `sync` | disk now matches the buffer (save) | sha256 of the bytes on disk (the hash reconcile stamps) |
| `rename` | the buffer moved | new path (the ledger file moves with it) |
| `close` | clean close | sha256 of the buffer text (checks replay) and of the synced disk bytes |
| `gap` | reopen found the disk changed (§4) | a `group` marked as a gap |
| `checkpoint` | compaction (§6) | text, blame, synced text; replaces everything before it |

- **Commands serialize as values** (ADR-0002/0004): `args` is the struct's field-spec fields, and
  decoding goes through the registry's real `parse/1`, the way the cassette test rebuilds
  commands. `meta` carries the actor as tagged JSON (`{"agent": {harness, session, turn,
  tool_use}}`, `{"llm": model}`, `"human"`, `"external"`), `at` as ISO-8601, and the reconcile
  stamp.
- **Only what took effect is logged.** A pending attestation is not; the `attest` entry it
  produces when it matches is.
- **Group ids become durable.** Today they come from `System.unique_integer/1`, which repeats
  across restarts. They become a per-ledger counter (on load, next id = highest seen + 1).
- **Blame is never stored** (except in a checkpoint). It is derived from the history, so replay
  brings it back exactly.

### 3. One transition function, live and on replay

Today undo, redo, attest and sync are `handle_call` bodies in `Geex.Buffer`. They move into a
pure history value, `Geex.History` (base, history, redo, blame, synced, group counter), with
`dispatch/2`, `group/3`, `undo/1`, `redo/1`, `attest/3` and `sync/1`. The buffer applies a
transition, then appends that same transition to the ledger; reopening folds the ledger's
entries through the same functions. The tested invariant: **restoring a ledger yields the same
history value the live buffer had** after any sequence of transitions.

### 4. Reopening joins by content hash, the same rule as attestation

On open, geex replays the ledger, then hashes the file on disk and compares it with the
**replayed synced hash**: the synced state after replay, not merely the last `sync` entry. A
reconcile group that leaves the buffer clean also moves `synced` (to the disk bytes it read, its
stamped `sha256`). Otherwise an agent edit reconciled into a clean buffer, followed by a crash
before any save, would look like a disk change and be applied a second time as an uncredited gap.
That case gets a test.

- **Disk matches the replayed synced hash:** restore as is. If the replayed text differs
  from it (unsaved edits at a quit or crash), the buffer opens **dirty, with those edits back**,
  and the status line says so.
- **Disk differs:** something changed the file while geex was closed. geex restores the history,
  then records the difference as one `:external` group marked as a gap ("changed while geex was
  closed"), merged with the step (b) rule (disk wins overlaps, and you're told). Never a silent
  rebase. Never credited to anyone: no attestation can match it, because the hook got `not_open`
  at the time.
- **No ledger, or an unreadable one:** today's behavior, a fresh base from disk. A corrupt
  ledger is moved aside (`<key>.jsonl.corrupt-<time>`), never deleted.

### 5. Crash safety and verified replay

- **Write:** the buffer process appends each entry as it applies the transition, in one write
  (raw file, append mode). One transition is one line, so a group is atomic. That survives a
  geex crash or kill.
- **fsync** at most once a second while entries are pending, and on save and close. A power loss
  can cost up to about a second of history, never earlier entries.
- **Load:** a final line that isn't complete JSON is a torn write: it is dropped and the file
  truncated to the last good line. Any other unreadable or unknown entry (`v`, `t`) stops replay
  there. Everything before it is restored, the rest is moved aside, and the reopen continues as
  in §4.
- **Replay is checked, not assumed.** Replay re-runs each command's `run/2`, and a command whose
  meaning changes between geex versions could replay differently (the `Edit` command resolves
  its search blocks at run time). So `sync` and `close` carry hashes and replay checks them
  there. A mismatch stops at the last verified point and continues as in §4.
- **Disk bytes and buffer text are the same bytes.** Save writes the text verbatim
  (`File.write/2`), so the hash of the text and the hash of the saved file agree. A reopen test
  on a CRLF file with a BOM and no final newline pins that: it must find no gap.
- **Two geex instances on one file:** the first takes `<key>.lock` (its OS pid; a dead pid is
  stale). The second edits that file without a ledger and says so on the status line.

### 6. Growth and retention

- About 200 bytes per keystroke: 10,000 edits is about 2 MB. **Nothing is deleted
  automatically.** Provenance is the point.
- A `checkpoint` entry (text, blame, synced text) allows compaction: `mix geex.ledger compact
  <file> [--keep N]` replays to N entries before the end, writes a checkpoint plus the last N
  entries to a new file, and renames it over the old one. Who wrote what survives, because the
  blame is in the checkpoint; only undo steps before it are lost.
- `mix geex.ledger forget <file>` deletes a file's ledger (secrets). `mix geex.ledger list`
  shows ledgers by path, including orphans whose file moved outside geex.

### 7. Per-agent revert: a new forward edit, never a history rewrite

- **Undo stays linear** (ADR-0031). Taking back one agent's change from the middle of the
  history is a **revert**, like `git revert`: geex computes the edit that returns the agent's
  lines to what they were, against the current text, and dispatches it as a new group through
  the one shared path. The actor is `:human`, with `meta.reverts = %{group, hunk}`. The history
  stays append-only, and replay stays deterministic because the recorded group holds concrete
  `replace` commands.
- **Granularity:** the hunk under the cursor, or the whole tool call (the agent's reconcile
  group). Proposed: `Alt+R` reverts the hunk under the cursor; minibuffer verbs `revert` and
  `revert-call`.
- **Mechanism:** replay to just before and just after the agent's group (`T_before`, `T_after`),
  then three-way merge with `Geex.Edit.Merge`: base `T_after`, ours the current text, theirs
  `T_before`, limited to the chosen hunk(s).
- **When your later edits overlap the agent's lines: refuse, and name the lines.** A partial
  revert leaves text nobody wrote; the step (b) rule (the revert wins) would throw your later
  edits away. A whole tool call is all-or-nothing.
- **Blame:** the reverted lines are yours (you chose to revert); the status line can say
  `reverted claude-code/7ccbf3d1`. To take a revert back, revert it, or undo it if it's the
  newest change.

### Out of scope

- **Agent writes to files geex doesn't have open, or made while geex is closed,** are still not
  recorded as they happen (the hook gets `not_open`). Reopening records them only as a gap,
  which decision F below can credit. A headless geex that keeps ledgers for files nobody has
  open is a later question.
- View state (cursor, scroll, which buffers were open): small and separate, later.
- Syncing ledgers across machines, or sharing them with a team.

### Join keys

The ledger stores an agent actor's ids as given, so they join to other records with no new
coupling:

- **`session`** joins captAInHook's trail (`sessionId`) and shell history, where
  agent-shell-history writes `harness/session8` (`# agent:claude-code/56544d6f`).
- **`turn` and `tool_use`** join Claude Code's own session transcript,
  `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` (`promptId` on user rows; the `tool_use`
  block's `id`). captAInHook's trail records neither (verified: zero rows). The transcript is the
  better join anyway, because it holds the conversation: the why behind an edit.
- **Key on `session`, never on a session's display name.** The session id survived context
  compaction and peer-session renames in testing (`oof-af` → `oof-41` kept `7ccbf3d1`; `geex-91` →
  `geex-5e` kept `d25a8b6d`).
- **A turn isn't always a human prompt.** One verified turn was a cross-session message from
  another agent. The ledger stores it as is; the UI says "turn", never "your prompt".

## Consequences

- Quitting, a crash, or closing a buffer no longer loses history, blame, or unsaved edits (up to
  about a second on power loss). Undo reaches back across sessions.
- **The sacred invariants hold.** A revert is a command group on the shared path; `Geex.History`
  is pure; replay is deterministic and now verified against hashes.
- **A new on-disk format,** versioned (`v: 1`). Changing it needs an amendment.
- `Geex.Buffer` is refactored: its history transitions move to the pure `Geex.History`, with no
  behavior change. That's the first build step.
- Opening a file replays its ledger: O(history × lines), the same cost undo already pays.
  Checkpoints bound it.
- The ledger is as sensitive as the files plus everything ever deleted from them: `0600`, outside
  the repo, and `forget`.

**Build order:** (1) extract `Geex.History` (no behavior change); (2) the ledger
codec, write path, and restore with the hash join; (2b) the spool, if F is accepted; (3)
per-agent revert; (4) the `compact` / `forget` / `list` tasks.

## Decisions (maintainer, 2026-10-15)

All six were taken as recommended. F includes credit for a run of edits from one session
(the maintainer's point: agents usually edit a file several times in a row).

| | Question | Decided | Rejected |
|---|---|---|---|
| A | Revert when your later edits overlap | **Refuse and name the lines** | Revert only the non-overlapping hunks; let the revert win (your edits one undo away) |
| B | Where ledgers live | **`~/.local/state/geex/ledger/`** | A `.geex/` directory per repo |
| C | fsync | **At most once a second, plus save and close** | Every entry (slower typing); only save and close (a crash between saves loses more) |
| D | Retention | **Keep everything; compact by hand** | Compact automatically above a size |
| E | Revert keys | **`Alt+R` and verbs `revert` / `revert-call`** | Other bindings |
| F | Credit agent writes made while a file isn't open | **Yes, as build step 2b: a hash-only spool, including a same-session run of edits** | Later; or never (gaps stay `:external`) |

**F, the spool (proposed by the coordinator).** When `geex-attest` gets `not_open` from every
geex, or finds none running, it appends the attestation (path, before, sha256, harness,
session, turn, tool_use: hashes and ids, no content) to a `0600` spool,
`$XDG_STATE_HOME/geex/spool.jsonl`. On reopen, a gap is credited only by exact hashes, never
timing:

- **One write:** a spooled entry's `before` equals the replayed synced hash **and** its `sha256`
  equals the disk hash.
- **A chain** (the usual case: one session making several Edits to a file in a turn): entries
  that link exactly, synced → `e1.sha256 = e2.before` → … → disk, **all from the same harness and
  session**. The whole gap is credited to that session as one group. The spool holds no
  intermediate text, so the gap can't be split into per-write hunks, but "who" doesn't need
  them. The actor carries the last write's `turn` and `tool_use`, and the gap's stamp lists
  every `tool_use` in the chain.
- **Anything else** (a missing link, or links from different sessions) stays `:external`.

Entries are removed when consumed and expire after a TTL. It changes only geex's own payload;
captAInHook is untouched.

## See

`doc/notes.md` § "Persistence & durable state"; `lib/geex/buffer.ex` (the transitions to
extract); `lib/geex/blame.ex` (derived blame); `lib/geex/edit/merge.ex` (the merge the revert
reuses); `test/geex/cassette_test.exs` (commands rebuilt through `parse/1`).
