# Architecture Decision Records

Short, numbered, dated records of geex's load-bearing decisions — *what* was decided,
*why*, and the *consequences*. An ADR answers "why is it this way?" for a future
contributor (human or LLM). They don't restate the design; they point to it.

Read [vision.md](../vision.md) first — these are the decisions that implement it.

## Format

Each ADR: **Status** · **Context** (the forces) · **Decision** · **Consequences**
(what it enables / costs) · **See** (where the detail lives). Keep them short. Status ∈
{ Proposed · Accepted · Superseded by ADR-NNNN · Deprecated }.

## Index

| # | Decision | Status |
|---|---|---|
| [0001](0001-build-on-the-beam.md) | Build the editor on the BEAM / OTP | Accepted |
| [0002](0002-commands-as-values.md) | Commands are values (`%Command{}` structs) | Accepted |
| [0003](0003-one-shared-path.md) | One dispatcher = the single shared path | Accepted |
| [0004](0004-neutral-field-spec.md) | One macro DSL emits a serialization-neutral field-spec | Accepted |
| [0005](0005-provenance-on-every-command.md) | Provenance on every command | Accepted |
| [0006](0006-elixir-not-gleam.md) | Elixir, not Gleam, for the MCP boundary | Accepted |
| [0007](0007-world-not-brain.md) | geex owns the world, not the brain | Accepted |
| [0008](0008-pharos-not-bundled.md) | pharos not bundled; geex is an MCP client | Accepted |
| [0009](0009-three-tier-extension-model.md) | Three-tier extension / capability model | Accepted |
| [0010](0010-disk-truth-lsp-v05.md) | Disk-truth-only LSP for v0.5 | Accepted |
| [0011](0011-direction-b-balance-beam.md) | Direction B on balance_beam; drop instructor_ex | Accepted |
| [0012](0012-trust-and-enforcement.md) | Trust & enforcement: cooperative vs enforced | Accepted |
| [0013](0013-jido-deferred.md) | Jido deferred (not adopted for the command system) | Accepted |

## Adding one

Take the next number, name it `NNNN-kebab-title.md`, fill the format, add a row above.
If it overturns an earlier ADR, set that one's status to *Superseded by ADR-NNNN* and
link both ways.
