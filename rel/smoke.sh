#!/bin/sh
# The smoke test of an installed geex (ADR-0041 §6): install it into a temporary HOME the way a
# user would, then run it for real.
#
#   rel/smoke.sh [--version VERSION]
#
# By default it installs from GitHub: `curl …/releases/latest/download/install.sh | sh`, or, with
# --version, that release's own install.sh. With GEEX_DOWNLOAD_URL set (a build's _build/package
# as a file:// URL) it installs from there with this checkout's install.sh, so a release job can
# check its tarball before publishing it. Needs network for `geex install json` (the catalog).
#
# Checks:
#   - `geex --version` is `geex VERSION` (or any `geex X.Y.Z` with no --version);
#   - `geex --frob` exits 2;
#   - `geex install json` installs the JSON grammar from the catalog;
#   - `geex highlight` prints a JSON file in colour, and the same text without the colour;
#   - where tmux is installed: geex opens the file in a terminal, and Ctrl-X quits with status 0;
#   - `install.sh --uninstall` removes it.
set -eu

REPO=LoganBresnahan/geex
here=$(cd "$(dirname "$0")/.." && pwd -P)
version=
while [ $# -gt 0 ]; do
  case $1 in
    --version) version=${2#v}; shift 2 ;;
    *) echo "usage: $0 [--version VERSION]" >&2; exit 2 ;;
  esac
done

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }
ok() { echo "smoke: ok: $*"; }

box=$(mktemp -d)
trap 'tmux -L geex-smoke kill-server 2>/dev/null || true; rm -rf "$box"' EXIT
HOME=$box/home
XDG_DATA_HOME=$HOME/.local/share
XDG_CONFIG_HOME=$HOME/.config
XDG_STATE_HOME=$HOME/.local/state
XDG_CACHE_HOME=$HOME/.cache
TMPDIR=$box/tmp
unset GEEX_INSTALL_DIR GEEX_BIN_DIR
export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME TMPDIR
mkdir -p "$HOME" "$TMPDIR" "$box/work"

if [ -n "${GEEX_DOWNLOAD_URL:-}" ]; then
  [ -n "$version" ] || fail "GEEX_DOWNLOAD_URL needs --version"
  sh "$here/install.sh" --version "$version"
elif [ -n "$version" ]; then
  curl -fsSL "https://github.com/$REPO/releases/download/v$version/install.sh" | sh -s -- --version "$version"
else
  curl -fsSL "https://github.com/$REPO/releases/latest/download/install.sh" | sh
fi

geex=$HOME/.local/bin/geex
[ -L "$geex" ] || fail "no link at $geex"
PATH=$HOME/.local/bin:$PATH
export PATH

said=$(geex --version)
if [ -n "$version" ]; then
  [ "$said" = "geex $version" ] || fail "--version says \"$said\", not \"geex $version\""
else
  case $said in
    "geex "[0-9]*) version=${said#geex } ;;
    *) fail "--version says \"$said\"" ;;
  esac
fi
ok "$said"

status=0
geex --frob >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "geex --frob exited $status, not 2"
ok "an unknown option exits 2"

geex install json || fail "geex install json"
ok "installed the JSON grammar from the catalog"

file=$box/work/smoke.json
printf '{"key": [1, true, "text"], "n": null}\n' >"$file"
geex highlight "$file" >"$box/out" || fail "geex highlight exited $?"
esc=$(printf '\033')
grep -q "$esc\[" "$box/out" || fail "geex highlight printed no colour: $(cat "$box/out")"
plain=$(sed "s/$esc\[[0-9;]*m//g" "$box/out")
[ "$plain" = "$(cat "$file")" ] || fail "geex highlight changed the text: $plain"
ok "geex highlight coloured the JSON"

if command -v tmux >/dev/null 2>&1; then
  tmux -L geex-smoke new-session -d -s g -x 100 -y 20 \
    "cd '$box/work' && TERM=xterm-256color geex smoke.json; echo \"geex-exit=\$?\" >'$box/exit'; sleep 30"
  i=0
  until tmux -L geex-smoke capture-pane -p -t g | grep -q '"key"'; do
    i=$((i + 1))
    [ $i -lt 100 ] || fail "geex didn't show the file in tmux: $(tmux -L geex-smoke capture-pane -p -t g)"
    sleep 0.1
  done
  tmux -L geex-smoke send-keys -t g C-x
  i=0
  until [ -s "$box/exit" ]; do
    i=$((i + 1))
    [ $i -lt 100 ] || fail "geex didn't quit on Ctrl-X"
    sleep 0.1
  done
  [ "$(cat "$box/exit")" = geex-exit=0 ] || fail "geex quit with $(cat "$box/exit")"
  if grep -q terminating "$TMPDIR/geex.log" 2>/dev/null; then fail "geex.log: $(cat "$TMPDIR/geex.log")"; fi
  tmux -L geex-smoke kill-server
  ok "geex opened the file in tmux and quit on Ctrl-X"
else
  echo "smoke: (no tmux here: the terminal check is skipped)"
fi

if [ -n "${GEEX_DOWNLOAD_URL:-}" ]; then
  sh "$here/install.sh" --uninstall
else
  curl -fsSL "https://github.com/$REPO/releases/download/v$version/install.sh" | sh -s -- --uninstall
fi
[ ! -e "$geex" ] || fail "--uninstall left $geex"
ok "uninstalled"
echo "smoke: geex $version passed"
