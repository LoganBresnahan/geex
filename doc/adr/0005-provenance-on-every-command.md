# ADR-0005: Provenance on every command

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

AI edits must be auditable, selectively undoable, and attributable in collaboration.
Retrofitting authorship onto a command system after the fact is painful; it must be
present from the first command.

## Decision

Every command carries `%Command.Meta{}`:
- `actor` — `:human` | `{:llm, model}` | `{:agent, id}` | `{:extension, id}` | `:external`
- `at` — timestamp (stamped at dispatch)
- `prompt_hash` — nil for human input
- `origin` — `%{turn_id, seq}` linking a *sequence* of commands to one agent turn

It lives **on the value**, never in a side ledger (a ledger is a second source of truth
and doesn't survive External Term Format across a remote dispatch).

## Consequences

- Audit; "undo the last AI edit" (filter by `actor`) and "revert everything the agent did
  this turn" (filter by `origin.turn_id`) as **pure queries over one history**; replay
  analysis; collab attribution; render-time tinting of AI-authored cells.
- Rides on the value → survives remote dispatch for free, exactly as the command does.
- Out-of-band edits (an agent that bypassed geex) are marked `:external` — geex never
  fabricates authorship it can't back ([ADR-0012](0012-trust-and-enforcement.md)).
- **Cost:** one struct field, designed in from day one (cheap now, expensive later).

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §7, §13 (composite provenance),
[ADR-0002](0002-commands-as-values.md).
