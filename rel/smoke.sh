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
#   - on Linux, with tmux and inotifywait: a SIGKILLed geex leaves no file watcher running;
#   - `geex self prune` keeps the current version, and an old one while a geex runs from it
#     (tmux), then removes the old one (a copy of this version stands in for it: one build);
#   - from GitHub only: `geex self update` fetches the release's install.sh, which finds this
#     version already installed;
#   - `geex self uninstall` removes it.
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
# The attestation discovery file goes here: a SIGKILLed geex (below) can't remove its own.
XDG_RUNTIME_DIR=$box/run
unset GEEX_INSTALL_DIR GEEX_BIN_DIR
export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME TMPDIR XDG_RUNTIME_DIR
mkdir -p "$HOME" "$TMPDIR" "$box/work"
mkdir -m 700 "$XDG_RUNTIME_DIR"

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
  log=$XDG_STATE_HOME/geex/geex.log
  [ -s "$log" ] || fail "no log at $log"
  if grep -q terminating "$log"; then fail "geex.log: $(cat "$log")"; fi
  tmux -L geex-smoke kill-server
  ok "geex opened the file in tmux and quit on Ctrl-X"
else
  echo "smoke: (no tmux here: the terminal check is skipped)"
fi

# The file watchers die with the VM, however it dies. geex doesn't run inotifywait itself: the
# file_system dep runs each under `sh -c 'inotifywait … & PID=$!; read a; kill -KILL $PID'`, and
# that shell kills it when the VM's end of the port closes. This guards against a file_system
# upgrade that drops the wrapper (and is why geex ships no bosun: ADR-0041 §6's amendment).
if [ "$(uname -s)" = Linux ] && command -v tmux >/dev/null 2>&1 &&
  command -v inotifywait >/dev/null 2>&1; then
  # A repository, so the tree's watcher runs too, beside the open file's and the installed one's.
  want=2
  if command -v git >/dev/null 2>&1; then
    want=3
    git -C "$box/work" init -q
    git -C "$box/work" add smoke.json
    git -C "$box/work" -c user.name=smoke -c user.email=smoke@localhost commit -qm smoke
  fi
  # This box's processes whose program is NAME (a watcher names a directory in the box).
  procs() { ps -A -ww -o pid=,args= | awk -v box="$box" -v name="$1" \
    'index($0, box) { n = split($2, p, "/"); if (p[n] == name) print $1 }'; }
  tmux -L geex-smoke new-session -d -s g -x 100 -y 20 \
    "cd '$box/work' && TERM=xterm-256color geex smoke.json; sleep 30"
  i=0
  until [ "$(procs inotifywait | wc -l)" -ge $want ]; do
    i=$((i + 1))
    [ $i -lt 100 ] || fail "geex started $(procs inotifywait | wc -l) file watchers, not $want"
    sleep 0.1
  done
  beam=$(procs beam.smp)
  [ -n "$beam" ] || fail "no beam.smp for the geex in tmux"
  kill -KILL "$beam"
  i=0
  while [ -n "$(procs inotifywait)" ]; do
    i=$((i + 1))
    [ $i -lt 50 ] || fail "a SIGKILLed geex left inotifywait running: $(procs inotifywait)"
    sleep 0.1
  done
  tmux -L geex-smoke kill-server
  ok "a SIGKILLed geex left no file watcher running"
fi

versions=$(cd "$XDG_DATA_HOME/geex/versions" && pwd -P)
old=$versions/0.0.0-smoke
cp -R "$versions/$version" "$old"
if command -v tmux >/dev/null 2>&1; then
  tmux -L geex-smoke new-session -d -s g -x 100 -y 20 \
    "cd '$box/work' && TERM=xterm-256color '$old/bin/geex' smoke.json; echo done >'$box/old-exit'; sleep 30"
  i=0
  until tmux -L geex-smoke capture-pane -p -t g | grep -q '"key"'; do
    i=$((i + 1))
    [ $i -lt 100 ] || fail "the old geex didn't show the file in tmux"
    sleep 0.1
  done
  geex self prune >"$box/out" 2>&1 || fail "geex self prune: $(cat "$box/out")"
  grep -q "kept 0.0.0-smoke: a running geex uses it" "$box/out" || fail "self prune: $(cat "$box/out")"
  [ -d "$old" ] || fail "geex self prune removed a version a running geex uses"
  tmux -L geex-smoke send-keys -t g C-x
  i=0
  until [ -s "$box/old-exit" ]; do
    i=$((i + 1))
    [ $i -lt 100 ] || fail "the old geex didn't quit on Ctrl-X"
    sleep 0.1
  done
  tmux -L geex-smoke kill-server
  ok "geex self prune kept a version a running geex uses"
fi
geex self prune >"$box/out" 2>&1 || fail "geex self prune: $(cat "$box/out")"
grep -q "kept $version (current)" "$box/out" || fail "self prune: $(cat "$box/out")"
grep -q "removed 0.0.0-smoke" "$box/out" || fail "self prune: $(cat "$box/out")"
[ ! -d "$old" ] || fail "geex self prune left 0.0.0-smoke"
[ -x "$versions/$version/bin/geex" ] || fail "geex self prune removed the current version"
ok "geex self prune removed the old version and kept the current one"

if [ -z "${GEEX_DOWNLOAD_URL:-}" ]; then
  geex self update --version "$version" >"$box/out" 2>&1 || fail "geex self update: $(cat "$box/out")"
  grep -q "geex $version is already installed" "$box/out" || fail "self update: $(cat "$box/out")"
  ok "geex self update fetched the release's install.sh"
fi

geex self uninstall || fail "geex self uninstall"
[ ! -e "$geex" ] || fail "geex self uninstall left $geex"
[ ! -e "$versions" ] || fail "geex self uninstall left $versions"
ok "uninstalled"
echo "smoke: geex $version passed"
