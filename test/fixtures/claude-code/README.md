# Claude Code tool-use envelopes (copied from captAInHook)

Verbatim copies of `~/captAInHook/examples/fixtures/claude-code/*.jsonl` at captAInHook
commit `3ddb467` ("Real Claude Code tool-use envelopes, pinned against the encoder"). Each
file is one tool call, captured live on **Claude Code 2.1.299** through captAInHook's exec
wire: its `PreToolUse` envelope, then its `PostToolUse` envelope, one JSON line each.
captAInHook's own README there documents every field.

`test/geex/attest_payload_test.exs` runs `integrations/captainhook/geex-attest.sh` against
them (ADR-0032 step d). The test swaps only the captured file path for a temp file; every
other byte is the host's.

These are the host's bytes, and the host changes them between versions. When the payload
breaks on a new Claude Code, re-copy from captAInHook (or capture again) rather than
editing these.
