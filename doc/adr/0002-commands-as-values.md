# ADR-0002: Commands are values

- **Status:** Accepted
- **Date:** 2026-05-27

## Context

Input from humans and LLMs must yield undo, replay, collaboration, and provenance. If an
edit is a side-effecting function call or a closure, none of that comes for free — there
is nothing to record, ship, or re-run.

## Decision

Every editing operation is a **serializable value** — a `%Command.X{}` struct — not a
module + map (Jido's shape) and not a closure. A command is data; `run(%Command{}, state)`
executes it. The struct *is* the operation.

## Consequences

- **Undo** = keep the values. **Replay** = re-run them. **Collab** = ship them between
  nodes (External Term Format). **Provenance** = tag them ([ADR-0005](0005-provenance-on-every-command.md)).
- This is the spine of the whole design; the dispatcher ([ADR-0003](0003-one-shared-path.md))
  and provenance hang off it.
- **Cost:** every capability must express itself as a command struct — no ad-hoc buffer
  pokes. This is the discipline that buys the four properties above.
- Distinguishes geex from Jido (passes a validated *map* to `run/2`, no `defstruct`) and
  from instructor_ex/Ecto (the schema owns its own definition). geex keeps the operation
  a plain value it controls.

## See

[notes.md](../notes.md) (Commands as data), [mcp-ai-integration.md](../mcp-ai-integration.md) §1.
