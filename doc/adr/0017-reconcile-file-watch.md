# ADR-0017: Reconcile — file-watch + `:external` provenance (the honest floor)

- **Status:** Accepted
- **Date:** 2026-06-04
- **Refines:** [ADR-0012](0012-trust-and-enforcement.md)

## Context

[ADR-0012](0012-trust-and-enforcement.md) made "reconcile (watch the file on disk,
surface divergence — an escape is *detected*, never silent)" a cooperative duty, but left
it design-locked with **no module, process, or UX**. [ADR-0016](0016-external-harness-integration.md)
makes reconcile load-bearing: it is **Rung 0**, the always-on floor under every other
enforcement rung — the only thing that covers (a) a harness that shells out to a script
that writes disk (the gap tool-deny leaves open), and (b) best-effort / out-of-scope
harnesses (Cline, Cursor, aider) that cannot be gated at all. This ADR gives it a shape.

The insight (the author's): geex holds its own copy of the buffer; the disk is an I/O
surface. When something writes the disk behind geex's back, geex can **diff disk against
its `EditorState` and replay the change as `%Command{}`s** — so undo/replay/provenance
still happen. The file-watcher is just **another transport** producing commands, exactly
like the minibuffer or the MCP server.

## Decision

1. **`Geex.Reconcile` — a file-watch GenServer** watches each open buffer's backing file.
   On an out-of-band disk change it diffs the disk text against the buffer's
   [`EditorState`](0014-editor-state-and-dispatch-ownership.md), synthesizes a minimal
   `%Command{}` (a whole-buffer `replace` to the disk content, for now — finer line-level
   diffs pair with the [ADR-0020](0020-diff-edit-tool.md) myers work), and dispatches it
   into the one undo history — **the same path every other edit takes**
   ([ADR-0003](0003-one-shared-path.md)). It targets the *changed file's* buffer (resolved
   by path via `Geex.Registry`), which may not be the active one, so it uses the per-buffer
   chokepoint `Geex.Buffer.dispatch/2` (the gather → apply → scatter → record primitive that
   `Geex.Dispatch.run/1` itself wraps) rather than `run/1`, whose active-buffer resolution
   doesn't fit. After adopting disk content it marks the buffer **synced** (memory now equals
   disk, so it is not dirty — the geex-as-observer post-condition).
   - **Watch mechanism (decided 2026-06-04): the `:file_system` hex library** —
     push-based (inotify / fsevents / inotifywait), the standard BEAM choice (Phoenix
     live-reload uses it), low latency and overhead. This is geex's ~3rd dependency, after
     Bandit/Plug; a hand-rolled poller was the alternative and was rejected as a hack we'd
     replace. (`JSON` and diffing stay built-in.)
   - **Echo-suppression by content comparison (decided 2026-06-04; amended 2026-06-05 →
     compare to the *baseline*):** on a watch event, read the disk and compare to the
     buffer's **`synced` baseline** — the disk content it last loaded / saved / adopted, *not*
     its live (possibly dirty) `EditorState`. **Equal → ignore** (geex's own `save/1`, a
     no-op, or unsaved edits sitting on top of an otherwise-unchanged file); **differ →
     reconcile.** The original "compare to `EditorState`" rule was correct for clean buffers
     but reverted a *dirty* buffer on any spurious event — and on geex's own `rename_file/2`,
     whose moved bytes diverge from the unsaved text. Comparing to the baseline (the
     editor-standard "did the file change underneath me?" test, as in VS Code / Emacs /
     JetBrains) fixes both, and makes a rename echo-suppress for free (the re-keyed buffer
     carries its baseline). Still no separate "I just wrote this" bookkeeping. See the
     2026-06-05 [testing-log entry](../testing.md).
2. **Out-of-band edits are tagged `actor: :external`**, never fabricated as `{:llm, _}` or
   `:human` (ADR-0012: "never fabricates provenance it can't back"). `:external` is added
   to the canonical `Geex.Command.Meta` actor enumeration (the code already carries it;
   [§7](../mcp-ai-integration.md) of the design doc is brought into line).
3. **Surfaced, never silent.** A divergence raises an event consumed by `Geex.Session`
   (and shown in the UI) — geex "never silently desyncs from disk." Reconciled commands
   are normalized (a state-equivalent minimal diff), so provenance is *honest but coarse*
   (it records *what* changed and *that it was external*, not the keystrokes/intent).
4. **Ownership: geex-as-observer is the default for harness-driven files** — disk is the
   truth, geex follows and records. (geex-as-primary, where the buffer is truth and disk
   is output, is the interactive-editing case; it needs "file changed on disk, reload?"
   merge UX. Echo-suppression — a write geex itself just made not being re-ingested as
   `:external` — is handled by the content comparison in point 1.)

## Consequences

- The honest-provenance / never-silent promise of ADR-0012 becomes implementable, and
  ADR-0016's Rung 0 is real rather than aspirational.
- The document undo history stays pure edits; reconcile adds commands through the same
  dispatcher, so undo/replay/collab/provenance all apply to external edits too — at
  save-granularity, coarsely attributed.
- Works with **any** writer (any harness, a human in another terminal, `git checkout`) —
  the universal floor.
- **Cost / risk:** echo-suppression and disk/buffer conflict handling are the sharp edges;
  reconcile must not loop or mis-attribute. Diff→command reconstruction is lossy by nature
  (intent is not recoverable from a result).

### Implementation decisions (surfaced by the build + an adversarial review)

- **Echo/loop freedom is structural.** Reconcile only *reads* disk and dispatches in-memory
  commands — it never writes disk — so it cannot echo its own work. A burst of `:modified`
  events for one write reconciles once, then content-compares the rest to `:ignored`; a
  geex `save/1` produces disk == `EditorState`, so the resulting watch event is ignored.
- **Graceful degradation.** If the watch backend is unavailable (`inotify-tools` not
  installed) `FileSystem.start_link` returns `:ignore`; the watcher logs and no-ops, the app
  still boots, and the **reconcile core stays fully usable** when invoked directly.
- **OTP robustness.** The reconciler traps exits and *both* a worker's `:stop` event and a
  trapped `:EXIT` free its directory for re-watching — the `:file_system` worker survives a
  *normal* backend exit (forwarding `:stop` without exiting), so `:stop` is the authoritative
  cleanup signal, not a following `:EXIT`. A target buffer that dies under the watcher is
  contained as `{:error, {:buffer_down, _}}`, so one buffer's death can't crash the reconciler
  and cascade-kill every linked file-watcher.
- **Lexical path identity.** Watch + event resolution key on the `Path.expand`-ed path,
  matching the buffer-dedup identity ([ADR-0019](0019-file-lifecycle-and-operation-tools.md));
  symlinked aliases aren't canonicalized.
- **Deferred refinements:** close-event filtering / debounce (a non-atomic mid-write read is
  adopted then corrected by the settling event — coarse but undoable); deletion handling (a
  removed file is skipped, not reconciled to empty); conflict-aware "file changed, reload?"
  merge UX (geex-as-primary); finer line-level diffs; surfacing to a UI consumer (today:
  `Logger` + the `:external` command in queryable history). The watcher is feature-gated
  (`:start_reconcile`, on in dev/prod, off under `mix test`).

## Open question — attribution beyond `:external` (leaning **no**, 2026-06-04)

Can a reconciled write be attributed to *who/what* authored it, rather than just
`:external`? It can be *narrowed*, never (for free) to door-grade provenance — a disk
write is a result stripped of intent; "which LLM / prompt / turn" only reaches geex
through a channel geex is on. The spectrum, weakest → strongest:

- **Session correlation** (cheap, circumstantial): "external write *during* harness X's
  active turn." geex already has the session state.
- **OS process attribution** (heavy, platform-specific): Linux `fanotify` reports the
  writing PID (plain `inotify` does not) → `/proc` gives exe/ppid; macOS needs Endpoint
  Security. Privileged, racy, and yields the *process* (`node`/`python`), not the agent
  turn.
- **Cooperative breadcrumbs**: a hook / sandbox-wrapper geex's preset installs tells geex
  "about to shell out" — but that puts geex back *in the loop*.

The deeper point: strong attribution comes from being **in the loop**, so the lever is the
[ladder](0016-external-harness-integration.md) (Rung 2 makes the door the only egress and
the writer self-identifies) — *shrink* `:external`, don't forensically decode it. Whatever
is added, the [ADR-0012](0012-trust-and-enforcement.md) rule holds: never promote a guess
to `actor`; hang any inference off a separate, confidence-tagged field
(`external: %{inferred:, method:, confidence:}`).

**Current lean: no.** Keep `:external` as the honest floor; revisit cheap session
correlation if a concrete need (debugging / audit) appears.

## See

[ADR-0012](0012-trust-and-enforcement.md), [ADR-0016](0016-external-harness-integration.md),
[ADR-0003](0003-one-shared-path.md), [ADR-0014](0014-editor-state-and-dispatch-ownership.md),
[ADR-0005](0005-provenance-on-every-command.md),
[mcp-ai-integration.md](../mcp-ai-integration.md) §7 / §9.


## Amendment — 2026-10-14 ([ADR-0032](0032-listener-first-agent-integration.md))

Reconcile is now the **primary agent path**, not only the floor. The open question above (attribution beyond `:external`) is **answered yes, by attestation, not inference**: a captAInHook `post-tool-use` payload sends `(path, sha256, harness, session, …)` and `Buffer.attest/2` upgrades the matching command's actor from `:external` to `{:agent, …}` on an exact post-state hash match. On no match it stays `:external`; never a guess. The deferred work (line-level diffs, conflict UX) moves onto the v0.5 critical path.
