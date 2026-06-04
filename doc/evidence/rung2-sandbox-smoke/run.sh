#!/bin/bash
# Rung-2 OS-sandbox topology smoke test (evidence for ADR-0016).
#
# Model: an OS sandbox that denies the *harness* writes to the repo (repo
# read-only, only scratch + /tmp writable, network shared). Questions:
#   A.  does the sandbox deny a direct repo write?
#   B.  does it deny a write by a child the harness SHELLS OUT to? (the gap
#       harness tool-deny rules cannot close)
#   C1. is an MCP server SPAWNED AS A CHILD inside the sandbox trapped too?
#       (the naive stdio-MCP topology — harness spawns geex)
#   C2. can a server OUTSIDE the sandbox, reached over a unix socket, write on
#       the harness's behalf? (the corrected topology — geex outside, harness
#       connects in)
#
# Requires: bwrap (bubblewrap), python3, a kernel with unprivileged userns.
# Self-contained: uses a fresh mktemp scratch; no fixed paths.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Scratch must live OUTSIDE /tmp: the bwrap profile shadows /tmp with a tmpfs,
# which would hide the repo/socket if they lived there.
SMOKE="$(mktemp -d "${HOME:-/var/tmp}/geex-smoke.XXXXXX")"; trap 'rm -rf "$SMOKE"' EXIT
mkdir -p "$SMOKE/repo" "$SMOKE/scratch" "$SMOKE/run"
PY="$(command -v python3)"
CHAN="$HERE/channel.py"

# bwrap profile = "harness sandboxed": everything read-only, writable scratch+/tmp,
# network shared (default). The repo (under $SMOKE/repo) is therefore read-only.
sb() {
  bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
        --bind "$SMOKE/scratch" "$SMOKE/scratch" -- "$@"
}
reset() { echo "ORIGINAL" > "$SMOKE/repo/target.txt"; }
state() { cat "$SMOKE/repo/target.txt"; }
unchanged() { [ "$(state)" = "ORIGINAL" ] && echo "PASS (denied, repo unchanged)" || echo "FAIL (repo was written!)"; }
changed()   { [ "$(state)" != "ORIGINAL" ] && echo "PASS (write landed: '$(state)')" || echo "FAIL (write did not land)"; }

echo "# A. Harness writes repo directly (inside sandbox) — expect DENIED"
reset; sb /bin/sh -c "echo A_DIRECT > $SMOKE/repo/target.txt" 2>&1 | sed 's/^/   /'
echo -n "   -> "; unchanged

echo "# B. Harness SHELLS OUT to a child that writes repo — expect DENIED"
reset; sb /bin/sh -c "/bin/sh -c 'echo B_SUBPROC > $SMOKE/repo/target.txt'" 2>&1 | sed 's/^/   /'
echo -n "   -> "; unchanged

echo "# C1. 'MCP server' SPAWNED AS A CHILD inside the sandbox — expect TRAPPED/DENIED"
reset; sb /bin/sh -c "$PY -c \"open('$SMOKE/repo/target.txt','w').write('C1_INSIDE_SERVER')\"" 2>&1 | sed 's/^/   /'
echo -n "   -> "; unchanged

echo "# C2a. 'geex' server OUTSIDE sandbox, FILESYSTEM unix socket — expect WRITE LANDS"
reset
"$PY" "$CHAN" server-fs "$SMOKE/run/geex.sock" "$SMOKE/repo/target.txt" > "$SMOKE/run/fs.log" 2>&1 & SRV=$!
sb "$PY" "$CHAN" client-fs "$SMOKE/run/geex.sock" "C2a_VIA_FS_SOCKET" 2>&1 | sed 's/^/   /'
wait $SRV 2>/dev/null
echo -n "   -> "; changed

echo "# C2b. 'geex' server OUTSIDE sandbox, ABSTRACT unix socket — expect WRITE LANDS"
reset
"$PY" "$CHAN" server-abstract "geexsock" "$SMOKE/repo/target.txt" > "$SMOKE/run/ab.log" 2>&1 & SRV=$!
sb "$PY" "$CHAN" client-abstract "geexsock" "C2b_VIA_ABSTRACT_SOCKET" 2>&1 | sed 's/^/   /'
wait $SRV 2>/dev/null
echo -n "   -> "; changed

echo "# Control: same direct write WITHOUT the sandbox — expect WRITE LANDS"
reset; /bin/sh -c "echo CONTROL > $SMOKE/repo/target.txt"
echo -n "   -> "; changed