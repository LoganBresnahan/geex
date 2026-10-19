# Installing geex

geex runs on **Linux** (x64 and arm64, glibc 2.35 or newer: Ubuntu 22.04, Debian 12, Fedora 36,
RHEL 10 and newer; not RHEL 9, whose glibc is 2.34, nor musl systems such as Alpine) and **macOS** (Apple silicon from 0.3.0, Intel from 0.3.1). On Windows, use
WSL: geex has no Windows build. Each release is one tarball per platform with its own Erlang
runtime inside, so you don't need Erlang or Elixir installed. How it's built, and why:
[ADR-0041](adr/0041-release-without-burrito.md).

## Install

```sh
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh
```

That installs the latest release:

- the release unpacks into `~/.local/share/geex/versions/<version>/`;
- `~/.local/bin/geex` is a link to it.

If `~/.local/bin` isn't on your `PATH`, the script prints the line to add to your shell's startup
file. It never edits that file itself, and it needs no sudo.

To install a particular version:

```sh
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh -s -- --version 0.3.1
```

Then install the languages and themes you use (geex ships none,
[ADR-0040](adr/0040-bare-geex-and-the-catalog.md)):

```sh
geex install elixir json
geex install --list
```

### What the script checks

- The download's sha256 must match the release's `SHA256SUMS`, or nothing is unpacked.
- The new `geex --version` must answer before the link moves.
- The link moves in one rename, so `geex` is always either the old version or the new one.

You can read the script before running it:
[install.sh](../install.sh), or `curl -fsSL …/install.sh | less`.

### Where things go

| | Default | Override |
|---|---|---|
| program files, one directory per version | `${XDG_DATA_HOME:-~/.local/share}/geex/versions/` | `GEEX_INSTALL_DIR` (its `versions/`) |
| the `geex` link | `~/.local/bin/geex` | `GEEX_BIN_DIR` |
| grammars and themes you install | `${XDG_DATA_HOME:-~/.local/share}/geex/{grammars,themes}/` | |
| settings (`Alt+Y`) | `${XDG_CONFIG_HOME:-~/.config}/geex/` | |
| edit history, ledgers, the log (`geex.log`), a crash dump | `${XDG_STATE_HOME:-~/.local/state}/geex/` | |
| compiled grammars (a cache) | `${XDG_CACHE_HOME:-~/.cache}/geex/` | |

## Managing an install: `geex self`

From 0.3.2, each version carries the `install.sh` it was released with, and `geex self` runs it
on the install it belongs to:

```sh
geex self update                   # install the latest release (or: --version 0.3.2)
geex self rollback                 # switch back to the previous version
geex self prune                    # remove old versions no running geex uses
geex self uninstall                # remove geex's program files and its link
```

`update` downloads the latest release's `install.sh` and runs it, so it always uses the newest
installer. The other three need no network. A geex that `install.sh` didn't install (one built
and run from a checkout, say) has nothing to manage: `geex self` says how to install geex, and
changes nothing.

Each one is also an `install.sh` option, and the commands below work from any version, 0.3.0 and
0.3.1 included.

## Upgrade

`geex self update`, or run the install command again. The current version and the previous one
stay. Older versions are removed, except one a running geex still uses: that one goes at a later
install, or a `geex self prune`, once it's free. Running editors keep working through an upgrade.
Restart them to get the new version.

Installing the version you already have does nothing; add `--force` to install it again.

## Roll back

```sh
geex self rollback
# or
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh -s -- --rollback
```

This switches `geex` back to the previous version, with no download. Run it again to switch
forward.

## Prune

```sh
geex self prune
# or
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh -s -- --prune
```

This removes every version but the current and the previous one, keeping any that a running geex
uses. It downloads nothing, and lists what it keeps and what it removes. An install does the
same.

## Uninstall

```sh
geex self uninstall
# or
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh -s -- --uninstall
```

This removes `~/.local/bin/geex` and every version under `~/.local/share/geex/versions/`. It keeps
your grammars and themes, settings, and edit history. If a geex is running, it removes nothing:
quit it first. To remove those too:

```sh
rm -rf ~/.local/share/geex ~/.config/geex ~/.local/state/geex ~/.cache/geex
```

By hand, without the script, the uninstall is
`rm ~/.local/bin/geex && rm -rf ~/.local/share/geex/versions ~/.local/share/geex/previous`.

## From an older geex (0.2 and before)

Before 0.3, geex installed as one self-extracting file (Burrito) at
`~/.local/share/geex/bin/geex`, unpacking into `~/.local/share/.burrito/`. The script replaces
the old `~/.local/bin/geex` link and leaves those files alone. Once no old geex is running, they
can go:

```sh
rm -rf ~/.local/share/geex/bin ~/.local/share/.burrito/geex_erts-*
```

## From source

See the [README](../README.md): `mix geex.deploy` builds this checkout and installs it with the
same script. Its version names the commits it was built from: `<version>+<geex commit>.<tree_sitter_wasm
commit>`, with `.dirty` added if either checkout has uncommitted changes.
