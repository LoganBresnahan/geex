# ADR-0004: One macro DSL emits a serialization-neutral field-spec

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

A command's argument shape feeds several consumers: the minibuffer parser, the MCP tool
`inputSchema` (JSON-Schema), and the argument validator. Hand-syncing these drifts —
pharos's single most-cited bug is a tool name living in four hand-maintained places.

## Decision

The `Geex.Command` macro emits a **serialization-neutral field-spec** (a plain Elixir
term describing fields, types, docs, defaults) — *not* JSON-Schema directly. Renderers
project that one term to each consumer: JSON-Schema for MCP, the `parse/1` clause for the
minibuffer *and* MCP args, the validator.

## Consequences

- **Define once, derive many** — schema, parser, and validator are generated from one
  source and structurally *cannot* drift. A new arg type is one entry in one mapping table.
- **Cost:** one small rendering module, plus the discipline to keep the spec neutral (no
  welding the command system to JSON-Schema).
- Direction-B *result* schemas stay a **separate role** — params (macro, input role) vs
  results (balance_beam, result role); they share at most a scalar-atom leaf, never a
  renderer ([mcp-ai-integration.md](../mcp-ai-integration.md) §1, §13).

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §3a, §4 (Decision 1).
