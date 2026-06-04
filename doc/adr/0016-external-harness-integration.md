# ADR-0016: External harness integration & the enforcement ladder

- **Status:** Accepted
- **Date:** 2026-06-04
- **Refines:** [ADR-0012](0012-trust-and-enforcement.md), [ADR-0009](0009-three-tier-extension-model.md)

## Context

[ADR-0012](0012-trust-and-enforcement.md) decided that a pre-built external harness
(Claude Code, Codex, Gemini, …) is a **cooperative** MCP client geex cannot force
through its dispatcher, and named two regimes (cooperative / enforced). It left three
things unresolved that a real integration must answer: (1) *how* the harness is actually
scoped — a principle, not a deliverable; (2) the regimes read as a **binary**, with
"enforced" conflated with "in-VM / WASM" — yet WASM cannot run a real Node CLI
(ADR-0012 itself says wrapping the CLI is the wrong layer for WASM); (3) which harnesses
can even be gated. A 2026-06 research pass (verified against current harness docs) plus a
[sandbox smoke test](../evidence/rung2-sandbox-smoke/) resolved these.

## Decision

**An external harness is a cooperative MCP *client* governed by ADR-0012 — not a
[§14](../mcp-ai-integration.md) tier** (the three tiers are geex-as-MCP-*client*-to-pharos,
in-VM WASM, native BEAM; an inbound external CLI is none of them). geex works *with*
harnesses as they are; it never wraps or forces them. Concretely:

1. **The capability grant is a checked-in, per-harness preset** — ADR-0012's cooperative
   regime made into a deliverable. Each preset (a) denies the harness's built-in file
   writers and (b) points its MCP config at geex. geex authors one per supported harness;
   gating is irreducibly per-harness (there is no portable "use only this server" switch).
   - Prompt / `CLAUDE.md` instructions are **not** an enforcement boundary.
   - **Coverage gate:** removing a harness's built-in writers is only safe once geex's MCP
     tools cover *every* mutation it needs (create/edit/delete/rename). Treat write-surface
     completeness as a v0.5 gate.
2. **Harnesses fall in three tiers:**
   - **First-class (gateable to MCP-only):** Codex (best — `sandbox_mode`), Claude Code
     (deny-list + `sandbox-runtime`), Gemini, Continue, Roo, OpenCode — built-in writers
     removable, geex's tools become the routed write path.
   - **Best-effort (reconcile-only):** Cline (built-in editor unremovable), Cursor
     (editor-owned apply pipeline) — cannot be forced MCP-only by design.
   - **Out of scope:** aider (no MCP client; direct git-diff writes) — geex is invisible
     to it; [reconcile](0017-reconcile-file-watch.md) still tags its edits `:external`.
3. **The enforcement ladder** (replacing ADR-0012's binary), weakest → strongest:
   - **Rung 0 — reconcile floor** (always on, every harness incl. aider/Cline/Cursor):
     out-of-band writes detected and tagged `:external`, never blocked
     ([ADR-0017](0017-reconcile-file-watch.md)).
   - **Rung 1 — cooperative preset** (per-harness deny + route to geex MCP): honest;
     depends on the harness honoring it; does **not** close the subprocess-write gap.
   - **Rung 2 — OS-sandbox the harness** (NEW): wrap the real CLI in
     Seatbelt/bubblewrap/Landlock — or **lean on the sandbox the harness already ships**
     (Codex `sandbox_mode`, Claude Code `sandbox-runtime`). Repo read-only; the only egress
     is geex. **Enforced *and* runs a real harness** — the rung the binary was missing.
   - **Rung 3 — WASI-P2 / wasmex** (§14 tier 2): strongest, but only for *thin
     geex-authored guests*; cannot run a real CLI.
4. **geex builds no sandbox.** For Rung 2 it leans on the harnesses that ship one and
   documents the config; an optional bubblewrap wrapper for sandbox-less harnesses is a
   post-0.5 nicety. geex's leverage is the dispatcher + provenance + reconcile, not a
   container runtime.

**The Rung-2 parentage requirement (smoke-tested, [evidence](../evidence/rung2-sandbox-smoke/)):**
geex must run **outside** the sandbox as a server the harness **connects to** — *not* the
stdio child the harness spawns (which inherits the sandbox and is trapped: its write is
denied). This is why the enforced rung requires the *connect* transport
([ADR-0018](0018-mcp-transport-streamable-http.md)), and the sandbox must permit narrow
**loopback egress** to reach geex.

## Consequences

- ADR-0012's cooperative regime is now a concrete artifact (presets), and "enforced"
  splits into **Rung 2 (OS-sandbox, external harnesses)** and **Rung 3 (WASM, geex's own
  guests)** — see the [ADR-0012 amendment](0012-trust-and-enforcement.md).
- The honest floor ([ADR-0017](0017-reconcile-file-watch.md)) is mandatory: it is the only
  thing covering subprocess writes under Rung 1, and the only coverage for best-effort /
  out-of-scope harnesses.
- A project-scope preset is **advisory-by-cooperation** (a user can override it unless it
  is deployed as managed/org settings) — so the preset is the nice default, not
  enforcement; Rung 0/2 are what make it honest/enforced. Do not describe a preset as
  "enforcement."
- Per-harness presets are real, ongoing maintenance (config keys are version-sensitive).

## See

[ADR-0012](0012-trust-and-enforcement.md), [ADR-0017](0017-reconcile-file-watch.md),
[ADR-0018](0018-mcp-transport-streamable-http.md),
[ADR-0009](0009-three-tier-extension-model.md),
[mcp-ai-integration.md](../mcp-ai-integration.md) §9 / §14,
[evidence/rung2-sandbox-smoke/](../evidence/rung2-sandbox-smoke/).
