# Installing geex

geex runs on **Linux** (x64 and arm64, glibc 2.35 or newer: Ubuntu 22.04, Debian 12, Fedora,
RHEL 9 and newer) and **macOS** (Apple silicon from 0.3.0, Intel from the release after 0.3.0). Each release is one tarball per platform with
its own Erlang runtime inside, so you don't need Erlang or Elixir installed. How it's built, and
why: [ADR-0041](adr/0041-release-without-burrito.md).

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
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh -s -- --version 0.3.0
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
| edit history, ledgers, the log (`geex.log`) | `${XDG_STATE_HOME:-~/.local/state}/geex/` | |

## Upgrade

Run the install command again. The current version and the previous one stay. Older versions are
removed, except one a running geex still uses: that one goes at a later install, once it's free.
Running editors keep working through an upgrade. Restart them to get the new version.

Installing the version you already have does nothing; add `--force` to install it again.

## Roll back

```sh
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh -s -- --rollback
```

This switches `geex` back to the previous version, with no download. Run it again to switch
forward.

## Uninstall

```sh
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh -s -- --uninstall
```

This removes `~/.local/bin/geex` and every version under `~/.local/share/geex/versions/`. It keeps
your grammars and themes, settings, and edit history. To remove those too:

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
same script, as `0.3.0+<commit>`.
