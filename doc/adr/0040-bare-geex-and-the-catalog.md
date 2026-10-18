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
  atoms cyan, numbers and constants yellow, functions blue, comments dim and italic.
  Every capture Birds of Paradise styles has one.
- **Comments are dim, not bright black.** The review found that some schemes make ANSI 8 the
  background itself (Solarized Dark's base03). The line numbers and dividers stay ANSI 8, so in
  such a scheme they fade into the background. A wrong colour costs legibility, never
  correctness. Telling would take another query (OSC 4 for colour 8), not built.
- **The status line** is reverse video in every theme. Before, it swapped fg and bg, which drew
  nothing with the terminal theme's two `:default`s.
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

### Built 2026-10-18 (step 5): installing, and loading what's installed

**`Geex.Install`** is the one install path, for the catalog and for local packages:

- **The download** (the coordinator session's review notes, folded in):
  - It uses `:httpc` with `:ssl` in `verify_peer` mode, against
    `:public_key.cacerts_get/0`. It sends SNI for each host, and checks host names with
    `pkix_verify_hostname_match_fun(:https)`, so the wildcard certificate of the CDN that a
    GitHub release asset redirects to verifies.
  - Redirects are followed by hand (at most 5) and never from https to anything else
    (`Install.redirect/2`).
  - The body is streamed with a 32 MB cap and cut off past it, before anything is written or
    hashed.
  - Checked live: a wrong host, a self-signed and an expired certificate (badssl.com) are each
    refused at the handshake. A real GitHub asset installs, through its 302 to the CDN.
- **The checks:**
  - The sha256 must be the catalog's. A local package's own hash is recorded.
  - Every zip entry must be a file with a flat name from the package's expected set, with no
    repeats, at most 64 MB unpacked in all, and checked before unpacking. A name is
    `[a-z0-9][a-z0-9_-]*`.
  - The package is unpacked in memory, in a process whose heap is capped (shared binaries
    included), so a zip whose headers lie is killed, not the editor.
  - A symlink can't get through. Erlang's `:zip` reports one as a regular file (its mode masked
    to 0o777), and geex writes every entry itself as a plain file, so a "link" lands as a file
    holding its target's name. The review asked for links to be refused, but they can't even be
    seen; a test checks the outcome instead.
- **Validation:** the manifest must name the expected kind and name. A grammar's ABI must be in
  13–15 and the NIF must load its wasm and query, which also warms the compile cache. A theme
  must pass `Theme.from_json/1`.
- **Writing:** `.<name>.new-N` beside its place, with `installed.json` (sha256, source, time)
  written last, then renamed in. Anything already there is renamed aside, then removed.
- **The network:**
  - `:inets` is in the release as `applications: [inets: :load]`: carried and loaded, not
    started at boot, and not a dependency of `:geex`. Mix won't let a permanent app depend on a
    loaded one; `d2cc70e` fixed the first try, whose deploy failed.
  - `:ssl` was already started at boot, a dependency of ThousandIsland (Bandit's socket layer)
    for the loopback listener; starting it makes no request.
  - Under mix, `prune_code_paths: false` keeps OTP's apps on the code path. Mix's pruning hides
    an app a project doesn't declare, even `:http_util`.
  - A test reads every geex module's import table: only `Geex.Install` calls `:httpc` or
    `:inets`, or connects with `:gen_tcp` or `:ssl`. (`Geex.MCP.Port` listens on loopback to find
    a free port.)
- **The step 5 review** (an adversarial subagent, with probes) found these, all fixed and
  tested:
  - **Two installs of one name at once could lose the package.** A failed rename skipped the
    rollback, and the temporary names could clash across VMs. Now a `.<name>.lock` is made
    exclusively for the swap; one left by a dead process is taken over, and a live one answers
    `:busy`. The temporary names carry the OS pid and random bytes. Every write and rename is
    checked, and a failed second rename puts the first back.
  - **A zip bomb in `manifest.json`** was unpacked before any check, outside the heap cap. Now
    its listed size must be at most 64 KB, and it is unpacked in the capped process.
  - **`"filenames": null`** installed and then crashed every file open. Now file names must be
    absent or lists of non-empty strings, and `Catalog.match/2` ignores anything else.
  - **A local package directory followed links.** It copied a 0600 file into a 0644 package.
    Now it reads only the names a package may have, each a plain file (`lstat`) under the caps.
    The rest of a grammar's checkout is left alone. Installed files are 0644.
  - **Names and types:** a theme named `installed`, `manifest` or `terminal` is refused; a
    non-string name or display is refused.
  - **A compile racing an update could cache the old grammar.** The cached handle now carries
    its build (the install's sha256), so a stale one is compiled again.
  - **Smaller ones:**
    - A catalog download is capped at the catalog's size plus 4 KB.
    - A heap-cap kill is told apart from a bad zip.
    - A cut-off request's messages are drained.
    - The watcher isn't told twice about an install in its own VM (`Watcher.seen/3`).
    - The theme in use is reloaded when it's updated.
    - `--list` keys by kind and name.
    - The CLI prints what failed.
  - **Left as is:** the body of a non-200 response isn't capped (`:httpc` streams only 200 and
    206). A hostile host can cost memory, never correctness, since the sha256 decides. Installs
    aren't fsynced before the rename.
- **The binary must exit:** `geex install --list | head -1` hung the binary. A write to the
  closed pipe raised inside the application's start, where the binary does its work. The install
  branch now always reaches its halt.

**`Geex.Installed`** lists what's installed:
- It reads `$XDG_DATA_HOME/geex/{grammars,themes}/*`, ignoring a directory with no
  `installed.json`, and caches the result in `:persistent_term` (`refresh/0`).
- The bundled `priv/grammars` now carry a `manifest.json` each and are read the same way, until
  step 7.
- `update?/1` compares an install's recorded sha256 with this geex's catalog, with no request.

**What highlights a file** is decided from the installed manifests:
- **The extension map:** `Highlight.language_for_path/1`'s hardcoded map is gone; the manifests'
  `filenames`, then their longest ending, decide.
- **The status:** `Highlight.grammar_status/1` says `{:ok, lang}`, `{:needs_update, display}`
  (an ABI outside 13–15) or `{:available, display}` (the catalog has one).
- **Version skew:** `Grammars.handle/1` refuses a grammar of another ABI, as
  `{:error, {:abi, n}}`, without loading it. Opening such a file says "<Display> highlighting
  needs an update: geex install <lang>", which step 6 changes to Alt+Y.
- **Themes:** `theme NAME` finds installed themes too (`Theme.named/1`).

**Without a restart:**
- An install in this VM tells the loop, `{:geex_installed, kind, name}`. Every open file the
  grammar covers starts its reactor again, and the loop subscribes to the new one.
- `Geex.Installed.Watcher`, started with the loop, watches the two install directories without
  recursion. An install by *another* geex, `geex install` in a second terminal, is read about
  300 ms later. A package that is new, or whose sha256 changed, has its compiled grammar
  dropped, and the loop is told the same way.
- Checked live: a Python file open as plain text took Python's colours about 2 s after
  `geex install python` ran in another process.

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

**Built 2026-10-18 (step 6).** `Geex.Loop.Settings` is the view: its state, keys, clicks, rows and
drawing, all pure. The loop carries out what it asks for. `Alt+Y` amends ADR-0037. The view:

- **Languages** lists the catalog's 16 grammars with their size and one of: available,
  installed, update available, bundled (until step 7), installing…. Enter or a click on an
  available or updatable one installs it in a process of its own (ADR-0035). The view says
  "installing rust…", then "installed Rust" or what went wrong. An open file of that language
  highlights when the install lands (step 5's message).
- **Themes** lists the built-in terminal theme, then the bundled, installed and catalog ones,
  with "✓ in use". Moving the highlight previews a theme that's here. Enter, or a click,
  chooses: one not yet installed is installed first, then chosen. The choice is kept in
  `settings.json`. Leaving with Esc or `Alt+Y` without choosing puts back the theme that was in
  use.
- **Keys** is `Geex.Loop.KeyHelp`, every key grouped, filtered by what you type (each word
  must match).
- **General:** the mouse; the file tree and the edits pane shown at start (each toggled now and
  kept); where the settings, the packages and the compiled grammars live.
- **Moving around:** Tab, ←, → (or `Alt+A`/`Alt+D`, added the same day) change tabs; ↑ ↓ (or
  `Alt+W`/`Alt+S`) move the highlight; the
  wheel moves it three rows; a click on a tab switches to it. The quit keys still quit.
- **Settings** (`Geex.Settings`) are `theme`, `mouse`, `tree` and `edits` in `settings.json`,
  written to a temporary file and renamed in. They're applied at start, and anything malformed
  is ignored. Tests use their own `settings_path`.
- **The hint:** opening a file the catalog can highlight, but that isn't installed (or is
  installed for another ABI), says "JavaScript highlighting available: Alt+Y" (or "… needs an
  update: Alt+Y"), once per language a session. `Alt+Y` then opens with that language
  highlighted.
- **Up to date** (the coordinator's note on step 5): installing a package whose installed
  record is already this catalog's sha256 fetches nothing ("rust is already installed (up to
  date; --force installs it again)"). `geex install --force` reinstalls a damaged one.
- **The step 6 review** (an adversarial subagent, with probes) found these, fixed and tested:
  - **A slow install could undo a later choice.** One started by choosing an uninstalled theme
    chose it when it finished, even after the user chose another and closed the view, and
    rewrote `settings.json`. Now choosing a theme, or closing the view, cancels every pending
    choice.
  - **Moving to Themes highlighted row 0** (the terminal theme), so Tab then Enter switched
    to it. A tab change now highlights the theme in use.
  - **General showed this session's state** under the label "at start", and saved the opposite
    of it. It now shows and turns over what `settings.json` keeps: unset, the mouse is on, and
    the tree and the edits pane are "auto" (wide terminals).
  - **A `settings.json` that isn't JSON** was rewritten with only the new key. It is left alone
    now, and the view says so.
  - **A hint from a file opened behind the open view** was used up unseen; it is now kept for
    later.
  - **A theme that fails to load** said so in the hidden notice; it now says so in the view.
  - **On a screen three rows tall**, a click on the help line acted on a row. The list has no
    rows there now.
  - **`geex install --force`**, alone or with `--list`, is the listing.
  - **After an install** the loop reads the packages again, in case its own read raced the
    install's, and keeps the highlight on its row by name.
  - **The view now keeps the highlight on screen** after the terminal shrinks.
  - **Left as is:** two geex writing `settings.json` at once can lose one of the writes; the
    file itself never corrupts.
- **The coordinator's note:** General's paths show `~` for the home directory, and one too long
  is cut from the left with "…", so its file name shows.

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

### Built 2026-10-18 (step 7): geex is bare

- **No `priv/` at all.** The Elixir and JSON grammars and Birds of Paradise moved to
  `test/fixtures/{grammars,themes}`, and NOTICE follows them. The bundled-grammar path in
  `Geex.Installed` is gone, along with `Theme.bundled/1` and the "bundled" status.
- **The default theme** is the built-in terminal theme (`Theme.default/0`, `theme_id
  "terminal"`). A kept choice in `settings.json` still wins at start, if that theme is
  installed. The palette's "theme birds-of-paradise" entry became "theme", which prefills the
  verb.
- **Tests:** `Geex.Fixtures` (`test/support`, compiled under test only) installs the fixture
  grammars and theme into the test data directory from `test_helper.exs`, as a user's local
  installs, afresh each run. A test that needs another data directory installs them there.
  The rendering tests that check Birds of Paradise's colours load it with
  `Geex.Fixtures.birds/0`.
- **For a user:** after this deploy, a file shows plain text in the terminal's colours until its
  language is installed. The first Elixir file says "Elixir highlighting available: Alt+Y", or
  run `geex install elixir`. An already-installed package is untouched. The coordinator session
  tells the maintainer before it lands, and installs nothing for them (§3).
- `mix geex.highlight` uses the kept theme, else the terminal theme, and the installed grammars.

### 9. Not covered: injections

The NIF highlights one grammar per file. A language embedded in another (HEEx inside `~H`,
JavaScript inside `<script>`, SQL in a string) stays the host's string or text colour.
`injections.scm` is not packaged or used. Recorded in the roadmap.

### The first catalog

Grammars: elixir, json, javascript, typescript, tsx, python, rust, go, bash, markdown, html, css,
toml, yaml, erlang, heex. Themes: birds-of-paradise. Each recipe pins an upstream commit and
records its licence; each package carries that licence.

**Built 2026-10-18 (step 4):** `mix geex.catalog`.
- **The recipes** are Elixir data: `catalog/grammars.exs` and `catalog/themes.exs`, read only
  by the task, with Birds of Paradise and its licence in `catalog/themes/`. A recipe pins a tag
  *and* its commit. The task clones the tag and stops if it no longer names that commit, so a
  moved tag can't change a package quietly.
- **Each grammar** is the latest release tag of its upstream, all of them `tree-sitter/…`,
  `tree-sitter-grammars/…`, `elixir-lang/`, `WhatsApp/` or `phoenixframework/`. Three grammars
  have special handling:
  - **Markdown** is the block grammar only; inline markup is a second grammar reached by
    injection.
  - **TypeScript** merges its own queries with JavaScript's, the files its
    `tree-sitter.json` names under `node_modules/tree-sitter-javascript`.
  - **TSX** also takes JavaScript's JSX queries.

  Each merged query file is headed by its source and commit.
- **The ABI** is read from the generated `parser.c` (`LANGUAGE_VERSION`). It is 14 for elixir,
  json, html, toml, typescript, tsx and yaml, and 15 for the rest, all in the NIF's 13–15.
- **Every package is checked** by loading it in `TreeSitterWasm.load_grammar/3`, so a query
  naming a node the grammar lacks stops the build.
- **The zip is deterministic** (`Geex.Catalog.Package.zip/1`: sorted entries, a fixed time), and
  so is the wasm build: two full builds wrote byte-identical `catalog.json` and assets. A
  rebuild names the same assets, and nothing new needs uploading.
- **The first catalog** comes to 1.4 MB: the largest packages are bash (229 KB), elixir
  (194 KB) and tsx (192 KB), the smallest json (4 KB).
- **`catalog.json`** puts one package per line, for one-line diffs. Its `base` is
  `https://github.com/LoganBresnahan/geex/releases/download/v0.1.0/`; the release itself is
  the coordinator session's to create.
- **`Geex.Catalog`** embeds it at compile time (`@external_resource`). It answers which grammar a
  file name belongs to: a whole name first (`rebar.config`), then the longest ending
  (`.app.src`). `Geex.Catalog.match/2` does the same over installed manifests in step 5.

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
