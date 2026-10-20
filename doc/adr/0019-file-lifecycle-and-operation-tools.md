# ADR-0019: File lifecycle & MCP operation tools

- **Status:** Accepted; amended 2026-10-19 (the human gets create, delete and rename in the TUI)
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

### Implementation decisions (surfaced by the build + an adversarial review)

- **A buffer is a `:temporary` supervised child.** A document buffer holding unsaved edits
  must **not** be silently restarted — a restart reloads from disk with an empty history,
  dropping unsaved work and reverting to stale bytes. So a crashed buffer stays down; its
  `Geex.Registry` entry clears, and recovery is an explicit re-open (which loads from disk on
  purpose). Active-buffer death is surfaced at the MCP boundary as `-32603` and the `Session`
  pointer self-heals on the next `open_file`; *monitoring* the active buffer is deferred (it
  matters once there are concurrent clients).
- **Load is non-raising.** `Buffer.init` uses non-bang `File.read`; an unreadable existing
  file fails the start cleanly as `{:error, {:load_error, posix}}` rather than raising a
  `File.Error` whose struct + stacktrace would leak into the model-facing tool result. The
  "posix error → clean result" contract therefore holds for *load* as it already did for save.
- **Buffer dedup is by the lexical (`Path.expand`-ed) path.** Symlinks/hard links are not
  resolved, so one file reached via two spellings yields two buffers. Acceptable for the
  single-user loopback slice; canonicalization pairs with any future workspace-root
  confinement (geex is not a sandbox today).
- **Open buffers are capped** (`BufferSupervisor max_children`): there is no `close_file`
  yet, so buffers accumulate for the session's life; the cap turns a runaway open-loop into a
  clean `{:error, :max_children}` (an isError tool result) instead of unbounded growth.

## See

[ADR-0014](0014-editor-state-and-dispatch-ownership.md),
[ADR-0003](0003-one-shared-path.md), [ADR-0015](0015-clipboard-subsystem.md),
[ADR-0017](0017-reconcile-file-watch.md), [ADR-0018](0018-mcp-transport-streamable-http.md),
[mcp-ai-integration.md](../mcp-ai-integration.md) §4 / §15b.

## Amendment (2026-10-19): create, delete and rename for the human

**Context.** An agent could create, delete and rename files through the MCP operation tools
(`Session.create_file/2`, `delete_file/1`, `rename_file/2`), but a person in the TUI could do
none of it. The maintainer asked for it in the minibuffer and in the tree, relayed by the
coordinator session.

**Decision.**

1. **Typed verbs** (`Geex.Loop.Verbs`, and the palette's catalog):
   - `new PATH` creates an empty file and opens it. When its directory is missing, geex asks
     "`DIR/` doesn't exist; create it? (y/n)" and makes it (`mkdir -p`) only on a yes. A path
     that exists, on disk or as an open buffer not saved yet, is refused.
   - `new DIR/` and `mkdir DIR` make a directory.
   - `delete` deletes the current file after "delete `PATH`? (y/n)". When the buffer has unsaved
     edits, the question says they go with it, and the notice afterwards says so again.
   - `rename PATH` (or `mv PATH`) moves the current file. `rename` alone asks for the new path,
     pre-filled with the old one. It never overwrites: an existing target is refused.
2. **Tree keys**, when the tree has focus ([ADR-0037](0037-pane-and-file-keys.md)'s amendment):
   - `a` opens the minibuffer with `new DIR/` typed, where `DIR` is the highlighted directory
     (or the highlighted file's directory). Typing a name and Enter is the typed `new`, so a
     trailing `/` makes a directory.
   - `d` deletes the highlighted entry, with the same y/n question. A directory is deleted
     only when it is empty; one with anything in it is refused, before any question.
   - `r` renames the highlighted file or directory, asking for the new path.
3. **Paths.** A relative path is from the project root (the tree's root), not from the current
   file as `open PATH` is: the tree names paths from the root, and its keys type them that way.
   One that leaves the root (`../x`) is refused. An absolute path (`/…`, `~`, `~/…`) goes where
   it says.
4. **Nothing is deleted, and no missing directory is made, without a y.** The question is a
   minibuffer mode (`:confirm`): `y` runs the step; `n`, Enter, Esc and Alt+N cancel ("nothing
   done"); other keys wait. The quit keys still quit.
5. **Off the key loop** ([ADR-0035](0035-the-loop-never-waits.md)). Every step, the checks
   before a question included, runs in a monitored process of its own (`Geex.Loop.FileOps.step/2`)
   and answers the loop with what comes next: a notice, a question, a file to open, a directory
   made, or a rename done. A step that crashes gives a notice and a log line. Opening the new
   file is the existing open path, which ADR-0035 §4 already measured and left in the loop.
6. **Through `Geex.Session`.** The TUI calls the same functions the MCP tools do, plus two new
   ones the MCP surface doesn't get (it is frozen, [ADR-0032](0032-listener-first-agent-integration.md)):
   `make_dir/1` (refuses what exists) and `remove_dir/1` (only an empty directory).
   `rename_file/2` now also takes a directory: every buffer open under it is re-keyed to the
   same place under the new name.
7. **What moves with a rename.** The buffer is the same process, re-keyed (`Buffer.rename/2`),
   so its text, unsaved edits, undo history, tabs and cursor stay attached; the highlight
   reactor follows the new extension.
   - **The ledger moves** ([ADR-0033](0033-durable-ledger.md)): `Ledger.rename/3` records a
     `rename` entry and moves the file to the new path's key, as it did for the MCP rename.
   - **The edits list doesn't.** Its rows are a record of what happened to a path at a time
     ([ADR-0034](0034-panes-tree-edits-hold.md) §6), and `edits.jsonl` is append-only, so they
     keep the old path. Enter on one says the file "no longer exists", as for any file gone
     since. New edits are recorded under the new path.
   - **On delete,** the buffer is closed and its ledger stays at the old key, where
     `mix geex.ledger list` shows it as an orphan until `forget` removes it, as for the MCP
     `delete_file`.

**Consequences.**

- A person can manage files without leaving geex, and every operation either finishes with a
  notice or says why it didn't.
- Two kinds of relative path now exist: `open` is from the current file, the file operations from
  the root. Folding `open` onto the root is left for the maintainer to decide.
- An empty directory shows in the tree only if this run made it
  ([ADR-0034](0034-panes-tree-edits-hold.md)'s 2026-10-19 amendment), since the tree is built
  from a list of files.

**See** `lib/geex/loop/file_ops.ex`, `lib/geex/loop/verbs.ex`, `lib/geex/loop.ex`
(`start_file_op/2`, `file_op_done/2`, `tree_key/2`), `lib/geex/session.ex`;
`test/geex/loop/file_ops_test.exs`, `test/geex/session_test.exs`, `test/geex/loop/verbs_test.exs`;
[testing.md](../testing.md) 2026-10-19.
