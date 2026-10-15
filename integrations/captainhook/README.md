# captAInHook integration: who wrote that?

`geex-attest.sh` is a captAInHook exec payload. After an agent's
`Write`, `Edit` or `NotebookEdit`, it tells every running geex which agent made the write
(harness, session, turn, tool call). geex has already recorded the change from its file
watcher as `:external`. If the message's before and after hashes match that change, geex
relabels it with the agent's identity. Otherwise nothing happens. Design: ADR-0032
(`doc/adr/0032-listener-first-agent-integration.md`), the step (d) amendment.

## Register it

Add this entry to the `handlers` list in `~/.captainHook/handlers.json`, using the absolute
path of your checkout. The daemon hot-reloads the file.

```json
{
  "name": "geex-attest",
  "command": "/home/you/geex/integrations/captainhook/geex-attest.sh",
  "events": ["post-tool-use"],
  "mode": "oneshot",
  "failMode": "open",
  "budgetMs": 1500,
  "passEnv": ["XDG_RUNTIME_DIR"]
}
```

- `passEnv` matters on Linux: captAInHook strips a handler's environment to an allowlist, and
  geex publishes its address under `$XDG_RUNTIME_DIR/geex/`.
- `failMode: "open"`: the script always exits 0 with no answer, so a bug in it costs an
  attribution, never a tool call.
- It needs `jq`, `curl`, and `sha256sum` (or `shasum` on macOS).

## Cost

Every tool call runs it. Measured against a live geex: ~3 ms for a call that isn't a write,
~15 ms for a small Edit, ~250 ms for a 2.7 MB file. With no geex running it sends nothing.

## Check it

`mix test test/geex/attest_payload_test.exs` runs the script against real Claude Code
envelopes (`test/fixtures/claude-code/`). Live: open a file in geex, have an agent edit it,
and the geex log (`<tmp>/geex.log`) shows `attested: claude-code session …`.
