# ADR-0032: Listener-first agent integration — agents edit natively, geex records, captAInHook attributes; MCP frozen

- **Status:** Accepted
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
