# ADR-0010: Disk-truth-only LSP for v0.5

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

§8's in-VM editor-state contract (live `didChange` mirroring + `editor_focus`, so LSP can
answer about *unsaved* edits and "what is the user looking at?") assumed pharos was
co-located in geex's VM. Un-bundling pharos ([ADR-0008](0008-pharos-not-bundled.md)) means
an external stdio pharos cannot read geex's in-VM buffer state.

## Decision

**v0.5 LSP is disk-truth-only.** The §8 in-VM contract is retained as the *target
end-state*, unlocked later by an optional co-location transport swap — **not** by pushing
unsaved-buffer state over the stdio link (that would rebuild pharos's ADR-028 WebSocket
bridge, the exact transport §8 exists to avoid, and pharos has no such ingest today).

## Consequences

- Navigation, references, diagnostics, hover on a *dirty* buffer can be stale until save.
  Tolerable for a v0.5 grid/coordinate editor; a real gap for an AI loop that edits then
  immediately asks the LSP about its own unsaved edit.
- Mitigation (save-then-query discipline / auto-save-shadow) is deferred.
- **Trigger to build co-location:** a feature needs unsaved-state answers **and**
  stdio/warmup is a *measured* bottleneck (roadmap post-0.5).

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §8, §14, §13 (pharos co-location).
