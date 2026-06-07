# ADR-0022: The capability reactor — when highlighting & LSP fire

- **Status:** Accepted
- **Date:** 2026-06-07
- **Refines:** [ADR-0021](0021-capability-connections.md), [ADR-0014](0014-editor-state-and-dispatch-ownership.md), [ADR-0010](0010-disk-truth-lsp-v05.md)

## Context

[ADR-0021](0021-capability-connections.md) decided *what* the capabilities are (an `LSP`
connect-out contract; a `Highlight` host-in engine) but left the **trigger model** open: with
geex set up with both, *when* does highlighting recompute and *when* is an LSP call made? Are
there buffer/keystroke hooks? Highlighting wants to feel instant on every keystroke; LSP is a
network round-trip that must never block editing — and is [disk-truth](0010-disk-truth-lsp-v05.md),
so it can't even *see* unsaved edits. The two cannot share one cadence.

## Decision

**1. The command pipeline *is* the change hook.** Every edit is a `%Command{}` through the one
dispatcher into the buffer ([ADR-0003](0003-one-shared-path.md)) — so the **dispatch stream is
the "after change" event**; no separate keystroke-hook system is invented. The Buffer gains a
small **post-dispatch / post-save emit** (a notification at the chokepoint). Buffer lifecycle
hooks already exist as operations ([ADR-0019](0019-file-lifecycle-and-operation-tools.md)):
`open_file` / `save_file` / `close_file` are the `didOpen` / `didSave` / `didClose` points.

**2. A per-buffer *reactor* process** consumes those events. It is started/registered/killed
with its buffer (the same `:temporary` + `Geex.Registry` pattern as the Buffer), subscribes to
the three event sources — **change** (post-dispatch), **view** (cursor/scroll, from
`Geex.View`/`Session`), **lifecycle** (open/save/close) — owns the timers, maps events →
capability calls, and routes results. **It is a separate process from the Buffer**, deliberately:

- **async by construction** — editing finishes in the Buffer and returns; the reactor computes
  on its own timeline, so editing **never waits** on highlighting (this is what "async" *means*
  on the BEAM — a separate process, the free default, not bolted-on concurrency);
- **crash isolation** — a bad grammar / highlighter crash takes the *reactor* down, not the
  Buffer. If highlighting lived in the Buffer, a crash would lose unsaved edits, violating the
  [`:temporary` "never silently drop edits"](0019-file-lifecycle-and-operation-tools.md) policy;
- **separation** — Buffer = edits + history (pure); reactor = derived render state + capability
  cadence.

**3. "Sync" is genuinely blocking; highlighting is async-coalesced-viewport-first.** Computing
highlights inside the dispatch handler would make the keystroke *wait* for highlighting — couples
edit latency to highlight latency, degrading exactly under load. So highlighting runs in the
reactor, **latest-wins, not queue-all**: coalesce a keystroke burst, keep **at most one pass in
flight**, re-check dirtiness when a pass finishes, and highlight the **viewport first** (on-screen
lines, then the rest lazily). This is safe because highlighting has **no correctness contract** —
it is view-local *derived* render state ([ADR-0014](0014-editor-state-and-dispatch-ownership.md),
like the cursor), so a frame of staleness costs nothing and a pass can always be dropped/delayed.
tree-sitter's **incremental** re-parse uses the edited range the `%Command{}` already carries.
(Pure-BEAM compute is scheduler-safe via reduction preemption; a tree-sitter **NIF** would need
dirty-scheduler care — another reason the engine is WASM, [ADR-0021](0021-capability-connections.md).)

**4. LSP fires on save / on-demand — never per-keystroke.** Because v0.5 LSP is
[disk-truth](0010-disk-truth-lsp-v05.md), the server only sees *saved* content, so the cadence is
structural, not a workaround:

- **diagnostics** — on `save_file` (disk now matches the buffer); a buffer `open` requests an
  initial pass;
- **navigation / hover / references** — **on-demand**, triggered by an explicit user action at
  the cursor (one-shot call);
- LSP calls are **async** (network) — fire-and-merge-when-they-arrive, never blocking the editor.

**5. Reads render; writes dispatch; neither pollutes history.** A capability **query** (hover,
goto, diagnostics, highlight tokens) is a **read** → it does **not** go through `Dispatch` (the
write path). Its result is **view-local overlay/render state** — never a `%Command{}`, never in
the undo history (a highlight refresh is *not* an edit). A capability result that **mutates** (a
rename `WorkspaceEdit`, a formatter's output) becomes a `%Command{}` through `Dispatch.run/1`
(the [ADR-0011](0011-direction-b-balance-beam.md) composition rule). One path for writes; reads
stay on the view side.

**6. semanticTokens: `off` by default → opt-in `combined`, gated by the `synced` baseline; never
`full`.** The base highlighter (tree-sitter) is the dependable per-keystroke layer. LSP semantic
tokens are an **optional** overlay that adds compiler-grade context (mutable/param/unused) — but
they are disk-truth, so they are **only valid when the buffer equals disk**. geex already tracks
that: the **`synced` baseline** from [reconcile](0017-reconcile-file-watch.md) is exactly the
"is this buffer clean vs disk?" signal, so it doubles as the "are the semantic tokens fresh?"
gate. Policy: **`off`** (base-only) in v0.5; later an opt-in **`combined`** overlay that renders
only on a *synced* buffer (else fall back to base-only), LSP-token-wins precedence, merged async;
**never `full`** (semantic tokens are optional/partial — replacing the reliable base means flicker
and gaps). Mirrors Zed's off/combined/full and Neovim's capability-gated precedence.

The trigger table:

| Event | Highlighting (in-VM, live) | LSP (MCP, disk-truth) |
|---|---|---|
| buffer **open** | full parse + highlight viewport | initial diagnostics (vs disk) |
| **change** (dispatch) | incremental re-highlight, coalesced + viewport | — (nothing until save) |
| **idle** (debounce) | settle highlight | — |
| **save** | — (already current) | request diagnostics |
| cursor + **user request** | — | goto-def / hover / references (at cursor) |
| **scroll** / viewport | highlight newly-visible lines | — |
| **close** | drop token state | `didClose` / drop |

## Consequences

- No new event system — the dispatcher is reused as the change bus; the only Buffer change is a
  post-dispatch/save emit. The reactor is geex-owned glue, the feature layer that *consumes* the
  [ADR-0021](0021-capability-connections.md) contracts.
- Highlighting never blocks editing and never enters history; an engine crash can't lose edits.
- LSP load is naturally bounded (save/on-demand, not per-keystroke) — disk-truth turns from a
  limitation into the thing that sets the cadence.
- The `synced` baseline built for reconcile is reused as the semantic-token freshness gate — one
  piece of state, two features.
- **Open (build-time tuning, not architecture):** exact debounce/idle values; whether the reactor
  is one-process-per-buffer or a session reactor keyed by buffer; its relationship to the existing
  `Geex.Renderer`. Settle when the highlighter/LSP features are actually wired.

## See

[ADR-0021](0021-capability-connections.md), [ADR-0023](0023-theming-and-extension-loading.md),
[ADR-0014](0014-editor-state-and-dispatch-ownership.md), [ADR-0003](0003-one-shared-path.md),
[ADR-0010](0010-disk-truth-lsp-v05.md), [ADR-0017](0017-reconcile-file-watch.md),
[ADR-0019](0019-file-lifecycle-and-operation-tools.md), the
[research notes](../research/capability-connections.md) (prior-art highlighting cadence).
