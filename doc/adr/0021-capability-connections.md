# ADR-0021: Capability connections — contracts, adapters & hosting tiers

- **Status:** Accepted
- **Date:** 2026-06-07
- **Refines:** [ADR-0008](0008-pharos-not-bundled.md), [ADR-0009](0009-three-tier-extension-model.md), [ADR-0010](0010-disk-truth-lsp-v05.md), [ADR-0018](0018-mcp-transport-streamable-http.md)

## Context

[ADR-0008](0008-pharos-not-bundled.md) made geex an MCP **client** (consume pharos/LSP and
other providers); [ADR-0009](0009-three-tier-extension-model.md) sketched a three-tier
extension/capability model; [ADR-0010](0010-disk-truth-lsp-v05.md) scoped v0.5 LSP to
disk-truth. They left the **shape** of capability integration unspecified: how geex connects
to *heterogeneous* providers without bespoke-per-provider spaghetti **or** a false "unified
provider API"; what the relationship is between an MCP-client connection (tier 1) and the
WASM/native tiers (2–3); and where the [world/brain boundary](0007-world-not-brain.md) falls
when geex consumes external tools. Two v0.5 consumers force the question — **LSP** and **syntax
highlighting** — and a verified 2026-06 research pass mapped the landscape (Pharos, Serena,
agent-lsp, mcp-language-server, …; tree-sitter, Makeup, LSP semantic tokens). See the
[research notes](../research/capability-connections.md) and the
[testing-log entry](../testing.md).

## Decision

**1. Three roles around the one dispatcher** (this names what [ADR-0003](0003-one-shared-path.md)
left implicit):

- **Drivers** put commands *in* — a harness, a human at the TUI, a remote peer ([§3](../mcp-ai-integration.md)
  inbound layers). They write, through `Geex.Dispatch.run/1`.
- **Capability providers** *answer geex's queries* — pharos (LSP), a highlighter, a
  Direction-B AI endpoint. They **never write a buffer**; geex calls them and a *useful*
  answer becomes a `%Command{}` through the same dispatcher (or just renders).
- **The core** — dispatcher + buffers + history. geex's world.

**The capability-private invariant:** **capabilities are private to geex's world — geex never
relays an outbound capability to an inbound driver.** The test is one question: does the
connection's output *land in geex's world* (a buffer change, a rendered diagnostic, a
navigation target), or just *pass through to a driver*? Land → in scope. Pass-through → that is
the **middle-man / tool-router** anti-pattern (brain, not world), explicitly out
([§14](../mcp-ai-integration.md): "No LSP-tool proxying through geex's MCP server"). A harness
that wants pharos connects to pharos itself; [reconcile](0017-reconcile-file-watch.md) still
catches any disk writes.

**2. The world test on the outbound axis.** geex defines a capability contract **only when a
geex world-feature consumes it** ([ADR-0007](0007-world-not-brain.md) + the named-consumer
rule). Editor-world capabilities (LSP nav/diagnostics, highlighting, formatting, in-editor AI
features) are in; arbitrary agent tools (web search, Jira, DB) are the harness's business. No
feature → no contract → no adapter → no connection. This is what bounds the whole thing to a
small contract set.

**3. Two-layer integration — substrate + contracts + adapters** (resolves "custom connections
vs unified API"): the two are separable layers with opposite answers.

- **Transport/protocol layer — unified, shared.** Every MCP server speaks the same wire
  (`initialize`/`tools/list`/`tools/call`, JSON-RPC). geex builds **one** MCP-client substrate
  (the [`handle_line`](0006-elixir-not-gleam.md) seam **run in reverse**: originate requests,
  decode replies, correlate by `id`; one supervised process per connection; negotiate
  `protocolVersion`, tolerate skew/missing tools). The connection is **never** bespoke.
- **Semantic layer — heterogeneous, NOT unifiable.** What a provider's tools *mean* differs
  irreducibly. So geex defines **neutral, geex-owned capability contracts** (ports;
  data-in/data-out) that its features consume, and a **thin per-provider adapter** maps a
  provider's tools onto the contract — the only provider-specific code. **Per-server adapters
  are mandatory, not one generic adapter:** the research is unambiguous — the same LSP method
  appears as `definition` / `goto_definition` / `find_definition` / `get_info_on_location`
  across bridges, and semantic servers (Serena, agent-lsp) invent entirely different verbs at
  symbol granularity. A single LSP adapter is impossible; the contract+adapter model is the
  fit. (This mirrors [ADR-0004](0004-neutral-field-spec.md)'s neutral field-spec, pointed
  inbound.)

**4. Connect-out vs host-in — the two needs have different *shapes*.** A capability is either:

- a **connection** geex reaches *out* to (a provider process: pharos/LSP) — tier 1; or
- an **engine** geex *hosts in*-VM (a highlighter: tree-sitter / Makeup) — tiers 2–3.

This matters operationally: an in-VM engine (per-keystroke highlighting) must **not** sit on
the MCP/network path; a connection (LSP) does. "Two external things" (LSP + highlighting) is
really **one connect-out + one host-in**, with an *optional* bridge (LSP `semanticTokens`
enriching highlighting).

**5. Two hosting tiers for host-in capabilities** (re-frames [ADR-0009](0009-three-tier-extension-model.md):
not "three tiers of different things" but **one contract mechanism, two hosting tiers + a
connection substrate**):

- **Native** (any BEAM language — Elixir/Erlang/Gleam) — the **~free baseline** (a behaviour +
  a registry; full I/O/OTP, no marshalling). Chosen for trusted/first-party code and hot paths.
- **WASM** (sandboxed; WIT-typed) — for **untrusted/polyglot** compute; an expensive subsystem,
  **deferred to its first real consumer** (likely highlighting *grammars*, not LSP).

The cross-language safety is **runtime boundary validation** (geex validates the data an adapter
returns against the contract, language-agnostic — [ADR-0004](0004-neutral-field-spec.md)'s
`cast` pattern), **not** any one language's static types. **Gleam is a native-tier authoring
footnote**, not a tier: a Gleam author gets compile-time checking for free, but it disciplines
only Gleam code; geex owes Gleam nothing until a Gleam adapter author exists. Contracts are kept
**data-clean (serializable structs in/out)** so they *project* later — to Gleam types, or a WIT
interface for WASM — as a hosting swap, not a redesign.

**6. The substrate is transport-pluggable** (amends [ADR-0008](0008-pharos-not-bundled.md)'s
"over stdio" with [ADR-0018](0018-mcp-transport-streamable-http.md)'s logic): the reversed-seam
core is transport-agnostic, with **connect-to-running (HTTP) preferred** (decoupled lifecycle,
one warm provider shared, symmetric with geex's own inbound server) and **spawn-stdio as the
fallback** (zero-config, binary-only providers, CI). Pharos already serves both. Daemon
lifecycle: connect if a URL is configured, else spawn-stdio — one knob, no daemon-management
surface.

**7. Binary / NIF economics put the highlighter on the WASM tier.** geex shipping as a binary
(`mix release`, optionally Burrito) is trivial for pure-BEAM code; a **NIF** breaks
"compile-once-run-anywhere" — per-platform native build matrix, in-VM segfault blast radius,
dirty-scheduler care. WASM **collapses** that: one per-platform runtime NIF (wasmex), above
which grammars are **portable `.wasm`** needing no native build and no geex recompile. So the
highlighter is **tree-sitter on the WASM tier** — *not* a tree-sitter NIF (whose Elixir bindings
are all early-stage anyway). This makes **highlighting the WASM tier's named consumer** (point
5): the tier is built *now*, not deferred. (`Makeup`, the pure-Elixir lexer, was considered as a
zero-NIF interim base but **dropped** — it would be a throwaway, its token taxonomy isn't
tree-sitter's so themes wouldn't map (point 8 / [ADR-0023](0023-theming-and-extension-loading.md)),
and committing to the real engine avoids a migration.)

**8. First consumers (named):**

- **LSP** → the MCP substrate + a **Pharos adapter** onto an `LSP`-family contract
  (`Definitions`/`References`/`Diagnostics`/`Hover` — the four [ADR-0010](0010-disk-truth-lsp-v05.md)
  needs). Pharos is first-party (Gleam-on-BEAM) and serves both transports; the client must
  tolerate its quirks (hardcoded `protocolVersion` 2024-11-05, no `ping`). A second provider
  (`mcp-language-server`) is kept as the proof the adapter seam is genuinely per-server.
  Provider language is **irrelevant** (MCP is the boundary); Pharos's BEAM-ness buys nothing in
  v0.5 (disk-truth, un-bundled). Output that mutates (a rename `WorkspaceEdit`) re-enters via
  `Dispatch.run/1`; reads (diagnostics/hover) render.
- **Highlighting** → a `Highlight` contract: text [+ language] → token spans carrying
  **tree-sitter capture names** (engine- *and* theme-agnostic; the terminal **cannot** highlight
  — it only renders the SGR geex emits). **Engine = tree-sitter on the WASM tier** (point 7;
  portable grammar `.wasm`). The capture→`Style` mapping is the *theme*, a separate swappable
  data layer ([ADR-0023](0023-theming-and-extension-loading.md)). **Optional enrichment = LSP
  `semanticTokens`** from the Pharos connection (Zed-style off/combined/full overlay), never the
  base (optional, slower, partial; disk-truth → valid only on a clean buffer —
  [ADR-0022](0022-capability-reactor.md)). The *cadence* (when highlight/LSP fire) is the
  reactor, [ADR-0022](0022-capability-reactor.md).

Disk-truth ([ADR-0010](0010-disk-truth-lsp-v05.md)) holds: a socket/stdio provider can't see
unsaved buffers; co-location is a later transport swap.

## Consequences

- One MCP substrate serves **both** edges (inbound server [ADR-0018], outbound client) — the
  protocol vocabulary + JSON-RPC framing become shared; the client is the reversed seam (~20%
  reuse, 80% new: outbound transport + requester/correlator + capability registry).
- geex stays **bounded**: provider-specific weight is one *extractable* in-core reference
  adapter per first consumer; the WASM host machinery and external-package SDK are deferred to
  the second (third-party) consumer.
- The middle-man anti-pattern is closed by an invariant, not vigilance; highlighting is kept
  off the network path; LSP heterogeneity is absorbed by per-server adapters.
- **Cost:** a new MCP-client subsystem (connection config, per-connection supervision, a
  capability registry distinct from `CommandRegistry`); per-provider adapters are real,
  version-sensitive maintenance; the WASM tier is now a v0.5 subsystem (highlighting is its
  named consumer — point 7).
- **Follow-ups (now decided):** the *reactor* — which editor events trigger which capability
  call and at what cadence — is [ADR-0022](0022-capability-reactor.md); the *theme* layer
  (capture→`Style`) and how themes/grammars/extensions are loaded is
  [ADR-0023](0023-theming-and-extension-loading.md).

## See

[ADR-0008](0008-pharos-not-bundled.md), [ADR-0009](0009-three-tier-extension-model.md),
[ADR-0010](0010-disk-truth-lsp-v05.md), [ADR-0018](0018-mcp-transport-streamable-http.md),
[ADR-0007](0007-world-not-brain.md), [ADR-0003](0003-one-shared-path.md),
[ADR-0004](0004-neutral-field-spec.md), [ADR-0011](0011-direction-b-balance-beam.md),
[mcp-ai-integration.md](../mcp-ai-integration.md) §3 / §14, the
[research notes](../research/capability-connections.md).
