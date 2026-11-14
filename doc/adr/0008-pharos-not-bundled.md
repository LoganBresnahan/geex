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

## Amendment — 2026-11-13: the stack, and pharos on trial

The decision stands: geex reaches pharos as an MCP client over stdio. Two things are new since.

- **The client joins pharos's shared daemon.** pharos now runs one daemon per version (pharos
  ADR-034); each `pharos` process is a thin front end relaying a session's stdio to it. So geex
  and an agent's session share the same warm language servers: one index, one cold start, no
  co-location needed for that.
- **pharos is on trial.** The maintainer (2026-11-13): capable models with the compiler, the
  tests and grep may already cover what a language server offers; pharos stays only if a
  language-server hook clearly beats a plain compiler hook in a three-arm experiment
  ([pharos-mcp#7](https://github.com/LoganBresnahan/pharos-mcp/issues/7)). The MCP-client
  subsystem this ADR costs out ([geex#2](https://github.com/LoganBresnahan/geex/issues/2)) is
  parked until the verdict.

How the three tools (geex, pharos, captAInHook) connect, the rules between them, and the work in
order: [stack.md](../stack.md).
