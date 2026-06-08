# ADR-0023: Theming & how themes / grammars / extensions are loaded

- **Status:** Accepted
- **Date:** 2026-06-07
- **Refines:** [ADR-0021](0021-capability-connections.md), [ADR-0009](0009-three-tier-extension-model.md)

## Context

[ADR-0021](0021-capability-connections.md) made the highlighter **tree-sitter on the WASM tier**,
producing token spans tagged with **capture names**. That leaves two questions: how a *theme*
turns those captures into terminal color (and what format a theme is), and — more generally — how
a user **installs** anything geex doesn't bundle (a theme, a grammar for a new language, an
extension). The discussion surfaced a recurring conflation (themes vs WASM vs adapters vs a
"marketplace") that this ADR resolves by sorting installable things by **what they are**.

## Decision

### Theming

**1. The capture name is the engine↔theme contract; the theme is a swappable *data* layer.**
The pipeline is three decoupled stages:

```
tree-sitter (WASM)        Theme (data)                 Renderer
 text → capture spans  →  capture name → Style      →  Style → truecolor ANSI cell
```

The `Highlight` contract emits **capture names, not colors** (engine- *and* theme-agnostic). A
**Theme** is `capture-name → Style` (`fg`, optional `bg`, `bold?`/`italic?`/`underline?`) plus a
small **TUI palette** (editor bg/fg, line numbers, active line, cursor/selection). Swapping themes
re-renders only (no re-highlight); swapping engines keeps the same theme. Themes are **always
data, never code** — which keeps them safe (no sandbox), portable (any format → import), and
trivially loadable.

**2. geex's native theme format is the tree-sitter-capture vocabulary — not "Zed's format."**
The engine choice already fixed the vocabulary: a theme keys on tree-sitter captures (`keyword`,
`string.escape`, `punctuation.bracket`, …). Resolution is **longest-prefix** (`string.escape`
falls back to `string`). Terminal rendering is **24-bit truecolor SGR** (`\e[38;2;r;g;bm`;
`italic`→`\e[3m`, `font_weight:700`→`\e[1m`); the loader **flattens alpha** (`#RRGGBBAA`) against
the background since terminals have no alpha. First theme: **Birds of Paradise** (the author's Zed
port, [birds-of-paradise-zed](../../../birds-of-paradise-zed)), ported once into the native format.

**3. External theme formats are importer-adapters; build them in vocabulary-fit order.** Same
ports-and-adapters shape as [ADR-0021](0021-capability-connections.md): geex owns the native
`Theme`; external formats are *importers*. **Format affinity follows *engine* affinity** —

- **Zed / Helix / Neovim themes** key on tree-sitter captures (those editors also use
  tree-sitter), so they are *already in geex's vocabulary* → near-lossless import. This is the
  large, in-vocabulary ecosystem.
- **VS Code themes** key on **TextMate scopes** (a different, finer taxonomy) → importing needs a
  **lossy `scope → capture` table**, a real maintenance burden. More themes, wrong vocabulary.

So a runtime tree-sitter-vocabulary importer (Zed/Helix) is cheap and comes first (gated on a
"use my theme" consumer); a TextMate/VS Code importer is explicitly **lossy and deferred**, never
the native format. (Importers are trivial pure transforms — built-in core readers, not pluggable
WASM.)

### Loading — sort installable things by *what they are*

**4. Three kinds, three loading pipelines.** The conflation to kill: **a theme is data, not code;
only *code* and *parsers* are `.wasm`.** Nobody hosts "a `.wasm` of a theme."

| Kind | What it is | Format | Loaded how | Sandbox? | Bundled |
|---|---|---|---|---|---|
| **Theme** | data (colors) | native / Zed / Helix | **read & validate a file** | No (data) | a few defaults |
| **Grammar** | a parser (compute) | tree-sitter `.wasm` | **`wasmtime` (inside the tree-sitter NIF) instantiates** | Yes (WASM) | curated default set |
| **Extension / adapter** | code (logic) | native hex (trusted) **or** `.wasm` (untrusted) | hex (build) / **`wasmex`** (runtime) | per trust | first-party native |

> **Grammar loading — verified architecture** (2026-06-07 WASM de-risk research, 8/8 confirmed):
> a grammar `.wasm` is *inert* without the tree-sitter runtime, so it is **not** loaded by
> `wasmex`. The highlighter is one small native NIF — the `tree-sitter` crate (`wasm` feature,
> embedding `wasmtime`) + `tree-sitter-highlight` — that loads portable grammar `.wasm` at runtime
> (`WasmStore::load_language`). The user-facing promise is unchanged (drop a `.wasm`, declare its
> path, sandboxed by `wasmtime`); only the *host* differs. `wasmex` remains the host for the
> **untrusted-extension** tier ([ADR-0009](0009-three-tier-extension-model.md)), not grammars.
> See [ADR-0021](0021-capability-connections.md) point 7 and the
> [research notes](../research/capability-connections.md).

**5. Loading is config-path-based; geex fetches nothing.** A user adds anything geex doesn't
bundle by putting the file on disk and **declaring its path in user config** (distinct from the
app/runtime config). geex never pulls code off the network — the user vets and places the bytes;
config points at a local path. For **code** (grammars/extensions) explicit-path config is the
*right* default, not just convenient: loading executable code should be a **declared, auditable**
act, not auto-scan magic (a stray `.wasm` in a scanned dir must not run). Data (themes) may also
be auto-scanned from a `themes/` dir since it is harmless.

```toml
# ~/.config/geex/config.toml
theme = "birds-of-paradise"                 # bundled/native (DATA: parse + validate)
# theme = { path = "~/themes/birds.json" }  # …or an explicit file
[grammars]                                  # CODE: explicit path → sandbox + interface-check
rust = "~/grammars/tree-sitter-rust.wasm"
[extensions]                                # CODE: explicit path → sandbox + contract-check
my-highlighter = "~/ext/foo.wasm"
```

**6. WASM loading is a three-layer safety pipeline.** For anything that executes:
**(a) authorization** — an explicit config path = the user chose to load *this* file;
**(b) containment** — the WASM sandbox runs it (`wasmtime` in the tree-sitter NIF for grammars,
`wasmex` for extensions); a grammar gets *nothing* — text in, tree out; a malformed/non-grammar
`.wasm` traps to `{:error, _}`, never a BEAM crash;
**(c) correctness** — geex validates it satisfies the expected interface (tree-sitter grammar ABI
/ the [ADR-0021](0021-capability-connections.md) contract), else rejects with a clear error (e.g.
"rebuild with tree-sitter X.Y" on ABI skew).

**7. No marketplace.** "Drop a file, declare its path" *is* the install story. `geex install
<url>` (auto-fetch into a dir) is optional sugar on top and deferrable; a marketplace
(discovery/distribution/signing) is post-everything, gated on a real ecosystem — geex builds none
now.

### Packaging the highlighter NIF

**8. The ARCH 1 NIF is net-new and ships as a standalone, extractable package — geex *rents* the
extension runtime, builds only the one runtime nobody else has.** The 2026-06 survey found **no
BEAM package** that loads portable grammar `.wasm` at runtime: every existing binding
(`autumnus`/`lumis`, `treesitter_elixir`, `puretype/ex_tree_sitter`, `ex_tree_sitter_highlight`)
**statically links** grammars at compile time (= ARCH 3 — recompile to add a language). So geex
must build it. Two decisions fix its *form*:

- **Standalone hex package, not buried in geex** (geex-agnostic name, e.g. `tree_sitter_wasm`). It
  is a general BEAM capability (a NIF is callable from Elixir/Erlang/Gleam alike), it fills a real
  ecosystem gap, and a focused package is the clean vehicle for the `rustler_precompiled` builds
  geex's binary distribution needs anyway. geex then *consumes* it as a dep — "rent the runtime,
  own the contracts," except geex creates this runtime only because none exists. **Staged
  extraction:** build it as a local `path:`/`github:` dep while the `highlight/3` API is still
  being discovered; publish to hex once the load path is proven and the API stabilizes — the same
  build-extractable discipline as the Pharos adapter ([ADR-0021](0021-capability-connections.md)).
  Publishing is opt-in generosity on top of the obligation (geex needs the NIF either way) and
  carries a real cost: a precompiled-NIF CI matrix + version bumps against the tree-sitter crate.
- **Rent `wasmex` for the untrusted-extension tier; do not roll our own wasmtime host.** "Make a
  NIF for the wasmtime runtime instead of `wasmex`" literally = *rewrite `wasmex`* (itself a
  Rustler NIF over wasmtime, with WASI / component-model / fuel / epoch / `StoreLimits` /
  scheduler-safety / precompiled distribution already done). The binary therefore carries **two
  wasmtime copies** — one vendored inside the tree-sitter NIF (specialized for grammar loading,
  never exposed) and one in `wasmex` (a general embedding for extensions). Accepted as a minor
  cost; revisit only on a *measured* binary-size problem, where the fix is upstreaming
  grammar-loading into `wasmex`, not a bespoke host.

## Consequences

- Theming is the lightest subsystem: pure data, loaded like config, **zero security surface** (a
  bad theme fails validation or looks ugly). It is decoupled from the engine (capture vocabulary)
  and from the reactor ([ADR-0022](0022-capability-reactor.md)) — it is consulted only at render.
- geex sits in the **tree-sitter-vocabulary theme club** (Zed/Helix/nvim) — a large importable
  ecosystem — without adopting any external format as native; VS Code's bigger ecosystem stays
  reachable only through an explicit, lossy, deferred importer.
- The install model is **fetch-nothing / declare-paths**, which sidesteps download-trust, TLS,
  and cache-invalidation, and makes executing third-party code a deliberate act — the WASM
  sandbox ([ADR-0009](0009-three-tier-extension-model.md)) contains it regardless.
- geex **owns one new NIF** — the `tree_sitter_wasm` highlighter (net-new on the BEAM) — and may
  publish it standalone; `wasmex` and the tree-sitter crate are *rented*, so the only Rust geex
  maintains is the thin runtime+highlight wrapper. Two vendored wasmtime copies in the binary.
- **Cost:** geex needs a **user-config** layer (theme selection + grammar/extension paths),
  distinct from the app/runtime config; a native `Theme` representation + renderer truecolor/alpha
  support; a curated default grammar bundle; the Zed/Helix importer + the lossy VS Code one are
  per-format, consumer-gated work.

## See

[ADR-0021](0021-capability-connections.md), [ADR-0022](0022-capability-reactor.md),
[ADR-0009](0009-three-tier-extension-model.md), [ADR-0004](0004-neutral-field-spec.md)
(the same neutral-spec-projects-outward pattern), the
[research notes](../research/capability-connections.md) (tree-sitter / theme vocabulary),
[birds-of-paradise-zed](../../../birds-of-paradise-zed) (the reference theme).
