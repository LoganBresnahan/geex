# geex — per-harness presets (ADR-0016, Rung 1)

A **preset** is the checked-in artifact of ADR-0012's *cooperative* regime, made concrete
by [ADR-0016](../doc/adr/0016-external-harness-integration.md): per supported harness, a
small config that (a) **denies the harness's built-in file writers** and (b) **points its
MCP config at geex**, so the harness's edits flow through geex's dispatcher — one shared
command path, with undo / replay / provenance — instead of straight to disk.

This is **Rung 1** of the enforcement ladder. Read the next section before you rely on it.

## What a preset is — and is not

- A preset is **the nice default, not enforcement.** A project-scope config is
  advisory-by-cooperation: it depends on the harness honoring it, and a user can override
  it (unless it is deployed as managed/org settings). Do **not** describe a preset as
  "enforcement."
- **Prompt / `CLAUDE.md` instructions are not a boundary either** — only config that the
  harness actually obeys counts.
- The honest floor underneath is **Rung 0 — [reconcile](../doc/adr/0017-reconcile-file-watch.md)**
  (always on): any out-of-band write — a denied tool the harness ignores, a shell command,
  a second terminal, `git checkout` — is *detected* and replayed into the undo history
  tagged `:external`, never silently lost. The preset makes geex the *nice* path; reconcile
  makes off-path writes *honest*.
- Real **enforcement** (repo read-only, geex the only egress) is **Rung 2** — the
  OS-sandbox the harness already ships (Codex `sandbox_mode`, Claude Code `sandbox-runtime`).
  geex builds no sandbox; that rung is documented, not shipped here.

### Why Bash is deliberately *not* denied

A preset denies the harness's **structured file-writing tools** (the ones that map cleanly
onto geex's MCP tools). It intentionally does **not** try to block shell writes
(`echo > f`, `sed -i`, `python -c`, …): that is the **subprocess-write gap** Rung 1 is
documented *not* to close ([ADR-0016](../doc/adr/0016-external-harness-integration.md) §3).
Chasing every shell write here is both futile (infinitely many spellings) and harmful
(it breaks the harness's legitimate shell use). Shell writes fall through to **Rung 0
reconcile** (tagged `:external`); locking them out is **Rung 2**'s job. Keeping the preset
to structured writers is what keeps it honest about what it is.

## The coverage gate (now met)

Removing a harness's built-in writers is only safe once geex's MCP tools cover **every**
mutation the harness needs. As of the v0.5 write surface that gate is **met** — geex
exposes, over MCP:

| Need | geex tool(s) |
|---|---|
| edit text | `insert`, `delete`, `replace`, `edit` (search/replace) |
| create a file | `create_file` |
| delete a file | `delete_file` |
| rename / move | `rename_file` |
| open / save / close a buffer | `open_file`, `save_file`, `close_file` |

So a harness whose structured writers are denied can still do all of create / edit / delete
/ rename through geex.

## Using a preset

1. **Start geex serving** the loopback MCP transport (ADR-0018):

   ```sh
   mix geex.serve            # 127.0.0.1:4000  (or: GEEX_SERVE=1 mix run --no-halt)
   mix geex.serve --port 4100
   ```

   The listener binds `127.0.0.1` only; nothing off-host can reach it.

2. **Copy the harness's preset into your *target* project** (the repo the harness edits —
   **not** geex's own repo root, where it would disable geex's own development by denying
   *your* editor's writers). For Claude Code:

   ```sh
   cp -r presets/claude-code/. /path/to/your/project/
   ```

   That lands two files at the project root:
   - `.mcp.json` — registers the `geex` MCP server at `http://127.0.0.1:4000/mcp`
     (type `http`, the Streamable HTTP transport). Commit it.
   - `.claude/settings.json` — `permissions.deny` for the structured writers
     (`Write`, `Edit`, `NotebookEdit`, plus legacy `MultiEdit` — a separate tool in
     Claude Code ≤1.x, folded into `Edit` in 2.0; denying a tool the harness no longer
     exposes is harmless, kept for back-compat). Commit it (this is the shared, team file;
     personal overrides go in the gitignored `.claude/settings.local.json`).

   Adjust the port in `.mcp.json` if you served on a non-default one.

3. **Approve the server once.** On first run Claude Code prompts to trust the project MCP
   server in `.mcp.json` (a deliberate one-time security gate); approve it. Check status
   with `/mcp`. From then on the harness's writes route through geex's tools, and anything
   off-path is caught by reconcile.

> These config keys are **version-sensitive** (ADR-0016): harness vendors move them. If a
> preset stops working, re-check it against the harness's current docs.

## Status

| Harness | Tier (ADR-0016) | Preset |
|---|---|---|
| **Claude Code** | first-class | `claude-code/` — loopback MCP wire + tools + provenance + save verified with an external client (curl); a live claude-code-honoring-the-preset run is still pending (see [testing.md](../doc/testing.md)) |
| Codex | first-class (best — `sandbox_mode`) | follows this shape; not yet checked in |
| Gemini / Continue / Roo / OpenCode | first-class | follow this shape; not yet checked in |
| Cline, Cursor | best-effort (built-in editor unremovable) | reconcile-only — no MCP-only preset by design |
| aider | out of scope (no MCP client) | reconcile-only — geex is invisible to it |

The flagship (Claude Code) is the named consumer that drove v0.5; the other first-class
presets are the same two pieces — an `.mcp.json` pointing at geex plus a deny-list of the
harness's structured writers — in each harness's own config dialect, added as real users
appear (presets are ongoing, version-sensitive maintenance).
