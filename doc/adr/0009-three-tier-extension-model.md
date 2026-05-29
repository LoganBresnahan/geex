# ADR-0009: Three-tier extension / capability model

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

Extensions and capability providers arrive with different trust levels: out-of-process
providers (pharos), untrusted third-party code, and trusted first-party code. They need
one coherent model, not three ad-hoc integrations.

## Decision

Three tiers, **all funnelling to the one dispatcher** ([ADR-0003](0003-one-shared-path.md)):

1. **MCP-client connection** — out-of-process capability provider (pharos LSP, other MCP
   servers). Process boundary is the sandbox. A *capability provider*, not a writer.
2. **WASM / wasmex extension** — untrusted in-VM code (the Zed model). Host export surface
   bottoms out at `Dispatch.run/1`; no File/sockets/`Code.eval`/raw PIDs.
3. **Native BEAM extension** — trusted first-party, Gleam-typed API, full Layer-1 access.

No tier writes buffers; each produces a schema-validated `%Command{}` and runs it through
the dispatcher.

## Consequences

- The **trust ladder gates code execution; the dispatcher gates capability** — they
  compose. Provenance distinguishes `{:extension, id}` from `{:llm, _}` / `:human`.
- Each tier is added when a **named consumer** exists — tier 1 (pharos) in v0.5; tiers 2–3
  post-0.5, gated on a real untrusted/third-party extension author.
- WASM containment is for *in-VM extension code*, not for wrapping an external CLI
  ([ADR-0012](0012-trust-and-enforcement.md)).

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §14.
