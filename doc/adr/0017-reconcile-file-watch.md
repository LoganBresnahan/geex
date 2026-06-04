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
   `%Command{}` sequence, and runs it through `Geex.Dispatch.run/1` into the one undo
   history — **the same path every other edit takes** ([ADR-0003](0003-one-shared-path.md)).
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
   merge UX and **echo-suppression** so a write geex itself just made is not re-ingested
   as `:external` — a build prerequisite, tracked, not solved here.)

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
