# ADR-0018: MCP transport — Streamable HTTP, connect-first, dogfood == production

- **Status:** Accepted
- **Date:** 2026-06-04
- **Refines:** [ADR-0003](0003-one-shared-path.md), [ADR-0006](0006-elixir-not-gleam.md); relates to [ADR-0016](0016-external-harness-integration.md)

## Context

[§15b](../mcp-ai-integration.md) pulled forward a **stdio** "thin slice" as the earliest
dogfood. But there are two distinct usage modes, and stdio serves the wrong one:

- **Mode 1 — headless geex as a spawned tool** (stdio: the harness *spawns* geex as a
  child). Per-session, throwaway, single-client, dies with the harness. An LLM edits some
  files via geex semantics.
- **Mode 2 — the harness attaches to the *running* geex** (the harness *connects* to a
  long-running server). Edits land in the live session the human is looking at, with
  provenance, in the real undo history.

Production — and the author's always-intended model ("geex is its own process") — is
**Mode 2**. A Mode-1 stdio dogfood tests the protocol but exercises a different process
lifecycle and a cold, unshared session: it never tests the production path. The
[Rung-2 enforced sandbox](0016-external-harness-integration.md) *also* requires Mode 2
(geex outside the sandbox, harness connects in). A 2026-06 verification pass found **all
eight target harnesses can connect to a running HTTP MCP server**, with Streamable HTTP
the current (non-deprecated) remote transport.

## Decision

1. **The production / dogfood transport is MCP Streamable HTTP on loopback, served from
   the long-running geex BEAM process.** `geex --serve` runs the live editor *and* opens
   the MCP endpoint on the same node, sharing the same `Session`/`Buffer`/undo history.
   A real client connects; edits land in the live session. **That is dogfood == production**
   — and the same setup *is* the Rung-2 enforced-sandbox path.
2. **Build order:** the transport-agnostic **protocol core** first (`handle_line/1`,
   `tools/list` from the macro field-spec, `tools/call → Dispatch.run/1`, provenance) —
   it's pure and adapter-independent; then the **HTTP transport first**, ahead of stdio.
   Every transport is an adapter over the same pure dispatcher
   ([ADR-0003](0003-one-shared-path.md), §3).
3. **stdio is demoted to a CI / conformance harness** — a hermetic entry point (no editor,
   no network) for protocol unit tests and the [§15c cassette replay](../testing.md). It
   is the regression net, not the dogfood.
4. **No geex-native stdio shim.** All harnesses speak HTTP, so a relay is unnecessary *and*
   re-introduces the throwaway-spawn topology. For the two clients with version-sensitive
   Streamable-HTTP bugs (**Cline, OpenCode**), the hedge is to **co-host a legacy SSE
   endpoint** on the same server and/or bless the off-the-shelf `mcp-remote --transport
   http-only` proxy (a stdio facade over the *same* running geex — production topology
   preserved).
5. **First dependency: Bandit + Plug.** geex has been `deps: []`; the HTTP endpoint is its
   first dep. This is "own the technique, rent the transport" ([ADR-0011](0011-direction-b-balance-beam.md))
   applied to HTTP — geex owns the dispatcher/provenance, rents HTTP framing.
6. **Security (per the MCP spec):** bind `127.0.0.1` only (never `0.0.0.0`); validate
   `Origin` but **403 only when it is present and invalid** — CLI clients send no Origin,
   so allow absent/loopback Origins (DNS-rebinding defense without rejecting legitimate
   clients); auth (bearer/OAuth) opt-in, off for the loopback default.

## Consequences

- **Revises [§15b](../mcp-ai-integration.md) and [§12](../mcp-ai-integration.md):** HTTP
  (loopback Streamable HTTP) moves from a v0.5 *non-goal* to the v0.5 dogfood transport;
  stdio moves from "earliest dogfood" to "CI harness." This is a transport-ordering change,
  **not** a spine change — the protocol core is unchanged.
- The connect transport composes with [ADR-0016](0016-external-harness-integration.md)'s
  enforced rung: the sandbox must allow narrow **loopback egress** to the geex port; the
  enforced-rung smoke test and the live dogfood become the **same test**.
- v0.5 still excludes: remote/`0.0.0.0` exposure, WS, multi-client sessions, auth-required —
  loopback-single-user is the scope (§12 updated).
- A `.mcp.json` checked into the repo makes "geex editing geex" one connect away.

## See

[ADR-0003](0003-one-shared-path.md), [ADR-0006](0006-elixir-not-gleam.md),
[ADR-0016](0016-external-harness-integration.md), [ADR-0011](0011-direction-b-balance-beam.md),
[mcp-ai-integration.md](../mcp-ai-integration.md) §3 / §4 / §12 / §15b,
[testing.md](../testing.md).
