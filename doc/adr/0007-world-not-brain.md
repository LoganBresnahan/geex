# ADR-0007: geex owns the world, not the brain

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

In other editors, LLM integration is plugins/extensions each doing their own agent
orchestration. The question: should geex *also* be an agent-orchestration platform?

## Decision

**No.** geex owns the editor **world** — buffers, the shared command path, undo / replay
/ collab / provenance, the extension & capability substrate. The **brain** — planning,
ReAct, tool-selection, context-window management, cost budgeting, scheduling, signal
buses — is **bring-your-own**. An agent is just a typist; geex doesn't own how it decides
what to type.

## Consequences

- geex stays out of a crowded, fast-churning space (agent frameworks) and focuses on the
  one thing only it can provide: the shared, attributed, reversible path.
- Gives the **decision test** for everything: *is X about the editor's world or the
  agent's brain? World → geex owns it. Brain → geex exposes a clean surface and stays out
  of the way.*
- Implies geex needs only a *thin slice* of any LLM library — the structured-output
  technique at Direction-B call sites — not a whole framework
  ([ADR-0011](0011-direction-b-balance-beam.md)).

## See

[vision.md](../vision.md) §3, [mcp-ai-integration.md](../mcp-ai-integration.md) §0.5.
