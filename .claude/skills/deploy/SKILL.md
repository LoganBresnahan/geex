---
name: deploy
description: Build this checkout into geex's release tarball and install it as ~/.local/bin/geex through install.sh, the way a release installs (ADR-0041), then check the installed program live — version, a file, a directory, quitting restores the terminal, the attestation discovery file. Keeps the previous version for --rollback. Run when you want the `geex` command to be the current build; requires the suite green twice first.
---

# /deploy — build and install `geex`

`mix geex.deploy` does the build and the install. This skill adds the bar before it and the live
check after it. The build carries the OTP that runs Mix (asdf's, here), so it runs on this
machine; a portable build is CI's, with the runtime `rel/build-runtime.sh` makes
([ADR-0041](../../../doc/adr/0041-release-without-burrito.md)).

**Preconditions (stop if unmet):**

1. The working tree is clean, or the user okayed deploying it dirty. A dirty build's version is
   `0.3.0+<sha>.<sha>.dirty`, so it doesn't name its code.
2. The ship bar: `mix compile --warnings-as-errors`, then `mix test` green **twice**. Run them;
   don't go from memory.
3. Whether this install is live. `mix geex.deploy` installs into `~/.local/share/geex/versions`
   and moves `~/.local/bin/geex` unless `GEEX_INSTALL_DIR` and `GEEX_BIN_DIR` say otherwise. To
   try a build without touching the user's install, point both (and `HOME`, `XDG_*`) at a
   scratch directory.

## 1. Build and install

```sh
mix geex.deploy
```

- It runs `MIX_ENV=prod mix release --overwrite`, so the build output streams by. The release
  steps trim and check the release (a native-library note is expected for a local build: it links
  this machine's libraries), then pack `_build/package/geex-<version>-<os>-<arch>.tar.gz`.
- Mix's closing "To start your system … bin/geex start" text is Mix's own and doesn't apply:
  `bin/geex` is geex's launcher.
- The first prod build, or one after `../tree_sitter_wasm` changed, compiles the Rust NIF in
  release mode and takes minutes.
- Then `install.sh` installs it from `_build/package` (`GEEX_DOWNLOAD_URL=file://…`), checking
  the sha256 and the new `--version`, and ends with `geex install: installed geex <version> at …,
  linked from ~/.local/bin/geex`. A dirty build goes in with `--force`.
- If install.sh stops because `~/.local/bin/geex` is something it didn't make, ask the user.
  Don't remove it.

Check it by exit status and that last line, not by scrollback. The version has to be the commit
you meant: `git rev-parse --short=8 HEAD`.

## 2. Check the installed program live

Use an isolated tmux socket (the `/dogfood` way) and scratch state, so the user's ledger and
log stay clean:

```sh
export XDG_STATE_HOME=$(mktemp -d) TMPDIR=$(mktemp -d)
tmux -L deploy new-session -d -s g -x 120 -y 30 "cd $SCRATCH_REPO && geex a.txt"
```

- `geex --version` prints `geex <version>` and exits 0. `geex --frob` prints usage and exits 2.
- `geex FILE` shows the file. `geex DIR` (and bare `geex` inside a repo) shows the tree with a
  scratch buffer.
- Typing, `Ctrl-O`, and `Ctrl-X` all work. After `Ctrl-X` the shell prompt is back and usable:
  the alternate screen is gone and the cursor is visible.
- While it runs, `$XDG_RUNTIME_DIR/geex/<pid>.json` exists (the attestation listener). It is
  gone after quitting.
- `$TMPDIR/geex.log` reads "loading code in embedded mode" and has no `terminating` lines.
- `geex notes.txt`, where `notes.txt` holds `IO.puts("x")`, opens the file. It must not
  print `x` (ADR-0036 §2).
- `geex highlight some.json` prints it in colour, when the JSON grammar is installed.

## 3. Log it

Add a dated entry to [doc/testing.md](../../../doc/testing.md) with:

- the version;
- what you checked;
- the test count;
- what you didn't check.

## Rolling back

```sh
mix geex.deploy --rollback
```

It runs `install.sh --rollback`: `~/.local/bin/geex` points at the previous version again, with
no download. Running it again switches forward. `mix geex.deploy --no-build` installs the last
build without building.

## Traps

- **Restart running editors after a deploy** to get the new code. They keep running: each
  version has its own directory, and install.sh removes an old one only when no running process
  names it.
- **An old Burrito install** (0.2 and before: `~/.local/share/geex/bin/geex`): install.sh replaces
  its link and leaves its files, saying so. `~/.local/share/.burrito/geex_erts-*` can go once no
  old geex runs.
