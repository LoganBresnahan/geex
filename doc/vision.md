# geex — Vision

> The north-star document: what geex is, what it is **not**, and the one property
> everything else hangs off. Read this first; [README.md](README.md) maps the rest.

geex is an **LLM-native text editor built on the BEAM** — designed from the core so
that **humans and LLMs co-work on the same buffers**, through the same path, with
undo, replay, collaboration, and provenance falling out almost for free.

## 1. The thesis

Every other editor bolts AI on as a *plugin* or *extension*: a parallel path that
reaches into the editor alongside the human's. geex inverts that. Its one
load-bearing property:

> **One path.** Every *edit* — a mutating human keystroke, an LLM tool-call, an
> extension, a remote collaborator — becomes the same `%Command{}` value and runs
> through the same dispatcher into the same undo history.

From that single property we get, almost for free:

- **Undo / redo** — every change is a recorded, reversible command.
- **Replay** — a command sequence re-runs deterministically (the backbone of testing AI edits).
- **Collaboration** — a command from a remote node is just another command.
- **Provenance** — every command is tagged with *who* (human / llm / agent) authored it.

*Navigation is not an edit.* Cursor, selection, and scroll are view-local and
ephemeral — an LLM never navigates, it edits by coordinate, so the shared path is
precisely the *edit* vocabulary. A cursor-relative edit resolves the cursor into
absolute coordinates baked into the command at dispatch ([adr/0014](adr/0014-editor-state-and-dispatch-ownership.md));
the clipboard is a sibling subsystem with its own ring history, not part of the
recorded state ([adr/0015](adr/0015-clipboard-subsystem.md)).

The BEAM is why this is cheap: process-per-everything, OTP supervision, isolation,
distribution, and hot reload mean crash-recovery, security, and "edit my buffer from
your laptop" are *substrate properties*, not features to build. (Full rationale:
[notes.md](notes.md).)

## 2. Why one path matters (and why it can't be a plugin)

The shared path is the *only* thing geex does that a plugin in another editor cannot.
A plugin is, by definition, a second way into the buffer — exactly the Cursor /
Zed-AI shape, where the AI writes through a path parallel to the human's, so undo,
history, and attribution fork. The moment there are two paths, the "one history"
property is gone.

So the shared path must live in the editor's **core**. That is geex's reason to exist.

## 3. What geex is NOT — the world, not the brain

> **geex owns the *world*. The *brain* is bring-your-own.**

| geex owns — the world | geex does NOT own — the brain |
|---|---|
| buffers, the shared command path, undo / replay / collab | agent orchestration (planning, ReAct, tool-selection) |
| provenance, the audit / undo history | context-window management |
| the extension & capability substrate ([mcp-ai-integration.md](mcp-ai-integration.md) §14) | cost budgeting / token accounting |
| being legible, controllable, reversible | multi-step reasoning, scheduling, signal buses |

An agent — claude-code over MCP, a future in-pane agent, a human at the keyboard — is
just **a typist**. geex doesn't care how it decided what to type; it guarantees that
whatever gets typed is recorded, attributed, and reversible. Orchestration floats
*above* geex; geex is the well-structured, observable, undoable surface *below* it.

This keeps geex out of a crowded, fast-churning space (agent frameworks) and focused
on the one thing only it can provide.

> **The test for any "should geex do X?" question:** is X about the editor's *world*
> or the agent's *brain*? World → geex owns it. Brain → geex exposes a clean surface
> and stays out of the way.

## 4. What "LLM-native" actually means

Not "geex has an AI mode." Rather:

> geex is the first editor whose **core write path** is built so that an external
> intelligence and a human share **one undoable, attributed history**.

Provenance and undo aren't features layered onto an AI feature — they are
load-bearing primitives of the editor itself. The MCP server isn't "geex's AI"; it
is geex making itself **legible and controllable** to *any* intelligence, with every
action recorded and reversible.

## 5. Trust & enforcement — the honest boundary

geex provides **the door and the ledger**. It cannot stop an agent that has *another
way in* (e.g. claude-code editing a file on disk directly, bypassing the buffer). The
shared-path guarantee covers edits that *enter through geex* — it is not a property
geex can impose on the outside world.

Enforcement is therefore a property of the agent's **capability grant**, not
something geex does *to* a client. (A database with an audit log can't stop someone
who has direct file access — you remove the direct access; you don't containerize
every client.) Two legitimate regimes:

- **Cooperative** (external agent, e.g. claude-code): the harness *chooses* the door
  — typically by scoping the agent's tools (give it geex's MCP tools, withhold raw
  file write). geex's duties are **honest provenance** (attribute what came through
  the door; mark out-of-band changes `external`; never fabricate authorship) and
  **reconcile** (watch the file on disk and surface divergence — an escape is
  *detected*, never silent).
- **Enforced** (in-VM agent / wasmex extension): the agent lives *inside* geex; the
  dispatcher chokepoint + PID-as-capability + the wasmex sandbox make the path
  structural — there is no other door. This is where containment (WASM) earns its
  keep: around *code running in geex's VM*, not around an external CLI.

> **Enforcement = removing the other ways in** — a decision made *where the agent
> lives*: scope an external agent's tools, or host the agent inside geex.

**Update (2026-10-14, [adr/0032](adr/0032-listener-first-agent-integration.md)):** for external
agents geex no longer pursues the door. Agents edit with their native tools; reconcile records
every write into the one history; a captAInHook hook payload, already in the agent's loop,
attests who made it by content hash. The ledger stays complete, and attribution comes from the
layer that is in the loop rather than from steering the agent.

(Mechanics: [mcp-ai-integration.md](mcp-ai-integration.md) §9 Security, §14 Extension
& capability model. Decisions: [adr/0007](adr/0007-world-not-brain.md),
[adr/0012](adr/0012-trust-and-enforcement.md).)

## 6. How the documents relate

| Document | Role |
|---|---|
| **this doc** | the north star: identity, the one path, the boundary |
| **[notes.md](notes.md)** | design-space exploration: why BEAM, extension substrates, frontend, the command system, the AI loop |
| **[mcp-ai-integration.md](mcp-ai-integration.md)** | detailed design of the AI layer (the two directions, transport, the MCP server, security, sequencing) |
| **[adr/](adr/)** | the decision ledger — each load-bearing decision, why, and its consequences |
| **[roadmap.md](roadmap.md)** | the staged plan, v0.1 → v0.5 → beyond |
| **[research/](research/)** | the background research the decisions rest on |
