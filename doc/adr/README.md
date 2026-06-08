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
| [0012](0012-trust-and-enforcement.md) | Trust & enforcement: cooperative vs enforced | Accepted (amended by 0016/0017) |
| [0013](0013-jido-deferred.md) | Jido deferred (not adopted for the command system) | Accepted |
| [0014](0014-editor-state-and-dispatch-ownership.md) | Editor-state & dispatch ownership (EditorState; cursor view-local; `run/1` gather/scatter) | Accepted |
| [0015](0015-clipboard-subsystem.md) | Clipboard as a sibling subsystem (registers + ring history) | Accepted |
| [0016](0016-external-harness-integration.md) | External harness integration & the enforcement ladder (per-harness preset; OS-sandbox rung) | Accepted |
| [0017](0017-reconcile-file-watch.md) | Reconcile: file-watch + `:external` provenance (the honest floor) | Accepted |
| [0018](0018-mcp-transport-streamable-http.md) | MCP transport: Streamable HTTP, connect-first, dogfood == production | Accepted |
| [0019](0019-file-lifecycle-and-operation-tools.md) | File lifecycle (load/save, multi-buffer) & MCP operation tools (a third tool category) | Accepted |
| [0020](0020-diff-edit-tool.md) | Diff / search-replace edit tool (compiles to `replace`; ports Moby's tiered matcher) | Accepted |
| [0021](0021-capability-connections.md) | Capability connections — contracts, adapters & hosting tiers (consume-MCP model; LSP + highlighting) | Accepted |
| [0022](0022-capability-reactor.md) | The capability reactor — when highlighting & LSP fire (per-buffer process; async cadence) | Accepted |
| [0023](0023-theming-and-extension-loading.md) | Theming & loading themes/grammars/extensions (capture-vocab theme; config-path install; fetch-nothing) | Accepted |
| [0024](0024-tui-core-extractable.md) | TUI core is extractable but stays in geex until mature + a second consumer (no-NIF `prim_tty`) | Accepted |
| [0025](0025-user-config-layer.md) | The user-config layer (theme/grammar/extension selection; TOML at XDG; precedence + cache), distinct from app config | Accepted |

## Adding one

Take the next number, name it `NNNN-kebab-title.md`, fill the format, add a row above.
If it overturns an earlier ADR, set that one's status to *Superseded by ADR-NNNN* and
link both ways.
