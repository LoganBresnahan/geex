# ADR-0040: geex ships bare; grammars and themes install from a catalog fixed per release

- **Status:** Accepted 2026-10-18 (the maintainer's decisions, relayed by the coordinator session
  and built autonomously at the maintainer's word). Steps 2–7 build it; each amends this ADR
  with what it found.
- **Date:** 2026-10-18
- **Amends:** [ADR-0023](0023-theming-and-extension-loading.md) §5 ("geex fetches nothing") and
  §7 ("no marketplace"). §4 (themes are data, grammars are sandboxed `.wasm`, separate load paths)
  and §6 (the three-layer safety pipeline) stand.
- **Relates to:** [ADR-0025](0025-user-config-layer.md) (the user config, still unbuilt),
  [ADR-0035](0035-the-loop-never-waits.md) (the loop never waits), [ADR-0036](0036-installed-binary.md)
  (the installed binary), [ADR-0037](0037-pane-and-file-keys.md) (the keys; `Alt+Y` is amended
  there in step 6), [ADR-0039](0039-mouse.md) (the settings view takes the mouse)

## Context

geex bundles two grammars (Elixir and JSON, `priv/grammars`) and one theme (Birds of Paradise,
`priv/themes`), and maps file extensions to languages in code (`Geex.Highlight.language_for_path/1`).
Any other language is plain text, and adding one means rebuilding geex. ADR-0023 chose "drop a
file, declare its path" as the whole install story and ruled out fetching, but the config that
would declare the path (ADR-0025) was never built, so today there is no way to add a language at
all.

Going public (Apache-2.0, 2026-10-18) raises two more questions: what geex may redistribute
inside its own tree, and what a new user sees on first start. The maintainer's answer: geex ships
with nothing third-party, and installs a language or a theme in one click from a catalog that the
geex release itself pins.

## Decision

### 1. geex ships bare

- **No grammar and no theme in the tree or the binary.** `priv/grammars` and `priv/themes` go
  (step 7); tests use fixtures under `test/fixtures/`. Birds of Paradise lives only in the
  catalog, with its BSD 3-Clause notice.
- **A built-in look that is always the user's own terminal:** the default foreground and
  background (SGR 39/49) and the 16 ANSI colours, plus a built-in **"terminal" syntax theme**
  that maps captures to those colours. It is code, not a file, so a bare geex highlights nothing
  yet but looks right in any terminal and any colour scheme (step 3).
- To shade the active line and the selection, geex may ask the terminal for its background
  (OSC 11) and derive a subtle tint from the answer. A terminal that doesn't answer within a short
  wait gets the plain fallback (reverse video for the selection, nothing for the active line).
  Windows Terminal (the maintainer's) is checked live in step 3.

**Built 2026-10-18 (step 3):**
- **The theme** is `Geex.Theme.Terminal`, named `terminal`. Its palette is the terminal's
  default foreground and background, line numbers in bright black (ANSI 8), and the cursor's
  accent in yellow (ANSI 3).
- **Syntax** captures map to ANSI colours: keywords magenta, strings green, escapes, types and
  atoms cyan, numbers and constants yellow, functions blue, comments bright black and italic.
  Every capture Birds of Paradise styles has one.
- **With the background known,** the active line moves 7% and the selection 22% from it,
  toward white on a dark background and black on a light one (luminance under half is dark).
  Those two are truecolor; the rest is 16-colour.
- **With no answer,** there is no active-line shade, and the palette's new `mark` field is
  `[:reverse]`. The selection, a picked tree, edits or picker row, and the minibuffer line are
  drawn in reverse video. The shown tab of an unfocused pane is underlined. A theme file's
  palette has `mark: []`, so Birds of Paradise draws as before.
- **The query** is `ESC ] 11 ; ? ESC \`. `Geex.TerminalIO` sends it at start, only when stdin and
  stdout are both terminals (`:prim_tty.isatty/1`). It doesn't wait: the first frame uses the
  fallback, and an answer re-tints. `TerminalIO` keeps the answer for a subscriber that comes
  after it.
- **The answer** arrives on the same input as the keys, and the coordinator session's review
  asked that it never be read as keys:
  - `Geex.Input.Parser` reads `ESC ] Ps ; Pt`, ended by BEL or ST, whole, into
    `{:osc, ps, pt}`; any OSC, not only 11.
  - A partial one is held as leftover, up to 256 bytes, then dropped. `ESC ] 11 ;` is always
    held: nobody types it. A shorter start (`ESC ]`, `ESC ] 1`, `ESC ] 11`) is held only for the
    query's first second (`Parser.osc_reply?/2`); after that it is Alt+] and what followed,
    flushed as keys.
  - An answer that comes late, after the first frame or after a key, is still read as one.
  - An ESC inside that isn't ST means it wasn't an OSC: the rest is read again.
- **Choosing it:** `theme terminal`, `theme birds-of-paradise` and `theme` (which lists them)
  switch for the session, and the palette has both. The default stays Birds of Paradise until
  geex goes bare (step 7), and `Alt+Y` keeps the choice (step 6).
- **Checked live** in tmux, which doesn't answer OSC 11 with no client attached, so that was the
  fallback: the selection was reversed. Then the answer's bytes were sent into the pane, as a
  late answer would arrive. The active line took `rgb(46,46,61)` from `rgb:1e1e/1e1e/2e2e`, the
  selection `rgb(80,80,92)`, and nothing was typed into the buffer. **Windows Terminal is not
  checked yet**: it needs the maintainer's terminal.

### 2. The catalog is fixed per release

- **Each geex build embeds `catalog.json`** at compile time: every package it can install, its
  download URL and its **sha256**. A download whose hash differs is rejected. The hash is the
  whole trust model: no signing, no key, no mirror policy. A compromised host can only make an
  install fail.
- **The catalog lives in the geex repository.** `catalog/` holds the recipes (a grammar's
  upstream repository, pinned commit, file extensions, licence, and the grammars its queries
  inherit from) and the theme files. A mix task builds the packages and writes `catalog.json`
  (step 4). There is no separate repository.
- **Packages are release assets** on github.com/LoganBresnahan/geex. Their file names carry
  their hash (`<kind>-<name>-<sha12>.zip`), so a rebuilt package never overwrites one an older
  geex pins: many catalog revisions share a release, and an older binary keeps installing what it
  was built with as long as its assets stay up. `catalog.json` holds each package's full URL, so
  the release a URL names can change without a code change.
- **A local catalog base for development** (`GEEX_CATALOG_URL`, a `file://` directory or an
  `http(s)://` base) replaces the release host, so installs are tested before a release exists.
  The hashes still apply.

### 3. geex never makes a network request the user didn't ask for

- The network is used **only** for an install or an update the user starts: `geex install`, or
  Enter (or a click) in `Alt+Y`. There is no check at startup, no background polling, no
  telemetry.
- **"Update available"** is the embedded catalog compared with what's installed: an installed
  package whose hash differs from this geex's catalog. No request is made to find that out.
- **Installed grammars and themes work fully offline.** Nothing about loading them touches the
  network.
- `:inets` and `:ssl` start only when an install begins (step 5), and a test asserts that a
  started geex runs no HTTP client.
- Downloads use OTP's `:httpc` with `:ssl` in `verify_peer` mode against the system's CA store
  (`:public_key.cacerts_get/0`), then check the sha256.

### 4. One install path, two load paths

- **Install** is shared: fetch (or read a local file), check the hash, unpack into a temporary
  directory beside the target, write the record, rename into place. A crash leaves either the old
  package or the new one, never half of one.
- Files go to `$XDG_DATA_HOME/geex/grammars/<lang>/` and `$XDG_DATA_HOME/geex/themes/<name>/`
  (default `~/.local/share/geex/`). Each directory's `installed.json` (the package's sha256, its
  catalog name, when) is written last, and a directory without one is ignored.
- **Load** stays as ADR-0023 §4 has it: a theme is JSON, read and validated, never run; a grammar
  is `.wasm`, run only inside the NIF's wasmtime sandbox. A theme package can't carry a grammar's
  code, nor the reverse; the package's kind decides which loader sees it.
- **A package** is:
  - a grammar: `parser.wasm`, `highlights.scm` (inherited queries already merged in, so it
    stands alone), `manifest.json` (name, file extensions, the tree-sitter language ABI, the
    licence, the upstream repository and commit), and the upstream `LICENSE`;
  - a theme: its JSON, `manifest.json`, and its licence.
- **Which language a file is** comes from the installed manifests' extensions; the hardcoded
  map in `Geex.Highlight` goes (step 5). The catalog's manifests (not installed) feed a one-line
  hint on opening a file: "JavaScript highlighting available, Alt+Y" (step 6).
- **An install takes effect without a restart:** open buffers of that language highlight once
  it lands, off the loop (ADR-0035).
- **The offline paths stay:** `geex install ./dir` (or a package `.zip`) installs a local
  package by the same path, the hash then being the file's own. ADR-0023's config line,
  `[grammars] lang = "path.wasm"`, stays the plan; it arrives with the user config (ADR-0025),
  which this ADR doesn't build.

### 5. Version skew is shown, never a crash

A grammar built for a tree-sitter language ABI the NIF doesn't support (the manifest says which;
tree-sitter 0.26.9 loads ABI 13 to 15) is not loaded. Its files show as plain text and the
status line says "<Language> highlighting needs an update (Alt+Y)". A grammar the engine rejects
for any other reason is treated the same way. The catalog's own packages are built with the CLI
the NIF pins (0.26.9), so a catalog install never hits this; a hand-installed or stale package can.

### 6. `geex install`

`geex install <lang|theme>` installs from the embedded catalog; `geex install --list` prints the
catalog with what's installed and what has an update; `geex install ./path` installs a local
package. Each runs in the terminal before the editor starts (like `--version`), prints what it
did, and exits.

### 7. `Alt+Y`, the settings view (step 6)

A full-screen view, tabbed: **Languages** (name, size, installed / available / update; Enter or
a click installs), **Themes** (choosing one previews it live), **Keys** (a searchable reference),
**General** (the mouse, layout defaults, the config path). Esc or `Alt+Y` closes it, and the mouse
works throughout (ADR-0039). A chosen theme, and any other setting the view changes, is stored in
`$XDG_CONFIG_HOME/geex/settings.json`, which geex writes itself; the hand-edited `config.toml`
(ADR-0025), when it exists, is read over it.

### 8. Compiling a grammar is cached on disk (step 2)

Loading a grammar compiles its `.wasm` with wasmtime: measured on the prod build, 152–173 ms for
Elixir's 1.4 MB parser, 12–14 ms for JSON's 6 KB, against 47 ms to highlight `lib/geex/loop.ex`.
With a catalog of 16 or more grammars this is paid on every first open of each language. The NIF
gets wasmtime's compilation cache, kept in `$XDG_CACHE_HOME/geex/wasm`. An unwritable directory
means no cache, never an error, and a wasmtime upgrade must not load stale code from it.

**Built 2026-10-18 (step 2),** `tree_sitter_wasm` 0bc6629:
- **How:** `TreeSitterWasm.load_grammar/4` takes `cache_dir:`. A direct `wasmtime =36.0.10`
  dependency with its `cache` feature unifies with the wasmtime tree-sitter embeds. Read in
  tree-sitter's `wasm_store.c`: both its stdlib module and the grammar compile with
  `wasmtime_module_new` on the engine passed in, so both are cached. There is one engine per
  directory, made once (a cache starts a worker thread).
- **Staleness, read in wasmtime's source:** the cache key hashes `Config::module_version`
  (wasmtime's version) with the compiler's settings, and a cached artifact is version-checked
  again when loaded. So another wasmtime misses and compiles. The cache's directory name, meant
  to carry the git revision, is empty in a crates.io build, so the key carries the version
  instead. A test damages every entry and checks the next load compiles afresh.
- **Measured** through `Geex.Highlight.Grammars.handle/1`, a new VM each time: Elixir 154 ms
  with an empty cache, 72 ms warm; JSON 3 ms, then under 1 ms. In the NIF alone, Elixir's
  `.wasm` takes 5 ms from the cache. The other ~67 ms is `Query::new` compiling its
  `highlights.scm`, which no wasm cache covers. Caching the query would need tree-sitter to
  serialize one, which it can't.
- **geex** caches in `$XDG_CACHE_HOME/geex/wasm` (`~/.cache/geex/wasm` by default,
  `Grammars.cache_dir/0`). It is off under test (`wasm_cache`).

### 9. Not covered: injections

The NIF highlights one grammar per file. A language embedded in another (HEEx inside `~H`,
JavaScript inside `<script>`, SQL in a string) stays the host's string or text colour.
`injections.scm` is not packaged or used. Recorded in the roadmap.

### The first catalog

Grammars: elixir, json, javascript, typescript, tsx, python, rust, go, bash, markdown, html, css,
toml, yaml, erlang, heex. Themes: birds-of-paradise. Each recipe pins an upstream commit and
records its licence; each package carries that licence.

### Out of scope

- A marketplace: listing, searching or hosting anything outside the release's own catalog.
- Packages from third parties, signing, and mirrors.
- Extensions and adapters (ADR-0023 §4's third kind) by this path.
- Removing a package from `Alt+Y` (step 6 may add it; deleting the directory works).

## Consequences

- A fresh geex has no syntax colour until the user installs a language. It still looks like the
  user's terminal, and the first file of a known type says how to fix that.
- geex's tree holds only geex's code, so its licence is one licence. Third-party licences travel
  with each package.
- The release process gains a step: building the catalog's packages and uploading them before
  publishing a binary that pins them. A binary whose assets are missing can't install, but works.
- Trust is the release: whoever can change geex's source or its embedded catalog decides what
  installs. Nothing is fetched that the binary doesn't already name by hash.
- Two machines on the same geex get byte-identical packages; a newer geex may pin newer ones,
  and "update" means "this geex's version".

## See

- [ADR-0023](0023-theming-and-extension-loading.md) (§4 the three kinds, §6 the safety pipeline),
  [ADR-0025](0025-user-config-layer.md), [ADR-0035](0035-the-loop-never-waits.md).
- `catalog/` (step 4), `lib/geex/highlight/grammars.ex`, `lib/geex/theme.ex`, `NOTICE`.
