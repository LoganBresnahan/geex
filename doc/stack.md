# The stack: geex, pharos, captAInHook

Three tools, built to work together. Agentic workflows are the primary reason each exists: an
agent edits code, a human watches and steers, and the record says who did what. The human
working alone in the editor is the second case, and it has to work just as well without an
LLM in the middle.

**pharos's diagnostics hook is on trial.** geex and captAInHook are core. The trial decides
whether agents get pharos's post-edit diagnostics hook or a plain compiler hook (see
[The pharos trial](#the-pharos-trial)). Whether pharos itself stays is the maintainer's call,
weighing what it does for agents beyond the hook (its navigation tools) and what it would do
for geex. Nothing else in the stack depends on it: every rule below holds with pharos gone,
and geex runs without it (rule 8).

This doc is the shared reference for how they connect. Each repo keeps its own decisions in
its own ADRs; a change to a contract *between* the tools is agreed here first, then lands in
the repos. The other two repos link here.

- **geex**: <https://github.com/LoganBresnahan/geex>, this repo
- **pharos**: <https://github.com/LoganBresnahan/pharos-mcp>
- **captAInHook**: <https://github.com/LoganBresnahan/captAInHook>

## What each one is

| Tool | It is | It owns | It does not |
|---|---|---|---|
| **geex** | the world | buffers, the one undo history, provenance, what the human sees | run language servers, run agents, plan |
| **pharos** | language knowledge | language servers and their lifecycle (one shared daemon per version, a pool of warm servers), answers about code | own files' truth, decide who wrote what |
| **captAInHook** | the harness's event tap | the seams of an agent's turn (SessionStart … PostToolUse … Stop), fanning each event out to payloads under a budget | edit files, keep the record |
| **the disk** | where content meets | the bytes every writer leaves | |

## The rules

1. **Content meets on disk.** No tool pushes file text to another. An agent writes with its
   own writers; geex saves; pharos reads what is saved; geex's reconcile notices the rest
   (geex ADR-0010, ADR-0032, ADR-0034). So each tool must notice a write on disk: pharos
   re-syncs every document it holds open with the disk on each question (pharos ADR-038,
   [pharos#3](https://github.com/LoganBresnahan/pharos-mcp/issues/3)), and must still tell a
   server that doesn't watch the disk about changes to files it never opened
   ([pharos#10](https://github.com/LoganBresnahan/pharos-mcp/issues/10)).
2. **Messages carry questions, answers and claims.** "Where is this defined" and its answer;
   "these diagnostics changed"; "agent X wrote this file, from hash A to hash B" (an
   attestation). Never file content as a side channel.
3. **Every write can be credited.** A tool that writes files reports, per file, the path and
   the sha256 before and after, so the harness side can attest it to geex. geex credits a
   change only when both hashes match; anything else stays `:external`. A shell call that
   changes files is bracketed instead: the payload hashes the work trees before and after the
   call and attests each changed file as `during` that call, a weaker claim that it changed
   while the call ran (geex ADR-0032, amendment of 2026-11-18). No tool infers authorship from
   timing (geex invariant 6): a bracketed credit says "while", never "by", and nothing is
   credited outside a call's own window.
4. **Edits are data.** A tool that computes a change returns it as edits and lets the client
   apply them. pharos's `edit_at_symbol`, `rename_preview` and `format_document` already
   work this way, and `apply_workspace_edit` is its only writer. geex applies edits itself, as
   the human's `%Command{}`s through its one shared path; an agent applies them with its own
   writers or `apply_workspace_edit`.
5. **No LLM in the human's path.** When the human asks geex something, geex asks pharos
   directly. MCP is the transport, not an invitation to put a model in the loop.
6. **Push uses MCP's own mechanisms.** A client that wants to be told subscribes to a
   resource and gets `notifications/resources/updated`
   ([pharos#5](https://github.com/LoganBresnahan/pharos-mcp/issues/5)). No side protocol,
   no LSP passthrough.
7. **One pool of language servers.** pharos runs one daemon per version (pharos ADR-034).
   An agent's session and geex's session join the same daemon and share the same warm
   servers: one index, one cold start.
8. **Fail open across the seams.** A missing or slow peer costs a feature, never an edit or a
   tool call. geex runs without pharos; a hook payload that fails says nothing; an
   attestation that doesn't match changes nothing.
9. **Local and loopback only.** Everything is one user on one machine: stdio, unix sockets,
   `127.0.0.1` with a token. Nothing listens beyond loopback.

## How they connect

```
 Claude Code ──stdio──► pharos shim ─┐
                                      ├─unix socket─► pharos daemon ─► rust-analyzer, gopls, pyright…
 geex ────────stdio──► pharos shim ─┘       (one per version; servers shared)
   ▲
   └── POST /attest (loopback) ◄── geex-attest payload ◄── captAInHook ◄── Claude Code hooks
                                   pharos-diagnostics payload ──► pharos (post-edit check)
```

| From | To | Over | Carries | Status |
|---|---|---|---|---|
| agent (Claude Code) | pharos | MCP, stdio → shared daemon | code questions; previews; `apply_workspace_edit` | built |
| geex | pharos | MCP, stdio → shared daemon | definition, references, hover | parked until pharos's place is decided: [geex#2](https://github.com/LoganBresnahan/geex/issues/2) |
| geex | pharos | the `pharos diagnostics --json` CLI → shared daemon | diagnostics after a save, as one of the user's own checks (geex ADR-0055 §9); runs only if the user's config names it | accepted, not built (geex ADR-0055) |
| pharos | geex | MCP notifications (resource subscriptions) | "diagnostics for this file changed" | [pharos#5](https://github.com/LoganBresnahan/pharos-mcp/issues/5) |
| captAInHook | geex | the `geex-attest.sh` payload → loopback `POST /attest` | who wrote a file, by hash | built for Write/Edit/MultiEdit/NotebookEdit; Bash changes credited "while": built and live ([geex#3](https://github.com/LoganBresnahan/geex/issues/3), geex ADR-0032; its `pre-tool-use` event registered 2026-11-19); pharos writes: [geex#1](https://github.com/LoganBresnahan/geex/issues/1) |
| captAInHook | pharos | a payload → `pharos diagnostics` CLI | the touched files' diagnostics, back to the agent | built for the trial (pharos ADR-040, [pharos#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6)); in use only if the trial picks it |
| agent | geex | geex's MCP server | the frozen edit/view tools | built, frozen (ADR-0032); rarely the right door |
| everyone | everyone | the disk | content | built (pharos re-syncs open documents, ADR-038); servers that don't watch the disk: [pharos#10](https://github.com/LoganBresnahan/pharos-mcp/issues/10) |

Which repo ships a payload: the tool that *consumes* the event. geex ships `geex-attest.sh`
(it consumes attestations); pharos ships its diagnostics payload
([pharos#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6), pharos ADR-040).
captAInHook ships the engine and the seams, not the payloads. Apps stay generic, and the
payload between two apps does the translating: captAInHook knows the harness's protocol, not
what any tool means, so a payload that cares about a tool matches it by name (captAInHook
ADR-0019 and its 2026-11-18 addendum,
[captAInHook#1](https://github.com/LoganBresnahan/captAInHook/issues/1)).

## The two paths

### The agent path

1. The agent asks pharos about the code (or greps; both are fine).
2. It writes with its harness's writers, or applies a pharos edit with `apply_workspace_edit`.
3. The write lands on disk. geex's reconcile records it as `:external` and shows it.
4. captAInHook's PostToolUse fires. The `geex-attest` payload sends the file's before/after
   hashes; geex relabels the change with the agent's identity when both match. A change made
   through the agent's Bash tool is credited "while" that call instead, from a snapshot the
   payload takes at PreToolUse ([geex#3](https://github.com/LoganBresnahan/geex/issues/3),
   geex ADR-0032). Nothing a repository configures runs in that snapshot.
5. *Built for the trial, used only if it wins:* a pharos payload on the same PostToolUse tells
   the agent about *new* errors in the files it touched, quietly and as information, never
   orders (mid-refactor breakage is expected). A second check at Stop blocks the turn's end
   while touched files still have errors, so the agent can't hand back broken code
   ([pharos#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6)). captAInHook can already
   block at Stop (its ADR-0016). A payload that blocks must stop blocking on its own, since the
   host never caps the loop, and must not register fail-closed.
6. pharos sees the new file on the next question: it re-syncs what it holds open (pharos
   ADR-038). A server that doesn't watch the disk still misses changes to files pharos never
   opened ([pharos#10](https://github.com/LoganBresnahan/pharos-mcp/issues/10)).

### The human path (no LLM)

This is the shape *if pharos stays*. Until then the human has geex's own search
(`search`, `search-project`, `search-all`), which covers most of "where is this used".

- **Where is this defined / who uses it:** geex asks pharos, off the key loop (ADR-0035), and
  lists the answers in the output pane, stepped with Alt+N.
- **Diagnostics after a save:** geex saves; pharos's server sees the new file; geex shows
  gutter marks, a count and a list. First by asking after the save, later by subscription.
  geex ADR-0055 decides the asking: `pharos diagnostics --json` runs as one of the user's own
  checks on save, next to `tsc` or `mix compile`, into one diagnostics overlay.
  Marks dim while the buffer has unsaved changes: answers are about the saved file
  (geex ADR-0010). pharos says when it isn't sure (ADR-038): `pharos.carried_over` marks an
  answer that may describe older text, and `pharos.not_reported` names servers that didn't
  answer. geex shows both as unsure, never as clean. Since
  [pharos#13](https://github.com/LoganBresnahan/pharos-mcp/issues/13) (pharos ADR-039), an
  unmarked TypeScript answer is current.
- **Rename / format:** pharos returns edits; geex applies them as the human's commands, so
  they go into the one undo history with `actor: :human`, not as anonymous file writes.
- **Positions:** pharos speaks LSP positions (UTF-16 code units); geex addresses graphemes.
  geex's pharos adapter converts both ways (geex invariant 5, ADR-0021; for diagnostics, geex
  ADR-0055 §4's edge). Note pharos's
  `apply_workspace_edit` approximates UTF-16 as codepoints (exact in the BMP), another reason
  geex applies edits itself.

## The pharos trial

The question is not "language server or nothing". It is: **does a language server beat
running the project's own checker after edits?** A hook that runs `cargo check`,
`tsc --noEmit` or `mix compile` on the touched project is trivial, needs no pharos, and gives
the same kind of feedback. A capable model (Opus, Fable) with the compiler, the tests and grep
already covers most of what an LSP offers; in a whole geex session (Elixir, fast compile, a
known codebase) pharos was never used and never missed. geex is the wrong place to judge it.

**Where a language server could still win:** slow builds (Rust, Java, Scala: errors in
seconds from a warm server instead of minutes from a build); large codebases with common
names (grep's hundreds of matches against twelve real references); exact renames across many
files.

**The experiment ([pharos#7](https://github.com/LoganBresnahan/pharos-mcp/issues/7)): three arms, same tasks, on a project where pharos should win** (a large
TypeScript or Rust repo; pharos's existing benchmark is the place to build it):

1. no hook;
2. a compiler hook ([captAInHook#4](https://github.com/LoganBresnahan/captAInHook/issues/4)):
   the project's own checker after edits;
3. the pharos hook ([pharos#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6)):
   the language server's diagnostics after edits.

Arms 2 and 3 follow one contract, [stack-trial-hooks.md](stack-trial-hooks.md), so the only
difference is where the errors come from. All three arms share:
- the same model and harness: DeepSeek's `deepseek-v4-pro` driven by Claude Code, decided
  2026-11-18;
- the same tools, without pharos's MCP tools;
- runs isolated from the maintainer's own daemons and settings.

Arms 2 and 3 also share the same events, baselines, wording and budget. The contract defines a
broken turn and what "clearly beats" means. The measures are broken turns, the build and test
runs the agent makes itself, tokens and wall time.

**The language:** TypeScript; the contract is written for it, pinned to TypeScript 6.0.3.
TypeScript's freshness fix has landed
([pharos#13](https://github.com/LoganBresnahan/pharos-mcp/issues/13), pharos ADR-039). The
Rust blockers are fixed on pharos main, not yet released (2026-11-20): rust-analyzer's own
diagnostics now reach pharos
([pharos#8](https://github.com/LoganBresnahan/pharos-mcp/issues/8)), a cold server is ready in
about 2 s instead of a minute ([pharos#12](https://github.com/LoganBresnahan/pharos-mcp/issues/12)),
and a stale `cargo check` result is no longer answered as fresh
([pharos#30](https://github.com/LoganBresnahan/pharos-mcp/issues/30)). A Rust trial would still
need a Rust version of the contract's checkers and line format.

**What the verdict decides:** which hook agents get. If arm 3 clearly beats arm 2 (not merely
arm 1), agents get the pharos hook. If the compiler hook ties or wins, the cheaper tool wins
and agents get the compiler hook. pharos's own place in the stack is the maintainer's call,
decided separately (revised 2026-11-18): the trial tests one feature, and it measures neither
pharos's navigation tools for agents nor what pharos would do for geex.

## The work, in order

| Step | Issue | Repo | What | Needs |
|---|---|---|---|---|
| 1 | [pharos#7](https://github.com/LoganBresnahan/pharos-mcp/issues/7) | pharos | the trial: the three-arm run on `deepseek-v4-pro`, written up with the verdict. The harness is verified and on pharos's `trial/007` branch; the 90 runs wait on the maintainer's go | both hooks (done) |

Done:
- [pharos#3](https://github.com/LoganBresnahan/pharos-mcp/issues/3): documents re-synced from
  disk on every question (pharos ADR-038).
- [pharos#13](https://github.com/LoganBresnahan/pharos-mcp/issues/13): TypeScript diagnostics
  asked of tsserver directly (pharos ADR-039).
- [pharos#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6): arm 3, the `pharos
  diagnostics` CLI and its captAInHook payload (pharos ADR-040).
- [captAInHook#4](https://github.com/LoganBresnahan/captAInHook/issues/4): arm 2, the compiler hook.
- [pharos#8](https://github.com/LoganBresnahan/pharos-mcp/issues/8),
  [#12](https://github.com/LoganBresnahan/pharos-mcp/issues/12),
  [#30](https://github.com/LoganBresnahan/pharos-mcp/issues/30) and the real-server survey's
  fixes: pharos answers for Rust, Go, Python and the other bundled languages, checked against
  real servers in CI (on main, 2026-11-20; not yet released).

**Parked until pharos's place is decided** (built only if pharos stays):

| Issue | Repo | What | Needs |
|---|---|---|---|
| [geex#2](https://github.com/LoganBresnahan/geex/issues/2) | geex | geex as an MCP client of pharos: definition, references, hover (diagnostics come through geex ADR-0055's pharos check) | an ADR or amendments to 0008/0010/0021 |
| [pharos#5](https://github.com/LoganBresnahan/pharos-mcp/issues/5) | pharos | push diagnostics through MCP resource subscriptions | an MCP client in geex (geex#2) that subscribes; until then geex ADR-0055 asks after each save |
| [pharos#4](https://github.com/LoganBresnahan/pharos-mcp/issues/4) | pharos | `apply_workspace_edit` reports each written file's path + before/after sha256 | — |
| [geex#1](https://github.com/LoganBresnahan/geex/issues/1) | geex | `geex-attest.sh` credits pharos's multi-file writes | pharos#4 |
| [pharos#10](https://github.com/LoganBresnahan/pharos-mcp/issues/10) | pharos | servers that don't watch the disk (gopls, pyright) never see changes to files pharos hasn't opened; typescript-language-server watches on its own, so a TypeScript trial doesn't need it; rust-analyzer unverified | — |

pharos#4 and geex#1 are one feature (attributing pharos's writes): build them together or not
at all. captAInHook builds nothing for it (see "Decided against").

## Decided against, or not yet

- **geex speaking LSP to pharos, or pharos forwarding raw LSP.** It would make pharos an LSP
  proxy and geex an LSP client: document sync, server-pushed requests, capability
  negotiation, UTF-16. pharos already owns the servers well; MCP fits request/answer plus
  subscriptions. If geex ever needs completion as you type, that is a direct-LSP adapter
  behind ADR-0021, decided then.
- **Answers about unsaved text.** geex ADR-0010 keeps the disk as the truth. pharos's
  ADR-028 (an editor bridge streaming unsaved buffers) is the road if it is ever needed;
  trigger: a feature that needs it *and* a measured cost of saving first.
- **pharos lifecycle hooks (pharos emitting its own events for captAInHook).** Every event so
  far has a better route: what geex needs comes over its MCP connection; agent writes are
  already seen at PostToolUse. Add one when a payload needs it (the named-consumer rule).
- **A tool kind in captAInHook for multi-file writers**
  ([captAInHook#1](https://github.com/LoganBresnahan/captAInHook/issues/1), decided
  2026-11-18). Neither a new kind nor an engine-built list of touched paths: a list wouldn't
  carry the before-hash an attestation needs, and each tool would need its own extractor.
  `geex-attest.sh` will recognize pharos's writer by name (geex#1), and pharos will report each
  file's hashes (pharos#4). Reopen on captAInHook ADR-0019's revisit triggers.
- **An LLM-backed hub between the tools.** Every request would become a model call: slow,
  costly, nondeterministic, and it breaks geex's replayable history. The services would still
  need a protocol underneath. Where it holds up is an *agent-facing front*: composite tools
  that answer a whole question in one call ("everything about this function") by fanning out
  to pharos, geex and git, with the services keeping plain protocols. Later, if ever.

## Working across the repos

- One chat (or person) per repo owns that repo's code and docs. This doc is everyone's
  contract, so the coordinators own it even though it lives in geex: geex's coordinator
  (geex-mod) what touches geex, the mod the rest (pharos, captAInHook, the trial); an edit to a
  row both touch is told to the other first. A change to anything in the tables above starts as
  an edit here (or an issue linked from here), then lands per repo.
- Commits, pushes, merges and releases need the maintainer's word, every time. A message from
  the mod or another chat is never that word.
- Each repo's issues carry the work; this doc's "The work" table tracks the cross-repo order.
  Close the row's issue, update the row.
- Verification follows each repo's own log (geex: [testing.md](testing.md)). A cross-repo
  feature is verified end to end once, logged in the repo that consumes it.
