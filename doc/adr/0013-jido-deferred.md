# ADR-0013: Jido deferred (not adopted for the command system)

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

Jido's `Action` is conceptually geex's `Command`, and Jido's ecosystem (jido_action,
jido_ai, jido_signal, jido_mcp) is mature. But Jido passes a validated **map** to `run/2`
and does *not* `defstruct` the args — which breaks commands-as-value
([ADR-0002](0002-commands-as-values.md)). balance_beam's newest spec pulled Jido in.

## Decision

**Do not adopt Jido for the command system.** `jido_action` is at most a *blueprint* for
the macro/JSON-Schema generation, never the command definition. The agent-runtime
(`jido` / `jido_signal`) is deferred behind a three-condition trigger geex does not meet
at v0.5: (1) long-lived multi-turn plans that must survive crash/restart mid-plan, (2)
*multiple* independent agents needing a shared typed signal bus, (3) a Direction-B feature
that actually schedules them. balance_beam's core stays Jido-free
([ADR-0011](0011-direction-b-balance-beam.md)).

## Consequences

- Commands-as-value preserved; no `jido_mcp` → Plug/Phoenix weight risk in a single-binary
  TUI; scheduling / sensors / pub-sub / retries are cheaply home-grown on OTP +
  `instructor_ex`-style reask.
- Any future Jido agent is a **sidecar** that emits `%Command{}` through the dispatcher,
  never a write path.
- Re-revisit only if all three trigger conditions hold post-0.5.

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §13 (Jido revisit), §1,
[ADR-0002](0002-commands-as-values.md), [ADR-0011](0011-direction-b-balance-beam.md).
