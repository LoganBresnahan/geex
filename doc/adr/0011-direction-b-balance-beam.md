# ADR-0011: Direction B on balance_beam; drop instructor_ex

- **Status:** Accepted
- **Date:** 2026-05-28

## Context

Direction B (geex-calls-LLM) needs structured output — schema → JSON-Schema → validate →
reask. The plan was `instructor_ex`, but it is quiet (last release Feb 2025, last commit
Jun 2025) with a near-rewrite successor (InstructorLite). Separately, `balance_beam` (the
author's own library) was originally an all-in-one "Ecto for LLMs".

## Decision

Direction B is backed by **`balance_beam`**, which **owns the structured-output technique**
(schema → JSON-Schema → validate → reask) on a **thin, maintained transport** (`req_llm` /
`Req` + the few provider APIs used). **Drop `instructor_ex`.** Principle: *own the
technique, rent the transport* — own the bounded part, rent the provider-matrix churn that
stalls these libraries. `Geex.AI` is a thin editor-glue wrapper over balance_beam.

## Consequences

- No dependence on a stale library; the churn-prone provider/HTTP layer is rented, not owned.
- geex needs only a **thin, late** slice (the extraction helper, post-0.5); orchestration /
  cost / agent-runtime live *above* geex ([ADR-0007](0007-world-not-brain.md)) and aren't
  geex's concern. balance_beam is driven by its own (healthcare) consumer on its own clock.
- balance_beam's core stays **Jido-free** ([ADR-0013](0013-jido-deferred.md)).
- The shared *concepts* (provenance, supervised execution, replay) are already **native**
  to geex (BEAM/OTP + commands-as-data), not imports.
- **Cost:** balance_beam must actually implement the technique (today it is a spec).

## See

[mcp-ai-integration.md](../mcp-ai-integration.md) §6, §13, [ADR-0013](0013-jido-deferred.md).
