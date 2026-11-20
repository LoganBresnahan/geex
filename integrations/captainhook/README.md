# captAInHook integration: who wrote that?

`geex-attest.sh` is a captAInHook exec payload. After an agent's
`Write`, `Edit` or `NotebookEdit`, it tells every running geex which agent made the write
(harness, session, turn, tool call). After an agent's `Bash` call, it tells geex which files
changed **while** the call ran (below). geex has already recorded the change from its file
watcher as `:external`. If the message's before and after hashes match that change, geex
relabels it with the agent's identity. Otherwise nothing happens. Design: ADR-0032
(`doc/adr/0032-listener-first-agent-integration.md`), the step (d) amendment and the
2026-11-18 amendment.

## Where it is

From 0.3.5, every geex release carries this script, and `install.sh` keeps a link to the current
version's copy at one path that doesn't change with the version:

    ~/.local/share/geex/integrations/geex-attest.sh

(`$GEEX_INSTALL_DIR/integrations/geex-attest.sh` if you set that; the install prints the path.)
An update or a rollback moves the link to the new version's copy, and `geex self uninstall`
removes it. Nothing edits your handlers.json: registering is yours.

## Register it

Add this entry to the `handlers` list in `~/.captainHook/handlers.json`. The daemon hot-reloads
the file.

```json
{
  "name": "geex-attest",
  "command": "~/.local/share/geex/integrations/geex-attest.sh",
  "events": ["pre-tool-use", "post-tool-use"],
  "mode": "oneshot",
  "failMode": "open",
  "budgetMs": 1500,
  "passEnv": ["XDG_RUNTIME_DIR"]
}
```

- captAInHook expands a leading `~/` from 0.1.3. With an older captAInHook, write the absolute
  path (`/home/you/.local/share/geex/integrations/geex-attest.sh`).
- Working on geex itself, you can name the checkout's
  `integrations/captainhook/geex-attest.sh` instead; then every edit to it is live in the hook.
- `passEnv` matters on Linux: captAInHook strips a handler's environment to an allowlist, and
  geex publishes its address under `$XDG_RUNTIME_DIR/geex/`.
- `failMode: "open"`: the script always exits 0 with no answer, so a bug in it costs an
  attribution, never a tool call.
- It needs `jq`, `curl`, and `sha256sum` (or `shasum` on macOS); `git` for Bash calls.
- `pre-tool-use` is for Bash calls only. With `post-tool-use` alone, writers are credited as
  before and Bash changes stay `:external`. A payload older than this one ignores PreToolUse.

## Bash calls: "changed while"

A Bash response carries no file and no text from before, so the payload brackets the call. On
PreToolUse it snapshots each git work tree the call may touch (the one holding the session's
directory, and the ones holding each `cd DIR`, `git -C DIR` and absolute path in the command):
the sha256 of every file `git status` names. On PostToolUse it compares, and sends each changed
file with `"during": "Bash"` and the program's name (`sed`, `python3`; never the command line,
which can carry a token). A match proves the file changed while the call ran, not that the
command did it, so geex says "while", never "by": `✎ claude-code/1a2b3c4d · while python3` on
the status line, `(while Bash)` in the edits pane, a lighter `╎` in the gutter.

It never runs anything a repository configures: every git call it makes turns off
`core.fsmonitor`, empties the filter drivers and skips optional index writes, because it runs
before the permission prompt, in repositories a command merely names. A file a filter driver
handles (Git LFS) is therefore not credited, and a partial clone (which fetches missing objects
by running its remote's program) isn't looked at all. It needs git 2.31 or newer; with an older
git it credits no Bash changes and says so on stderr.

A file clean before the call takes its before from the commit the call started at. A new file is
credited only when the command names its path and it didn't exist before (even an ignored one).

Not credited (the change stays `:external`): a background call (`run_in_background`), files
outside a git work tree, a new file the command doesn't name (it can't be proved new: an
ignored or generated file, one inside an untracked directory git lists as one entry), an edit
the call also committed, symlinks, a work tree that is your home directory, a work tree with
more than 500 changed files, a call that changes more than 150 files (it says so on stderr).
Snapshots live in `$XDG_RUNTIME_DIR/geex/bash/` (`0600`; `<tmp>/geex-$USER/bash/` without
`XDG_RUNTIME_DIR`), carry the session and the time, and are refused by another session or after
an hour; one a denied call left is removed after an hour.

## When geex isn't running

If no geex has the file open, and geex keeps a history log for the file, the script saves the
attestation (hashes and ids, no file content) next to that log in
`~/.local/state/geex/ledger/`. When geex next opens the file and finds it changed, it credits
the change to the agent if the saved edits explain it exactly, from one session. If you set
`XDG_STATE_HOME`, add it to `passEnv` too.

## Cost

Every tool call runs it. Measured against a live geex: ~3 ms for a call that isn't a write,
~15 ms for a small Edit, ~250 ms for a 2.7 MB file. With no geex running it sends nothing.
PreToolUse runs before every tool call and holds it until it ends: ~1.3 ms for anything but
Bash; for Bash, the snapshot, ~16 ms in a 400-file repository, ~60 ms in a 60,000-file one, and
~1.4 ms more for each changed file (measured 2026-11-19, Linux under WSL2). Cut short by
`budgetMs`, it writes no snapshot: a missed credit, never a slow or blocked call. PostToolUse
for Bash: ~230 ms for 50 changed files and ~600-860 ms for 150 with a live geex; past 150 it
sends nothing. One geex that accepts connections and never answers costs one 1 s timeout per
call; with about 100 or more changed files as well, that can overrun `budgetMs`, and most of that
call's credits are lost (a known limit: a miss, never a wrong claim).

## Check it

`mix test test/geex/attest_payload_test.exs` runs the script against real Claude Code
envelopes (`test/fixtures/claude-code/`). Live: open a file in geex, have an agent edit it,
and the geex log (`~/.local/state/geex/geex.log`) shows `attested: claude-code session …`.
