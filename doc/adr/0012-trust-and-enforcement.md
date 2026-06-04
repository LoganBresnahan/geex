# ADR-0012: Trust & enforcement — cooperative vs enforced

- **Status:** Accepted
- **Date:** 2026-05-28
- **Amended by:** [ADR-0016](0016-external-harness-integration.md) (the cooperative grant
  becomes a concrete per-harness preset; the binary becomes a ladder; "enforced" splits
  into Rung 2 OS-sandbox / Rung 3 WASM), [ADR-0017](0017-reconcile-file-watch.md) (reconcile
  gets a module shape)

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
  (containerizing claude-code-the-Node-process is the wrong layer). **An *OS* sandbox,
  however, is the right layer for that same process** — see the ladder in
  [ADR-0016](0016-external-harness-integration.md), which splits this ADR's single
  "enforced" regime into Rung 2 (OS-sandbox, for external harnesses) and Rung 3 (WASM, for
  geex's own in-VM guests).

## See

[vision.md](../vision.md) §5, [mcp-ai-integration.md](../mcp-ai-integration.md) §9,
[ADR-0009](0009-three-tier-extension-model.md).
