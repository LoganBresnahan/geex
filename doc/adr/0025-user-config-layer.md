# ADR-0025: The user-config layer (theme / grammar / extension selection, distinct from app config)

- **Status:** Accepted
- **Date:** 2026-06-08
- **Refines:** [ADR-0023](0023-theming-and-extension-loading.md) (§5 config-path install;
  its Consequences name "a user-config layer … distinct from the app/runtime config" as the cost)
- **Relates to:** [ADR-0018](0018-mcp-transport-streamable-http.md) (the MCP port/env vars),
  [ADR-0009](0009-three-tier-extension-model.md) (the trust tiers a config path authorizes)

## Context

[ADR-0023](0023-theming-and-extension-loading.md) decided that everything geex doesn't bundle
is installed by **putting a file on disk and declaring its path in user config** — geex fetches
nothing. It sketched `~/.config/geex/config.toml` and listed the consequence: *geex needs a
user-config layer (theme selection + grammar/extension paths), distinct from the app/runtime
config.* That layer was never built, and it was tracked only as a deferred line in
[testing.md](../testing.md) and a footnote in ADR-0023 — not in the roadmap. This ADR makes the
decision explicit so the work is captured before it is built, and so the **theme loader already
shipped** (`Geex.Theme.load/1`, path-ready, never raises on a bad file) gets the reader that points
at it.

Two configs are being conflated and must be separated:

- **App / runtime config** — `config/config.exs` + `config/runtime.exs`: how the BEAM *application*
  boots. Feature gates (`start_http_mcp`, `start_terminal`, `start_highlight`), dep wiring,
  the `GEEX_*` env reads. Authored by geex, not the user; not a preferences surface.
- **User config** — the *human's* preferences: which theme, where their grammars/extensions live,
  (later) their keymap. Authored by the user, read by geex. This is what ADR-0023 §5 needs and
  what does not yet exist.

## Decision

**1. Add a distinct user-config layer; do not overload app/runtime config.** A `Geex.Config`
module loads the user's preferences, caches them once, and exposes typed accessors. App/runtime
config stays exactly as-is for boot concerns. The two never merge: a feature gate is not a user
preference, and a theme choice is not a boot flag.

**2. Format: TOML at the XDG path — decided.** `$XDG_CONFIG_HOME/geex/config.toml`, else
`~/.config/geex/config.toml`. TOML because this file is **hand-edited by a human**: it wants comments
and sections, which JSON refuses, and because the user likely also runs pharos (whose config is TOML
— [pharos study](../research/pharos-mcp-study.md)), so the convention and muscle memory carry over.
Cost: one small **pure-Elixir, NIF-free TOML parser dep** (data-only, no code execution — keeping the
core's no-native-code line intact; the specific package is pinned when `Geex.Config` is built). The
zero-dep JSON alternative (Elixir 1.18 ships `JSON`) was rejected as the default: a preferences file
a human maintains should allow comments.

**2a. Config is a thin *pointer* layer; bulk structured data lives in its own files.** TOML's one
real weakness is arrays-of-tables (deep nesting) — the shape that pushed pharos toward embedding
structured blobs inside TOML values. geex avoids it *by design*: config never inlines data, it only
**selects or points at** it — a theme is a separate JSON file referenced by name/path
([ADR-0023](0023-theming-and-extension-loading.md) §5), grammars/extensions are paths, not payloads
(§4 below). So the config stays shallow (sections + `key = value`) — exactly TOML's sweet spot — and
the embedded-JSON-in-TOML workaround never arises. Anything that tempts toward deep nesting belongs
in its own data file, not in config. (A future modal keymap stays clean too: TOML sub-tables like
`[keymap.normal]`, never arrays-of-tables.)

**2b. The format split is deliberate: TOML for the human-edited config, JSON for portable data.**
Theme *data* is JSON ([ADR-0023](0023-theming-and-extension-loading.md) §2 — machine-portable,
Zed-adjacent, imported); the config that points at it is TOML (human-edited, commented). Different
audiences, different formats — not an inconsistency.

**3. Precedence, resolved once and cached** — the pharos pattern
([study](../research/pharos-mcp-study.md)):

```
compiled defaults  <  global TOML (XDG/HOME)  <  project .geex.toml (walked up from cwd)  <  GEEX_* env
```

The resolved config is parked in `:persistent_term`; every reader (theme select, grammar resolve,
the MCP port) consults the cache, never re-reads env/files. `GEEX_*` env vars stay the lowest-
friction override (and remain how boot-critical values like `GEEX_MCP_PORT` reach
`runtime.exs`); the TOML file is the durable form of the same settings.

**4. What it carries — and how each kind is loaded (inherits ADR-0023 §4–6 trust split):**

```toml
# ~/.config/geex/config.toml
theme = "birds-of-paradise"                 # DATA: bundled name → parse + validate (no sandbox)
# theme = { path = "~/themes/birds.json" }  # …or an explicit file path
[grammars]                                  # CODE: explicit path → wasmtime sandbox + ABI check
rust = "~/grammars/tree-sitter-rust.wasm"
[extensions]                                # CODE: explicit path → wasmex sandbox + contract check
my-ext = "~/ext/foo.wasm"
# [keymap]  — deferred to the interactive TUI loop (its first real consumer)
```

Data (themes) may additionally be auto-scanned from a `themes/` dir (harmless); **code (grammars/
extensions) is explicit-path only** — loading executable bytes must be a declared, auditable act,
never auto-scan magic ([ADR-0023](0023-theming-and-extension-loading.md) §5). Reading the config
file itself executes nothing.

**5. Scope of the first build.** `Geex.Config` (load + `:persistent_term` cache + accessors), the
TOML dep, the `GEEX_*` env projection, and wiring `theme` selection to the existing
`Geex.Theme.load/1`. Grammar/extension path resolution lands with their loaders; the **keymap is
deferred to the interactive TUI loop** ([ADR-0024](0024-tui-core-extractable.md)), its first
named consumer — consistent with the named-consumer rule ([vision.md](../vision.md) §3).

## Consequences

- The install story from ADR-0023 becomes real: a user selects a bundled theme by name or points at
  a file, and (later) declares grammar/extension paths — all through one human-owned file with a
  predictable precedence chain.
- One new **data-only dep** (a TOML parser). No new security surface: config is parsed, not run;
  the trust gate is the WASM sandbox that the *declared paths* feed, unchanged from ADR-0023.
- `GEEX_MCP_PORT` and friends gain a documented home in the precedence chain rather than living only
  as ad-hoc env reads in `runtime.exs`.
- A clean seam for the future: keymap, per-language settings, and editor preferences all land in
  this layer without touching app/runtime config.
- **Decided: TOML** — the pointer-layer rule (§2a) keeps the config shallow, so TOML's only weakness
  (arrays-of-tables) never bites. The one deferred concrete is pinning the specific pure-Elixir,
  NIF-free parser package when `Geex.Config` is built.

## See

[ADR-0023](0023-theming-and-extension-loading.md) (the install model this implements),
[ADR-0024](0024-tui-core-extractable.md) (the TUI loop that brings the keymap consumer),
[pharos-mcp-study](../research/pharos-mcp-study.md) (the precedence-chain + persistent_term pattern),
`lib/geex/theme.ex` (`load/1` — the path-ready loader awaiting this reader).
