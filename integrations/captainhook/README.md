# captAInHook integration: who wrote that?

`geex-attest.sh` is a captAInHook exec payload. After an agent's
`Write`, `Edit` or `NotebookEdit`, it tells every running geex which agent made the write
(harness, session, turn, tool call). geex has already recorded the change from its file
watcher as `:external`. If the message's before and after hashes match that change, geex
relabels it with the agent's identity. Otherwise nothing happens. Design: ADR-0032
(`doc/adr/0032-listener-first-agent-integration.md`), the step (d) amendment.

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
  "events": ["post-tool-use"],
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
- It needs `jq`, `curl`, and `sha256sum` (or `shasum` on macOS).

## When geex isn't running

If no geex has the file open, and geex keeps a history log for the file, the script saves the
attestation (hashes and ids, no file content) next to that log in
`~/.local/state/geex/ledger/`. When geex next opens the file and finds it changed, it credits
the change to the agent if the saved edits explain it exactly, from one session. If you set
`XDG_STATE_HOME`, add it to `passEnv` too.

## Cost

Every tool call runs it. Measured against a live geex: ~3 ms for a call that isn't a write,
~15 ms for a small Edit, ~250 ms for a 2.7 MB file. With no geex running it sends nothing.

## Check it

`mix test test/geex/attest_payload_test.exs` runs the script against real Claude Code
envelopes (`test/fixtures/claude-code/`). Live: open a file in geex, have an agent edit it,
and the geex log (`~/.local/state/geex/geex.log`) shows `attested: claude-code session …`.
