# ADR-0041: Releases without Burrito — a tarball per target, a launcher, install.sh, CI

- **Status:** Accepted 2026-10-19. The maintainer's big run, directed by the coordinator session:
  Burrito leaves geex (and pharos), and geex is the first to ship this way. pharos copies the
  recipe, so §8 states it apart from geex. Built and shipped as 0.3.0. Before the tag, the
  release dry run was green on all three targets, and the darwin-arm64 tarball passed
  `rel/smoke.sh` on the maintainer's M1.
- **Date:** 2026-10-19
- **Supersedes:** [ADR-0036](0036-installed-binary.md) §1 (the Burrito wrap), §4 (`mix geex.deploy`)
  and §6 (the Burrito fork). §2 and §3 (the work done inside `Application.start/2`, the orderly
  quit) and §5 (the trim) stand, §2 with a new reason.
- **Relates to:** [ADR-0040](0040-bare-geex-and-the-catalog.md) (the catalog and its releases),
  the sacred invariant "the terminal belongs to the renderer"

## Context

ADR-0036 wrapped the release in one Burrito executable that unpacked itself on first run. That
was a local install: the release carried this machine's ERTS and the glibc NIF, so it ran here
and nowhere else. Two days of it showed what the wrapper cost:

- Burrito's launcher ran the VM in interactive mode (its `-mode embedded` was one argv element),
  so deleting an unpack crashed a geex still running from it (BUG-4). geex carried a fork to fix
  that and to lock an unpack in use.
- A second layer of versions (the unpack directories) to clean, beside geex's own.
- Its output on stdout, which broke `--version` checks.
- No portable build: its musl ERTS can't load a NIF built against glibc, and there was no build
  for a Mac at all.

geex goes public with installs on Linux and macOS, so the release has to be built per target, and
installed by something a user can read.

## Decision

### 1. The runtime: OTP built from source per target, linked to what every system has

`rel/build-runtime.sh PREFIX` builds the runtime a release carries, on the machine it targets:

- **Erlang/OTP 28.1.1**, from erlang/otp's release tarball;
- **OpenSSL 3.5** (the LTS), static: the crypto NIF links it in, so the release needs no
  libcrypto;
- **ncurses 6.5**, static, Linux only, as `libtinfo.a`. `:prim_tty` looks the terminal up with
  `tgetent` before it goes raw, so OTP needs a termcap library, and dropping it (`--without-termcap`)
  would leave geex no terminal. The static library reads the system's terminfo database, from the
  directories glibc distributions use (`/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo`;
  Debian keeps xterm's in `/lib`). The common terminals (xterm, screen, tmux, linux, vt100, and their
  256-colour forms) are compiled in as fallbacks, so they work with no database. macOS has ncurses
  in the OS;
- **zlib** from OTP's own copy (`--enable-builtin-zlib`), and the C++ runtime the JIT is written
  against linked statically (`-static-libstdc++ -static-libgcc`);
- **Elixir 1.19.5**, its precompiled `elixir-otp-28.zip`. Elixir's `.beam` files are the same on
  every target.

Every download is checked against a sha256 pinned in the script. No third-party ERTS build is
used. CI caches the result per target, keyed by the script's hash.

**What a release may link dynamically**, checked by `native_problems/2` in the release step
(below), for every VM program and every NIF's shared object:

- **Linux:** glibc's own libraries (`libc`, `libm`, `libdl`, `libpthread`, `librt`, `libutil`,
  the dynamic loader) and `libgcc_s.so.1`. That is GCC's unwinder, which Rust's standard library
  links (the tree_sitter_wasm NIF); every glibc system has it. No symbol may need a glibc newer
  than **2.35**: Linux releases build on Ubuntu 22.04, so 22.04, Debian 12, RHEL 9 and newer run
  them. musl (Alpine) doesn't, and install.sh says so.
- **macOS:** only the OS's own libraries (`/usr/lib`, `/System/Library`). Every Mach-O must
  verify with `codesign --verify --strict`: Apple silicon kills an arm64 program whose signature a
  strip broke, so `trim_erts/2` signs the programs it strips again, ad hoc (`codesign -s - -f`).
  Every NIF's `.so` is signed ad hoc too. The arm64 linker signs what it links, but the x86_64
  one doesn't: pharos-mcp found `crypto.so` unsigned on macos-15-intel.

A release build (`GEEX_RELEASE=1`) stops on any problem. A local build, which carries whatever OTP
runs Mix (asdf's, here) and runs only on this machine, prints them as a note.

### 2. The launcher

`bin/geex` is a POSIX sh script (`rel/launcher.sh.eex`, filled in with the version and the ERTS
version at build time). It follows its own symlinks to find the release (`~/.local/bin/geex`
points at it), then `exec`s `erts-*/bin/erlexec` directly, with no other shell in between:

    erlexec -noshell -mode embedded -boot releases/V/start -boot_var RELEASE_LIB lib
            -args_file releases/V/vm.args -config releases/V/sys.config
            -geex standalone true -extra ARGS...

- `-mode` and `embedded` are two arguments, so every module loads at boot and a running geex
  needs none of its files but the VM's helper programs.
- **`-geex standalone true`** sets geex's application environment, and `Geex.CLI.standalone?/0`
  reads it. It replaces Burrito's `__BURRITO=1` environment variable: a boot flag isn't inherited
  by the programs geex starts.
- It sets `ROOTDIR`, `BINDIR`, `EMU` and `PROGNAME` for erlexec, and `RELEASE_ROOT` and
  `RELEASE_SYS_CONFIG` for Elixir's config provider (`config/runtime.exs`).
- `ERL_CRASH_DUMP`, unless the user set it, is `erl_crash.dump` in geex's state directory
  (`${XDG_STATE_HOME:-~/.local/state}/geex`, made 0700), beside `geex.log`, which moved there
  from the temporary directory in the same change. A fixed name in a shared `/tmp` could be
  planted as a symlink by another user, and the VM's default is the current directory.
- No cookie: geex never starts distribution, and a cookie published in a tarball would be
  everyone's. `package/1` removes it, and Mix's own scripts (`bin/geex.bat`, `releases/V/elixir`,
  `iex`, `env.sh`, `remote.vm.args`, `start_clean.*`).

**Launch time,** measured in tmux to the first frame (median of 5, the same commit and machine):
525 ms from the launcher, 532–555 ms from the Burrito binary. The goal was no slower.

`Application.start/2` still runs the editor and never returns (ADR-0036 §2, §3). Nothing runs
Elixir's CLI any more, so the original reason is gone; the orderly quit it led to stays, and
changing it would buy nothing.

### 3. The package

`MIX_ENV=prod mix release` runs `[:assemble, &trim_release/1, &package/1]`:

- `trim_release/1` (ADR-0036 §5, extended): the four VM programs stay, stripped with `strip -S`
  (GNU's and Apple's alike), signed again on macOS; crypto's `otp_test_engine.so` goes; then
  the module closure check, the native check (§1) and the boot-script check.
- `package/1` writes the launcher, removes Mix's scripts and the cookie, and packs the release as
  **`_build/package/geex-<version>-<os>-<arch>.tar.gz`** (os `linux` or `darwin`, arch `x64` or
  `arm64`, from the VM that built it) with a top directory of the same name, plus `SHA256SUMS`.

The version is `0.3.0+<geex sha8>.<tree_sitter_wasm sha8>[.dirty]` for a local build (each one
installs into its own directory), and the plain `0.3.0` for a release build. A release build
needs clean trees and tree_sitter_wasm at the commit `mix.exs` pins (`@tree_sitter_wasm_ref`),
and stops otherwise.

### 4. install.sh

One script, at the repository's root and attached to every release, installs a release from
GitHub and a local build alike:

    curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh
    curl -fsSL …/install.sh | sh -s -- --version 0.3.0
    sh install.sh --rollback | --uninstall | --force

- **Layout:** `$GEEX_INSTALL_DIR/versions/<version>/` holds a whole release (default
  `${XDG_DATA_HOME:-~/.local/share}/geex`, beside the grammars and themes geex installs), and
  `$GEEX_BIN_DIR/geex` (default `~/.local/bin`) is a symlink to its `bin/geex`. `previous` names
  the version before the current one.
- **The switch** is `ln -s` to a temporary name, then `mv -f` over the link: one rename, atomic
  with GNU and BSD `mv` alike, because the link points at a file. No directory symlinks, no
  `mv -T`.
- **Fail closed:** `SHA256SUMS` must have a line for the tarball and the hash must match
  (`sha256sum` or `shasum -a 256`), or nothing is unpacked. The unpacked `geex --version` must
  answer `geex <version>` before the link moves. Unpacking happens in `versions/.tmp-<pid>` and
  lands with one rename.
- **Idempotent:** the current version again does nothing without `--force`. A version already
  unpacked (the previous one) is switched to without a download.
- **Retention:** the current and the previous version stay. Each older one goes, **unless a
  running process names its directory on its command line** (`ps -A -ww -o args=`, read once):
  the VM's `-root` and `-bindir` do, and so do the helper programs it starts from `erts/bin`.
  A version in use stays until a later install finds it free. Embedded mode means a running geex
  needs none of its other files, but it starts `inet_gethost` from its `erts/bin` on a host
  lookup, which is why it is kept at all.
- **Platform checks:** Linux or macOS, x64 or arm64 (an arm64 Mac's shell under Rosetta gets the
  arm64 build), and on Linux glibc 2.35 or newer.
- **It touches nothing else:** no shell rc file (it prints a `PATH` line to add when
  `~/.local/bin` isn't on it), no geex settings, no sudo. POSIX sh, run by dash and macOS's sh.
- **The ADR-0036 layout,** a link to `…/geex/bin/geex`, is replaced, and its files are left
  with a note. Any other `~/.local/bin/geex` stops the install.
- **Uninstall:** `--uninstall` removes the versions and the link, and says what it keeps
  (grammars and themes, settings, the edit history and ledgers).
- `GEEX_DOWNLOAD_URL` replaces the release's download directory; a `file://` directory works.

**Amended 2026-10-19 (0.3.2): the installed program manages itself.** The maintainer asked for
this; pharos and captAInHook take the same names.
- **`install.sh --prune`** prunes as an install does (keep current and previous, and any version
  a running process names), downloads nothing, and names what it keeps. With no current version
  it removes nothing: the current one decides what stays.
- **Each version carries its installer:** the tarball has `install.sh` at its top, so
  `versions/<v>/install.sh` can roll back, prune and uninstall offline.
- **`geex self update [--version X] | rollback | prune | uninstall`** is the launcher's, in sh,
  with no VM:
  - A running geex is what prune and uninstall leave alone, so from a VM, uninstall would
    refuse itself.
  - The bundled installer is fed to `sh -s` on stdin for the same reason: run as
    `sh versions/<v>/install.sh`, its own command line names `versions/`.
  - `update` downloads the latest release's `install.sh` (or X's) to a temporary file and runs
    it, so an update never runs an old installer.
  - It sets `GEEX_INSTALL_DIR` from the release's own place (`versions/<v>/../..`). Run
    through its link, it also takes `GEEX_BIN_DIR` from the link's directory, unless the user
    set one.
  - A bad `self` command, or a release outside a `versions/` layout, goes on to the VM.
    `Geex.CLI.self_command/1` prints the usage (exit 2) or the install one-liner (exit 1), and
    touches nothing.
- **The smoke test** (§6) also runs `geex self prune`. It keeps an old version while a geex runs
  from it, then removes it; a copy of the one build stands in for the old version. `geex self
  update` runs from GitHub after publishing, and `geex self uninstall` replaces
  `install.sh --uninstall`.

### 5. CI

- **`ci.yml`, every push:** the suite on Linux (ubuntu-22.04), compiled with the runtime §1 builds
  (cached), not a setup-beam OTP, so the `.beam` files and the shipped VM come from one OTP. It
  checks tree_sitter_wasm out beside geex at the pinned commit.
- **`release.yml`, on a `v*` tag:** for each target (linux-x64 on ubuntu-22.04, linux-arm64 on
  ubuntu-22.04-arm, darwin-arm64 on macos-14), the cached runtime, a release build
  (`GEEX_RELEASE=1`), and a smoke test of the tarball on that runner through install.sh. Then
  one job publishes a normal release (not a pre-release, so `releases/latest` is geex) with
  every tarball, one `SHA256SUMS` and `install.sh`. Publishing runs only for a `refs/tags/v*`
  ref. **Amended 2026-10-19:** darwin-x64 on macos-15-intel joins the matrix after 0.3.0 (and
  the post-release smoke), once the NIFs are signed (§1). 0.3.0 itself has three targets.
- **Catalog releases** (ADR-0040) keep their tags `v0.1.0` and `v0.2.0`: built geex versions
  name them. From now on a catalog release is tagged `catalog-v<N>` (the next is `catalog-v3`)
  and published as not-latest, so app versions own `v*` and `releases/latest`.

### 6. The smoke test, and `geex highlight`

A check has to run geex without a terminal, so `geex highlight FILE` prints FILE highlighted as
ANSI and exits: the VM, the tree_sitter_wasm NIF, an installed grammar and a theme, with no
editor (`Geex.CLI.highlight/1`; `mix geex.highlight` is now the same code). The smoke, on the
release's own runners and after publishing (`smoke.yml`, on fresh runners, from the public URL):

- `curl … install.sh | sh` into a temporary `HOME`;
- `geex --version` is the tag's version;
- `geex install json` from the catalog, then `geex highlight` on a JSON file prints colour;
- where tmux is installed (CI installs it on Linux and macOS runners), geex starts in tmux on a
  file and shows it, `Ctrl-X` quits with 0, and the log has no `terminating` lines;
- `install.sh --uninstall` removes it.

### 7. `mix geex.deploy`

Builds as §3 does, then runs this checkout's `install.sh` with `GEEX_DOWNLOAD_URL` pointing at
`_build/package`: a local install takes the same path, checks and layout as a release install.
A dirty build is installed with `--force` (its version repeats with other code under it).
`GEEX_INSTALL_DIR` and `GEEX_BIN_DIR` pass through, so a sandbox works. `--rollback` is
install.sh's.

### 8. The recipe, apart from geex

For another BEAM app (pharos), the parts that carry over:

1. Build OTP per target from source with static OpenSSL (and static ncurses on Linux, with the
   terminfo directories and fallbacks above, if anything uses `:prim_tty` or the shell), on the
   oldest runner whose glibc you'll support. Cache it by the build script's hash.
2. Check the release's native files: list each one's libraries (`readelf -d`, `otool -L`), allow
   only the libc family (and `libgcc_s` if Rust is in), cap the glibc symbol version, and on
   macOS verify every signature, re-signing ad hoc anything you strip.
3. A POSIX sh launcher that resolves its symlink and `exec`s `erlexec` with `-mode embedded` as
   two arguments, the boot file, `-boot_var RELEASE_LIB`, `-args_file`, `-config`, and the app's
   arguments after `-extra`. Mark "running as the installed app" with a boot flag
   (`-app key value`), not an environment variable.
4. `<app>-<version>-<os>-<arch>.tar.gz` with a top directory of that name, `SHA256SUMS`,
   `install.sh`: versions in their own directories, a file symlink switched by rename, fail
   closed on the hash, keep current and previous, prune by command line, no rc edits. Ship the
   installer inside each version too, and give the launcher `self update|rollback|prune|uninstall`,
   run from the launcher's shell, not the VM (§4's amendment).
5. A headless verb for the smoke test, and a smoke workflow that installs the published release
   from its public URL on fresh runners.

## Consequences

- geex installs on Linux (x64, arm64; glibc 2.35+) and Macs from one command (Intel Macs from
  the release after 0.3.0), and the same path installs a local build.
- One directory per version, and nothing unpacks at run time: there is no second cache to clean,
  and no Burrito fork to keep. The fork stays on GitHub for history.
- The release is ~14 MB packed, ~40 MB unpacked: the same trimmed release as before, no longer
  inside a self-extracting file.
- Building the runtime is our job now: an OTP or OpenSSL update is a change to
  `rel/build-runtime.sh`, and CI rebuilds it once per target.
- A system without glibc 2.35 has no build, and an Intel Mac has none in 0.3.0 itself.
- **Catalog packages aren't byte-reproducible across zlibs.** `mix geex.catalog` deflates with
  the VM's zlib: OTP's own copy in this runtime, the system's under asdf. The same recipe can make
  different bytes, and so a different sha256. That's harmless: a catalog pins the bytes it
  published, and an install checks the bytes it downloads. But a test may not rebuild a package
  and expect the pinned hash. `SettingsTest` reads the published Birds of Paradise package from
  `test/fixtures/catalog/` instead.

## See

- `rel/build-runtime.sh`, `rel/launcher.sh.eex`, `install.sh`
- `Mix.Tasks.Geex.Deploy` (`trim_release/1`, `package/1`, `native_problems/2`)
- `Geex.CLI` (`standalone?/0`, `highlight/1`)
- `.github/workflows/`
- [doc/install.md](../install.md): installing, upgrading, rolling back, uninstalling
