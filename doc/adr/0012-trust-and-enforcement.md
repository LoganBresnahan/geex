# ADR-0012: Trust & enforcement — cooperative vs enforced

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

The shared-path guarantee ([ADR-0003](0003-one-shared-path.md)) only covers edits that
*enter through geex*. An external agent (claude-code with raw file tools) can edit a file
on disk directly, bypassing the buffer entirely. geex cannot force such an agent through
its dispatcher.

## Decision

Enforcement is a property of the agent's **capability grant**, not something geex imposes
on a client. Two legitimate regimes:

- **Cooperative** (external agent): scope its tools — give it geex's MCP tools, withhold
  raw file write — so the door is the only way in. geex's duties: **honest provenance**
  (out-of-band edits are `:external`, never fabricated) and **reconcile** (watch the file
  on disk, surface divergence — an escape is *detected*, never silent).
- **Enforced** (in-VM agent / wasmex extension): the agent lives inside geex; the
  dispatcher chokepoint + PID-as-capability + the wasmex sandbox make the path structural
  — there is no other door.

## Consequences

- geex never fabricates provenance it can't back, and never silently desyncs from disk.
- Hard enforcement requires either scoping an external agent's tools **or** hosting the
  agent inside geex — a decision made *where the agent lives*.
- WASM containment is for *code running in geex's VM*, not for wrapping an external CLI
  (containerizing claude-code-the-Node-process is the wrong layer).

## See

[vision.md](../vision.md) §5, [mcp-ai-integration.md](../mcp-ai-integration.md) §9,
[ADR-0009](0009-three-tier-extension-model.md).
