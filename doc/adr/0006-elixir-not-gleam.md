# ADR-0006: Elixir, not Gleam, for the MCP boundary

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

pharos (the reference MCP server we port from) is Gleam — deliberately, because JSON-RPC
is a spec and Gleam's decoders make the envelope type-safe. notes.md reserves Gleam for
geex's *extension API*. So: should geex's MCP boundary also be Gleam?

## Decision

Write geex's MCP boundary in **Elixir**. The source of truth — the macro-generated
schema, the command registry, the dispatcher, the commands themselves — is all Elixir;
the MCP server is glue over those data structures. Putting it in Gleam would force a
language/FFI seam at exactly the hottest point and re-introduce the untyped boundary
Gleam was meant to remove.

## Consequences

- No FFI hop to type-check an ~80-line, ~6-field JSON envelope.
- The macro recovers most of the safety Gleam's compiler would give: schema, parser, and
  handler are generated from one source, so they *cannot* drift
  ([ADR-0004](0004-neutral-field-spec.md)).
- Re-acquire the envelope's type-safety cheaply at runtime: explicit request/notification
  guards, an explicit method catch-all, property tests + typespecs/Dialyzer.
- **Gleam still earns its keep at the third-party extension API** — a genuinely typed
  contract with external authors, where the typed boundary *is* the product feature
  ([ADR-0009](0009-three-tier-extension-model.md)). The MCP server is not that.

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §5.
