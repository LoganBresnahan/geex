# Research

Background research that fed [`../mcp-ai-integration.md`](../mcp-ai-integration.md).
Recovered from the 2026-05-28 design session (two multi-agent research workflows
that completed and were saved before the session itself died on an API error).

Each study is kept in two forms:

- **`*.md`** — human-readable rendering (synthesis + per-finding sections). Read these.
- **`*.json`** — the raw structured findings payload, for fidelity / re-processing.

| Study | Source task | What it covers |
|---|---|---|
| [`pharos-mcp-study.md`](pharos-mcp-study.md) | `wsikhm1th` | Deep read of [`pharos-mcp`](https://github.com/LoganBresnahan/pharos-mcp) (Gleam/BEAM MCP server) — protocol core, transport, tool dispatch, supervision, gotchas. Backs §4 / §10 / §11 of the design doc. |
| [`ai-integration-survey.md`](ai-integration-survey.md) | `wfnlyfnum` | Survey of daemon/HTTPS, distributed-Erlang RPC, [Jido](https://github.com/agentjido/jido), [`balance_beam`](../../../balance_beam), and [`instructor_ex`](https://github.com/thmsmlr/instructor_ex). Backs §3 / §5 / §6 / §8 of the design doc. |
| [`diff-edit-tool.md`](diff-edit-tool.md) | 2026-06-04 | DeepSeek-Moby's diff/apply engine + the Elixir/Hex diff ecosystem → the decided approach for geex's `edit` (search-replace) tool. Backs [`../adr/0020`](../adr/0020-diff-edit-tool.md). |

The design doc is the distilled, decision-bearing output; these files are the raw
inputs behind it. If a doc decision is ever questioned, the supporting evidence is here.
