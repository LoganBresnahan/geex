# geex — Documentation

geex is an **LLM-native text editor built on the BEAM**: one shared command path for
humans and LLMs, so undo, replay, collaboration, and provenance come almost for free.

If you read one thing, read **[vision.md](vision.md)**.

## Map

| Document | What it's for | Read when |
|---|---|---|
| **[vision.md](vision.md)** | The north star — what geex is & is not, the one shared path, the world-vs-brain boundary | First. Always. |
| **[roadmap.md](roadmap.md)** | Staged plan, v0.1 → v0.5 → beyond (editor core + AI layer) | You want to know what's next / what ships when |
| **[mcp-ai-integration.md](mcp-ai-integration.md)** | The detailed AI-layer design: the two directions, transport layers, the MCP server, security, the extension/capability model, testing & dogfooding | You're building or changing the AI layer |
| **[adr/](adr/)** | The decision ledger — every load-bearing decision, why, and its consequences | You're asking "why is it this way?" |
| **[notes.md](notes.md)** | The original design-space exploration: why BEAM, extension substrates, frontend options, the command system, the AI loop, TTY fundamentals | You want the background reasoning / the road not taken |
| **[research/](research/)** | Recovered background research (pharos-mcp study; AI-integration survey of Jido / balance_beam / instructor_ex / distributed Erlang) | You want the raw inputs behind a decision |

## The one idea

Everything hangs off a single bet: **the command is the universal unit.** Human
keystrokes, LLM tool-calls, extensions, and remote collaborators all become the same
`%Command{}` value, run through one dispatcher into one undo history, each tagged with
provenance. The TUI, the MCP server, the AI features, collaboration, and the test
harness are all *consumers and projections* of that one object.

- **geex owns the *world*** (buffers, the shared path, undo/replay/collab/provenance).
- **The *brain* is bring-your-own** (agent orchestration, planning, context, cost).

See [adr/0002](adr/0002-commands-as-values.md), [adr/0003](adr/0003-one-shared-path.md),
[adr/0007](adr/0007-world-not-brain.md).

## Status

Design-locked; implementation of the command system (v0.1) is the next work. Virtual
screen + renderer are built and tested. See [roadmap.md](roadmap.md) for the current
stage and [mcp-ai-integration.md](mcp-ai-integration.md) §12 for AI-layer sequencing.

## Conventions

- **Decisions** live in `adr/` (numbered, dated, short). A decision that changes one
  supersedes it (link both ways), rather than editing history silently.
- **`§N`** references in the docs point to sections of `mcp-ai-integration.md` unless
  another file is named.
- Design docs cross-link by relative path so they're navigable from any entry point.
