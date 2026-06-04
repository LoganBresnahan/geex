# Rung-2 OS-sandbox topology — smoke test

Empirical evidence for the **OS-sandbox enforced rung** in
[adr/0016](../../adr/0016-external-harness-integration.md). It validates *how* an
OS sandbox lets geex enforce "the harness's only write path is the command path,"
and — importantly — pins down the **process-parentage requirement** that a naive
reading gets backwards.

## What it tests

A bubblewrap profile models a sandboxed harness: the repo is read-only, only a
scratch dir + `/tmp` are writable, the network is shared. Then:

| # | Scenario | Expectation |
|---|---|---|
| A | Harness writes the repo directly (inside sandbox) | denied |
| B | Harness **shells out** to a child that writes the repo | denied — *the gap harness tool-deny rules cannot close* |
| C1 | "geex" **spawned as a child inside** the sandbox tries to write (naive stdio-MCP: harness spawns geex) | **trapped** — denied |
| C2a | geex **outside** the sandbox, reached over a **filesystem** unix socket | write lands |
| C2b | geex **outside** the sandbox, reached over an **abstract** unix socket | write lands |
| — | Control: same write **without** the sandbox | lands (proves A/B/C1 fail *because of* the sandbox) |

## Result (2026-06-04, Linux 6.6 / WSL2, bubblewrap)

All six behaved as expected:

```
A.  direct write inside sandbox    -> PASS (denied: Read-only file system)
B.  subprocess write inside sandbox-> PASS (denied: Read-only file system)
C1. server spawned INSIDE sandbox  -> PASS (trapped, denied: Read-only file system)
C2a server OUTSIDE via fs socket   -> PASS (write landed: 'C2a_VIA_FS_SOCKET')
C2b server OUTSIDE via abstract sock-> PASS (write landed: 'C2b_VIA_ABSTRACT_SOCKET')
control (no sandbox)               -> PASS (write landed: 'CONTROL')
```

## What it proves

1. **The sandbox closes the subprocess-write gap (B).** A shelled-out script's
   write is denied by the kernel — something no harness tool-deny rule can do.
2. **The naive topology is a trap (C1).** If geex is the **stdio child the harness
   spawns**, it inherits the sandbox and its write is denied too. So you cannot
   "sandbox the harness, point it at a stdio geex, done."
3. **The fix works (C2).** With geex running **outside** the sandbox as a server
   the harness **connects to** (unix socket — filesystem or abstract), the write
   lands *while the harness's own direct/subprocess writes stay denied*. The geex
   channel is the **sole egress** = structural enforcement. This is why the
   enforced rung requires the *connect* transport (adr/0018), not stdio-spawn.

## Scope / caveats

- **Linux / bubblewrap only.** macOS Seatbelt is untested (same FD/socket
  principle, different syscalls).
- **General kernel mechanics, not a specific harness.** Does not test whether
  Codex/Claude Code leave their *own* spawned MCP child unsandboxed (harness-
  specific, still needs a version-pinned check).
- The **outer-wrapper** variant (geex spawns the sandboxed harness with an
  inherited pipe FD) is untested here; inherited FDs aren't revoked by these
  sandboxes, so it should hold, but the socket-server variant is what's verified.

## Run it

```
bash doc/evidence/rung2-sandbox-smoke/run.sh
```

Requires `bwrap` (bubblewrap), `python3`, and a kernel with unprivileged user
namespaces. Self-contained (fresh scratch under `$HOME`, cleaned on exit).
