# ADR-0008: pharos not bundled; geex is an MCP client

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

geex needs LSP. An earlier framing co-located pharos in-VM as *the* LSP backend. But that
couples release builds, makes pharos a hard dependency, and forecloses the general
"connect to any capability provider" axis.

## Decision

**pharos is not bundled.** geex is an MCP **client** that connects out, over stdio, to
independently-shipped MCP servers (pharos for LSP, others) — *in addition to* being an MCP
**server** (Direction A). pharos is one capability connection among many, versioned and
shipped on its own.

## Consequences

- Independent versioning; the general "connect to any MCP server" axis; no release
  coupling; pharos (or any LSP-MCP server) is user/config-supplied.
- **Cost:** v0.5 LSP is disk-truth-only ([ADR-0010](0010-disk-truth-lsp-v05.md)); a small
  new MCP-client subsystem (connection config, process-per-connection supervision, a
  capability registry distinct from the command registry).
- Generalizes into the three-tier extension/capability model
  ([ADR-0009](0009-three-tier-extension-model.md)). Co-location remains reachable later
  as a transport swap, not a rewrite.

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §14, §13 (pharos co-location vs subprocess).
