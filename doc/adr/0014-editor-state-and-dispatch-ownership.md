# ADR-0014: Editor-state & dispatch ownership

- **Status:** Accepted
- **Date:** 2026-06-03
- **Refines:** [ADR-0003](0003-one-shared-path.md)

## Context

v0.1 shipped `Geex.Dispatch.run(command, doc)` — the dispatchable "world" was a
`Doc`. A vision-alignment audit (2026-06-03) found this contradicts the design's own
commands: `copy` needs the clipboard, insert-at-cursor needs the cursor. A Doc-only
contract would force those commands to bypass the one dispatcher — breaking the
load-bearing invariant ([ADR-0003](0003-one-shared-path.md)) — or be re-typed. The
audit also surfaced that the docs canonically promise `Geex.Dispatch.run/1` (resolve
the active buffer) while only a pure `run/3` exists.

## Decision

1. **`EditorState` is the recorded, replayable, buffer-scoped state** the pure runner
   operates on. Today ≈ `{doc}`; it grows to `{doc, marks, …}` as real recorded buffer
   state appears. A command's pure runner becomes `run(command, %EditorState{}) ->
   {:ok, state} | {:error, reason}` (widening v0.1's `run(command, doc)`).
2. **Cursor / selection / scroll are view-local and ephemeral** — NOT commands, NOT in
   the undo history. Navigation updates `View` directly. A cursor-relative edit
   **resolves the cursor into absolute coordinates and bakes them into the command** at
   dispatch — *a command is self-contained absolute data by dispatch time*. This keeps
   replay deterministic and the history pure-edits. (The LLM never navigates — it edits
   by coordinate — so the shared path is precisely the edit vocabulary.)
3. **Two dispatch layers.** The public **`Geex.Dispatch.run/1`** takes a
   provenance-stamped `%Command{}` (the transport stamps it via `put_provenance` —
   mcp-ai-integration.md §4), then **gather → pure run → scatter + record**: gather the
   `EditorState` from its owner, call the pure per-command `run/2`, scatter the new
   state back, append the command to the buffer's single history. The per-command
   `run/2` is the pure inner layer; v0.1's `run/3` is its transitional form.

The **`Geex.Buffer` process owns the `EditorState` and the one undo history**.
`Geex.Session` owns only cross-buffer / global state (the active-buffer pointer, the
minibuffer input being typed).

## Consequences

- One-path / one-history holds for **edits**; navigation is a separate, cheaper,
  non-recorded view concern ([ADR-0003](0003-one-shared-path.md) tightened to "every
  edit", not "all input").
- Replay stays deterministic: commands carry resolved absolute data (cursor/clipboard
  snapshotted in), so the runner and `replay/2` stay pure; only `run/1`'s gather/scatter
  is impure.
- Distributed state is handled by gather/scatter **in `run/1`**, not by spreading the
  runner across processes — the audit's hardest concern, resolved.
- Per-pane independent cursors (v0.3) work, because cursors are view-local.
- The v0.1 widening is shallow (`dispatch.ex` + the two command bodies; the macro is
  untouched) — do it **before** more Doc-typed commands accrete.
- The clipboard is deliberately **not** in `EditorState` — see
  [ADR-0015](0015-clipboard-subsystem.md).

## See

[vision.md](../vision.md) §1–2, [mcp-ai-integration.md](../mcp-ai-integration.md)
§2 / §3a / §4, [ADR-0002](0002-commands-as-values.md),
[ADR-0003](0003-one-shared-path.md), [ADR-0005](0005-provenance-on-every-command.md),
[ADR-0015](0015-clipboard-subsystem.md).
