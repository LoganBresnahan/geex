# ADR-0003: One dispatcher = the single shared path

- **Status:** Accepted
- **Date:** 2026-05-27

## Context

Editor-AI tools (Cursor, Zed AI, Continue) bolt the AI onto the editor through a path
*parallel* to the human's. That forks undo, history, and attribution — the AI's edits
and the human's live in different worlds.

## Decision

**Every edit** — a mutating human keystroke, an LLM tool-call (MCP), an in-pane agent,
an extension, a remote collaborator — becomes a `%Command{}`
([ADR-0002](0002-commands-as-values.md)) and runs through **one** dispatcher
(`Geex.Dispatch.run/1`) into **one** undo history. Nothing writes a buffer directly.
*Navigation* (cursor / selection / scroll) is view-local and is **not** a command; a
cursor-relative edit bakes the resolved coordinates into the command at dispatch, and
the dispatchable state is the buffer's `EditorState`
([ADR-0014](0014-editor-state-and-dispatch-ownership.md)).

## Consequences

- Undo / replay / collab / provenance are uniform *regardless of origin*. An LLM is just
  another typist.
- The editor is legible and controllable to an LLM **by construction** — this is what
  "LLM-native" means ([vision.md](../vision.md) §4).
- This is geex's reason to exist, and it **cannot be a plugin** — a plugin is by
  definition a second path ([vision.md](../vision.md) §2).
- **Cost:** every actor must route through the dispatcher. That single chokepoint is also
  where capability and trust are enforced ([ADR-0009](0009-three-tier-extension-model.md),
  [ADR-0012](0012-trust-and-enforcement.md)).

## See

[vision.md](../vision.md) §2, [mcp-ai-integration.md](../mcp-ai-integration.md) §2, §14;
the state model in [ADR-0014](0014-editor-state-and-dispatch-ownership.md), the clipboard
in [ADR-0015](0015-clipboard-subsystem.md).
