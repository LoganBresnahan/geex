---
name: deploy
description: Build geex into one executable with Burrito and install it as ~/.local/bin/geex (ADR-0036), then check the installed binary live — version, a file, a directory, quitting restores the terminal, the attestation discovery file. Keeps the previous binary for --rollback. Run when you want the `geex` command to be the current build; requires the suite green twice first.
---

# /deploy — build and install the `geex` binary

`mix geex.deploy` does the build and the install. This skill adds the bar before it and the live
check after it. The binary is local: it carries this machine's ERTS and the glibc
tree_sitter_wasm NIF ([ADR-0036](../../../doc/adr/0036-installed-binary.md)), so it is not
something to copy to another machine.

**Preconditions (stop if unmet):**

1. The working tree is clean, or the user okayed deploying it dirty. A dirty build's version is
   `0.1.0+<sha>.dirty`, so it doesn't name its code.
2. The ship bar: `mix compile --warnings-as-errors`, then `mix test` green **twice**. Run them;
   don't go from memory.
3. The toolchain: `zig version` is `0.15.2` (Burrito 1.5 needs 0.15; 1.6 needs 0.16), and `xz`
   is present.

## 1. Build and install

```sh
mix geex.deploy
```

- It runs `MIX_ENV=prod mix release --overwrite`, so the build output streams by.
- The first prod build, or one after `../tree_sitter_wasm` changed, compiles the Rust NIF in
  release mode and takes minutes. Later builds take about a minute.
- It ends with `geex deploy: installed <version> at …/geex/bin/geex, linked from
  ~/.local/bin/geex`.
- If it stops because `~/.local/bin/geex` is something else, ask the user. Don't remove it.

Check it by exit status and that last line, not by scrollback. Burrito prints a lot, and a
stale binary looks the same in a listing. The version has to be the commit you meant:
`git rev-parse --short=8 HEAD`.

## 2. Check the installed binary live

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
- `$TMPDIR/geex.log` has no `terminating` lines.
- `geex notes.txt`, where `notes.txt` holds `IO.puts("x")`, opens the file. It must not
  print `x`: Elixir's CLI evaluating arguments is the trap ADR-0036 §2 avoids.

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

It swaps `geex` and `geex.prev` under `$XDG_DATA_HOME/geex/bin` and prints the version now
installed. `mix geex.deploy --no-build` reinstalls the last build without building.

## Traps

- **A stale unpack:** Burrito skips unpacking when `~/.local/share/.burrito/geex_erts-*_<version>`
  exists. The task removes the new version's directory before its first run. If a binary still
  runs old code, run `geex maintenance directory` to find the directory, delete it, and run
  again.
- **`geex maintenance …` is Burrito's**, not a file. `geex -- maintenance` opens a file named
  `maintenance`.
- **Running editors keep the old binary.** Restart them after a deploy. The new version's first
  run removes the old version's unpacked files, which an old instance may still need for a
  grammar it hasn't loaded yet.
