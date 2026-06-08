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

## WASM tier — de-risk (2026-06-07; 8/8 claims confirmed live, incl. local toolchain)

The crux: a per-grammar `tree-sitter-<lang>.wasm` is **inert** — it exports only
`tree_sitter_<lang>() -> TSLanguage*` and must be driven by the tree-sitter **runtime**. So
"highlighting" = runtime + grammar + `highlights.scm`, and the only question is *where the runtime
lives*. Three realistic architectures:

| Arch | Shape | Portable grammars? | NIF? | Maturity |
|---|---|---|---|---|
| **1 (recommended)** | one native `tree-sitter` NIF (`wasm` feature → embeds `wasmtime`) + `tree-sitter-highlight`; loads portable grammar `.wasm` at runtime via `WasmStore::load_language` | **Yes** | one small stable NIF (runtime only, never per-grammar) | Rust pieces production; BEAM wrapper **net-new** = the build target |
| 2 (north-star) | pure `wasmex` runs `tree-sitter.wasm` (the runtime) + grammars | Yes | no new NIF (wasmex) | **unbuilt** — web-tree-sitter's runtime is Emscripten-built, needs JS/`fs` glue nobody has re-hosted on BEAM |
| 3 (bring-up only) | static-NIF (`autumnus`/`lumis`): tree-sitter + highlight + grammars baked in at compile time | **No** (recompile to add a lang) | NIF that grows per language | **production** (lumis: 110+ langs, ANSI, Neovim themes) |

**Pick ARCH 1.** It's the only one satisfying all three goals: portable grammars (`tree-sitter
build --wasm`/wasi-sdk since CLI v0.26.1 → `WasmStore` consumes exactly those), one small native
surface, runs on BEAM. The `tree-sitter-highlight` crate's `HighlightEvent` capture spans **are**
geex's `Highlight` contract `{byte_start, byte_end, capture_name}`.

**Inverts the earlier "wasmex loads grammars" framing:** wasmtime *inside the tree-sitter NIF*
loads grammar `.wasm`, not wasmex (which stays for the untrusted-extension tier). The
binary-distribution story is unchanged (one runtime NIF + portable grammars), the *runtime NIF*
is just tree-sitter+wasmtime, not wasmex. ADR-0021 §7 / ADR-0023 amended to match.

**Verified deps (buildable here today — Rust 1.94, OTP 28, Elixir 1.19.5):** `tree-sitter` 0.26.9
(feature `wasm`), `tree-sitter-highlight` 0.26.9, `rustler` + `rustler_precompiled`, `tree-sitter`
CLI (for `build --wasm`, build-time/author-side only), `wasmex` 0.14.0 (extension tier only, not
this path; supports core modules + WIT/component-model, fuel/epoch/StoreLimits sandboxing,
scheduler-safe via a tokio worker pool).

**Spike (de-risk in hours, pure-Rust before any BEAM):** ① `tree-sitter build --wasm` on
tree-sitter-json → confirm a `.wasm` + wasi-sdk auto-download. ② pure-Rust harness:
`Engine → WasmStore::load_language("json", bytes) → parser.set_wasm_store` → assert `Ok` (**the
single biggest unknown** — wasi-sdk-grammar ⇄ native-runtime ABI; pin CLI & crate to the same
0.26.x). ③ run `highlights.scm` on `{"a":"b\n"}` → assert ≥1 `HighlightStart(idx)` → real capture
+ non-empty byte range. ④ wrap ②–③ behind ONE Rustler NIF `geex_ts.highlight(grammar_bytes,
scm, src) -> {:ok, [{start,end,capture}]}`; call from iex. ⑤ failure paths: non-grammar bytes →
`{:error,_}` (no crash); deadline → `{:error,:timeout}` on a dirty scheduler. ⑥ repeat for
tree-sitter-elixir (dogfood). **Go/no-go:** **GO** (conditional on step ②) — every load-bearing
dep verified; the tier is viable now; ARCH 2 stays a north-star. Risks: grammar↔runtime ABI skew
(pin versions, validate ABI at load), whole-buffer re-parse latency on big files (cache
Engine/Store/Parser + keep a persistent `Tree` for incremental reparse — a native-NIF strength
ARCH 2 lacks).

### Spike EXECUTED — 2026-06-07, **GO confirmed** (steps ①②③⑤ run; pure Rust)

Ran the load path end-to-end in a throwaway crate (`/home/oof/ts-wasm-spike`, sibling to geex; not
committed — promote to the real `tree_sitter_wasm` package once the NIF API stabilizes). Toolchain:
tree-sitter **CLI 0.26.9** + crate **0.26.9** (`wasm` feature) → embedded **wasmtime 36.0.10** (via
`wasmtime-c-api-impl`, confirming the "vendored wasmtime inside the tree-sitter NIF" architecture),
**wasi-sdk-29**, Rust 1.94.

- **① build:** `tree-sitter build --wasm` on tree-sitter-json → a **6272-byte** portable
  `tree-sitter-json.wasm`; wasi-sdk auto-downloaded to `~/.cache/tree-sitter` on first run. ✓
- **② load (the single biggest unknown — RESOLVED):** `WasmStore::new(&Engine)` →
  `store.load_language("json", bytes)` → `Language` (**ABI version 14**); `parser.set_wasm_store` +
  `set_language` + `parse` → root `kind="document"`, `has_error=false`, correct s-expression. The
  wasi-sdk-grammar ⇄ native-runtime ABI handshake **works first try** with matched 0.26.x. ✓
- **③ contract:** `highlights.scm` via `Query`/`QueryCursor` on the wasm-store parser → **12 capture
  spans**, each `(byte_start, byte_end, capture_name)` — `string`, `escape`, `number`,
  `constant.builtin`, `string.special.key`. This **is** geex's `Highlight` contract, produced
  directly (no `tree-sitter-highlight` `Highlighter` wrapper). ✓
- **⑤ (lite) safety:** non-grammar bytes → `WasmErrorKind::Parse`, **no crash**. ✓

**Exact API (tree-sitter 0.26.9):** `tree_sitter::wasmtime::Engine` (re-exported from
`wasmtime_c_api`), `WasmStore::new(&Engine) -> Result<_, WasmError>`,
`WasmStore::load_language(&mut self, name, bytes) -> Result<Language, WasmError>`,
`Parser::set_wasm_store(WasmStore) -> Result<(), LanguageError>`. Captures iterate via
`streaming_iterator::StreamingIterator`; names from `Query::capture_names()[cap.index]`.

- **④ DONE — the NIF runs on the BEAM.** Standalone package `/home/oof/tree_sitter_wasm`
  (`mix` + Rustler 0.38, `tree-sitter` 0.26.9 `wasm` feature; `crate-type = cdylib`). The
  `#[rustler::nif(schedule = "DirtyCpu")]` `highlight(grammar, name, scm, src)` wraps the same
  `run()` and encodes `{:ok, [{start, end, capture}]}` / `{:error, msg}`.
  `TreeSitterWasm.highlight(json_wasm, "json", scm, src)` → **`{:ok, [12 spans]}`** identical to
  the pure-Rust run; garbage bytes → `{:error, "load_language(json): WasmError { kind: Parse, … }"}`
  (clean tuple, no VM crash). Compiled clean; `priv/native/tree_sitter_wasm.so` is the only build
  artifact. Not yet committed/published (local-path-dep phase).

**Open follow-ups (not blockers):** dirty-scheduler **parse deadline** → `{:error, :timeout}`
(currently DirtyCpu only, no cancellation); cache `Engine`/`Store`/`Parser` in a `ResourceArc`
(per-call construction today) + persistent `Tree` for incremental reparse on big files; whether the
`tree-sitter-highlight` `Highlighter` convenience layer supports wasm languages is **untested** —
the spike + NIF deliberately use `Query`/`QueryCursor` directly (the path that yields exact spans
anyway), so it is a nice-to-have, not on the critical path.
