# Research: LSP-over-MCP providers + syntax-highlighting sourcing

Evidence backing [ADR-0021](../adr/0021-capability-connections.md). A verified 2026-06 pass
(multi-source web research, each load-bearing claim independently confirmed — 14/15 confirmed,
1 "uncertain" only on which immature Elixir tree-sitter binding is Rust-vs-C). Sources inline.

## LSP-over-MCP landscape

Two tool-surface **families** — which is why **one generic LSP adapter is impossible** and geex
needs a thin **per-provider** adapter onto its own contract:

- **Raw / thin LSP-method bridges** — one tool per LSP method, but *no shared vocabulary*:
  the same method is `definition` (isaacphi/mcp-language-server, Go, BSD-3) vs `goto_definition`
  (Pharos) vs `find_definition` (stephanj/LSP4J-MCP, Java) vs `get_info_on_location`
  (Tritlo/lsp-mcp, TS). Three bridges, three names, three arg shapes.
- **Higher-level semantic/symbol tools** — named for the agent task at AST/symbol granularity:
  `find_symbol` / `find_referencing_symbols` / `replace_symbol_body` (oraios/serena, Python,
  MIT, ~25k★, 40+ langs via its `solidlsp` fork of Microsoft `multilspy`); blackwell-systems/
  `agent-lsp` (Go, 30 langs) adds workflow "skills" (`blast_radius`, `safe_apply_edit`).

| Provider | Lang | Transport | Surface | Note |
|---|---|---|---|---|
| **Pharos** (LoganBresnahan/pharos-mcp) | Gleam→BEAM | stdio **+** Streamable-HTTP/SSE | **hybrid** raw LSP **+** Serena-style symbol tools **+** `semantic_tokens`, `memory_*`, `runtime_*` | **first-party reference**; wraps rust-analyzer/gopls/pyright/jdtls +~18; quirks: hardcodes `protocolVersion` 2024-11-05, no `ping` (→ `-32601`); disk-truth |
| Serena (oraios) | Python | stdio + SSE + http | semantic/symbol | dominant prior art (~25k★) |
| agent-lsp (blackwell) | Go | stdio + HTTP/SSE | semantic + workflow skills | skills overlap geex's *own* command layer — borrow ideas, don't bind |
| mcp-language-server (isaacphi) | Go | stdio | raw (`definition`/`references`/…) | cleanest 2nd provider to prove the per-server seam |
| lsp-mcp (Tritlo) | TS | stdio | raw + subscribable `lsp-*://` resources | diagnostics-as-resource is a push-diagnostics pointer |
| ElixirLS MCP | Elixir | stdio | Elixir-semantic | BEAM-native buys nothing over MCP; Elixir-only |
| multilspy (Microsoft) | Python | — (library) | — | the substrate *under* Serena; not directly connectable |

**Design answers:** (a) a provider's language is **irrelevant** to geex — MCP (JSON-RPC over
stdio/HTTP) is the only boundary; even Pharos's BEAM-ness gives no in-VM advantage in v0.5
([ADR-0008](../adr/0008-pharos-not-bundled.md)/[0010](../adr/0010-disk-truth-lsp-v05.md)).
(b) **no uniform LSP vocabulary** → per-server adapter required.

## Syntax-highlighting sourcing

**CRUCIAL: highlighting cannot come "from the terminal."** A terminal only interprets ANSI SGR
escape codes a program emits; it never tokenizes source. The editor computes tokens and emits
ANSI — proven by Helix's pipeline (`tree-sitter → theme Style → helix-tui Cell → ANSI` in the
crossterm backend).

| Source | Tier | NIF/binary cost | Role |
|---|---|---|---|
| **tree-sitter** | WASM (or native NIF) | **WASM:** 1 runtime NIF (wasmex) + portable per-grammar `.wasm` (`tree-sitter build --wasm`, auto wasi-sdk since v0.26.1). **NIF:** per-platform matrix + segfault risk; Elixir bindings all early-stage (none exposes a token API in Elixir) | de-facto **base** engine (Helix/Zed/Neovim/GitHub) |
| **Makeup** (ExDoc's) | native, **zero NIF** | bundles clean, runs anywhere | **v0.5 base** — pure Elixir; HTML formatter only (geex writes ANSI); covers Elixir/Erlang/EEx/JSON/C. `makeup_syntect` reaches 205 langs but reintroduces a Rust NIF |
| **LSP `semanticTokens`** | via existing MCP conn | none new | **optional enrichment overlay** — Pharos already ships the tool (5-int-per-token encoding; legend lives in `initialize` capabilities, Pharos doesn't stash it). Optional/partial/slower → never the base |
| TextMate grammars | NIF/WASM (Oniguruma) | no BEAM home | skip — regex/line-based, industry deprecating |

## Prior art (the split is universal)

Helix, Zed, Neovim all source highlighting and LSP as **two separate subsystems**: a syntactic
**base** (tree-sitter; TextMate in VS Code) + an **optional** LSP `semanticTokens` **overlay**.
Zed's `semantic_tokens` setting (`off` default / `combined` / `full`) is the cleanest merge
model; Helix's LSP-token PR #6102 was closed (policy: tree-sitter base, LSP async overlay only);
Neovim gates on `semanticTokensProvider` and falls back to tree-sitter (the two can visually
conflict → need a precedence policy). **None relies on LSP tokens alone.** Cursor/Windsurf are
VS Code forks and add no novel highlighting/LSP sourcing — geex's LLM-native novelty is the
command path, *not* this layer, which should follow the proven split. (Aider uses tree-sitter
for LLM *structural context*, not display — a hint geex's tree-sitter engine could pay off twice:
display **and** structural context for the command path.)

**Conclusion:** two contracts (`Highlight` host-in; `LSP` connect-out), one-way overlap
(LSP `semanticTokens` may enrich `Highlight`), potentially **one provider** (Pharos serves both).
