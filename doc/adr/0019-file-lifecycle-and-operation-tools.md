# ADR-0019: File lifecycle & MCP operation tools

- **Status:** Accepted
- **Date:** 2026-06-04
- **Refines:** [ADR-0014](0014-editor-state-and-dispatch-ownership.md), [ADR-0003](0003-one-shared-path.md); relates to [ADR-0017](0017-reconcile-file-watch.md), [ADR-0018](0018-mcp-transport-streamable-http.md)

## Context

Buffers were in-memory only. For a harness (or human) to edit **real files on disk** geex
needs file lifecycle — open/load, save/write, create — and a way to address more than one
file. But opening and saving a file are **not content edits**: you don't "undo a save," and
loading isn't a mutation of an existing buffer's content. So they don't belong on the
edit/undo path ([ADR-0003](0003-one-shared-path.md) "navigation is not a command";
[ADR-0015](0015-clipboard-subsystem.md) "copy is not undoable"). And the MCP surface, which
so far had only macro-projected *edit* tools plus a read-only `snapshot`, needs to expose
these operations too.

## Decision

1. **Buffer file I/O (built).** A buffer started with `:path` loads that file's contents (a
   missing path is a fresh empty buffer, created on first save); explicit `:text` overrides
   (in-memory / test buffers). `Geex.Buffer.save/1` writes the current text back and clears
   `dirty`. `Doc` round-trips through `\n` split/join, so `load → save` is byte-stable for
   LF files.
2. **Load/save are operations, not recorded edit commands.** They never enter the undo
   history — only content edits (`insert`/`delete`/`replace`) do. This keeps the one-path /
   one-history invariant scoped to *edits*, exactly as navigation and clipboard already are.
3. **Multi-buffer, active-buffer model.** `Geex.Session.open_file(path)` starts-or-reuses a
   buffer for that path (registered by path in the existing `Geex.Registry`), loads it, and
   makes it the **active** buffer; edits keep targeting the active buffer, so an edit command
   stays buffer-relative ([ADR-0014](0014-editor-state-and-dispatch-ownership.md)) — **no
   per-edit file target**. A harness works sequentially: `open A → edit → save; open B → …`.
4. **Three MCP tool categories, one routing seam.** The MCP surface is:
   - **edit tools** (`insert`/`delete`/`replace`) — macro-projected from the field-spec
     ([ADR-0004](0004-neutral-field-spec.md)), routed through `Geex.Dispatch.run/1` into the
     undo history;
   - **read tools** (`snapshot`) — the read-only query surface (§15b);
   - **operation tools** (`open_file`/`save_file`/…) — hand-written handlers that act on
     `Session`/disk and are **not** recorded as edits.

   `tools/call` routes by category (operation name → handler; else edit-command registry);
   `tools/list` merges all three. Operation tools carry field-spec schemas projected by the
   same `Geex.MCP.Schema` renderer, so they appear in `tools/list` with no hand-synced JSON.

## Consequences

- A harness can open, edit, and save real files on disk — the precondition for the
  "geex editing geex" dogfood and for the [ADR-0016](0016-external-harness-integration.md)
  coverage gate (deny built-in writers only once geex covers open/edit/save).
- The one-dispatcher / one-history spine is **unchanged**: it governs edits; operations are
  a separate, non-recorded category, consistent with reads/navigation/clipboard.
- The MCP layer gains a small routing branch and a hand-written operation-tool surface
  (distinct from the macro command registry) — the cost of the third category.
- Multi-buffer is via `Geex.Registry` (path → pid); the active-buffer model avoids putting a
  file target on every edit command. Concurrent multi-file editing (per-edit targets) is a
  later step if a consumer needs it.

## See

[ADR-0014](0014-editor-state-and-dispatch-ownership.md),
[ADR-0003](0003-one-shared-path.md), [ADR-0015](0015-clipboard-subsystem.md),
[ADR-0017](0017-reconcile-file-watch.md), [ADR-0018](0018-mcp-transport-streamable-http.md),
[mcp-ai-integration.md](../mcp-ai-integration.md) §4 / §15b.
