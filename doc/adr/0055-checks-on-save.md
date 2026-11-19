# ADR-0055: Checks on save: triggers, payloads and a diagnostics overlay

- **Status:** Accepted 2026-11-18 (drafted at the maintainer's ask, reviewed by mod against
  stack.md and the trial contract, accepted with the recommended answers to its five questions);
  not built
- **Date:** 2026-11-18
- **Amends:** [ADR-0021](0021-capability-connections.md) (diagnostics become a contract with more
  than one adapter), [ADR-0010](0010-disk-truth-lsp-v05.md) (checks run on the saved text),
  [ADR-0008](0008-pharos-not-bundled.md) (a second road to pharos),
  [ADR-0025](0025-user-config-layer.md) (its first build is checks' `[[checks]]`), each by an
  amendment of this date
- **Relates to:** [ADR-0035](0035-the-loop-never-waits.md) (its 2026-11-15 amendment: the save
  leaves the loop and writes in place), [ADR-0042](0042-shell-commands.md) (the output pane and its locations),
  [ADR-0032](0032-listener-first-agent-integration.md) (the blame marks in the gutter),
  [ADR-0023](0023-theming-and-extension-loading.md) §5 (code is loaded only from a declared path),
  [stack.md](../stack.md) (rule 8, fail open; the connections table)

## Context

The maintainer, 2026-11-18, on using language servers from geex: "it almost feels like geex
needs lifecycle hooks itself that we could use for running these manual pharos diagnostics or
tsc checks." Today a human can run `!npx tsc --noEmit`, read the output pane and press Enter on a
`path(line,col)` to open it (ADR-0042's 2026-11-13 amendment). Nothing runs on its own, and
nothing marks the code.

Vim and Emacs got to language servers in three layers, and the order matters:

1. **Run a command, step through its errors:** Vim's `:make` with `errorformat` into the quickfix
   list; Emacs's `compile` and `next-error`. geex has this: `!`, the output pane, Enter, `Alt+N`.
2. **Check in the background, mark the code:** ALE (Syntastic before it) in Vim; flymake and
   flycheck in Emacs. **One display, many sources:** Neovim's `vim.diagnostic`, Emacs's flymake
   backends.
3. **A language-server client**, as one more source for that display: eglot sends its
   diagnostics into flymake rather than drawing its own.

geex has layer 1. This ADR adds layer 2. Layer 3 stays ADR-0021's "decided then" (completion,
roadmap item 22, needs unsaved text that ADR-0010 leaves out).

Since pharos 0.3.2 (pharos ADR-040) there is also `pharos diagnostics [--json] FILE...`: one
answer per file from the shared daemon, each `ok`, `unsure` or `failed`, with LSP's diagnostic
shape (0-based lines, UTF-16 columns). A check can call it like any other command, so geex can
show pharos's diagnostics without being an MCP client.

## Decision

**1. Three parts, kept apart.** A **trigger** (geex noticed something), a **check** (a command
the user configured, run off the loop) and the **overlay** (geex's per-file diagnostics, which
any check fills). tsc, `mix compile` and `pharos diagnostics` are all checks; nothing in the
overlay knows which ran.

**2. Triggers.** Only what the first checks need:

- **`save`**: a save of the file finished writing. The loop already hears each file's result
  (`{:geex_saved_file, …}`), and geex knows the exact text it wrote (`Buffer.begin_write/2`'s
  text), so the check is labelled with that text's sha256. Never the watcher's event for the same
  write: the save writes in place (ADR-0035's 2026-11-15 amendment), so a reader started by the
  watcher could see half a file. A `save-all` that writes five files of one project starts each
  check once, with all five.
- **`disk`** (off unless a check asks for it): a file geex holds changed on disk and reconcile's
  quiet period is over, as when an agent writes it. The hash is the one reconcile read. This is
  the agentic case: the human sees what an agent's write broke, without the agent's own hook.
  An open buffer holds its text when the disk changes (ADR-0034): until it is fast-forwarded,
  the marks describe text it doesn't show, so they are drawn stale beside its "behind" notice,
  and fresh once the fast-forward brings the checked text in.

**3. A check is a command, with an envelope and placeholders.** It runs as `sh -c COMMAND` in the
project root, the way `Geex.Shell` runs `!`: its own process group, no terminal, `TERM=dumb`,
`PAGER=cat`, stopped with TERM then KILL. Its stdin is a JSON envelope:

```json
{"geex": 1, "event": "save", "root": "/abs/project",
 "files": [{"path": "/abs/project/src/a.ts", "sha256": "<64 hex>"}]}
```

and `{files}` and `{root}` in the command expand to the same, shell-quoted, for programs that take
arguments and ignore stdin (`pharos diagnostics --json {files}`). **A check never writes the
user's files.** A formatter is not a check (see Alternatives).

**4. Output, in one of three forms the check declares:**

- **`json`**: `{"files": [{"path", "status", "reason"?, "diagnostics": [...]}]}`, each
  diagnostic LSP's shape (`range` with 0-based `line` and `character`, `severity` 1 to 4, `code`,
  `source`, `message`), and an optional `"positionEncoding"` (`"utf-16"`, the default, `"utf-8"`
  or `"utf-32"`, LSP 3.17's names). `status` is `ok`, `unsure` or `failed`. Fields geex
  doesn't know are ignored. This is `pharos diagnostics --json`'s shape as it stands (it also
  prints `file`, `uri` and `project`; in 0.3.2 an `unsure` file's `reason` is `no_publish`,
  `carried_over`, `not_reported` or `no_project`, comma-joined when there are several, and a
  `failed` file's is free text), so pharos needs no wrapper. **geex keys on `status` only**; a
  `reason` is shown, never interpreted.
- **`tsc`**: `path(line,col): error TS1234: message`, 1-based, UTF-16 columns.
- **`lines`**: `path:line[:col][:] [severity:] message`, 1-based, columns counted as the check
  says (`codepoint` by default), the severity word read when present (`error`, `warning`,
  `info`, `note`, `hint`).

Positions become graphemes at this edge, pure and property-tested (invariant 5). A position past
the line's end lands at its end; past the file's end, on its last line.

**5. What a result means.**

- **Scope.** A check says whether it reports on the **files** it was given (pharos) or on the
  whole **project** (tsc, `mix compile`). A `files` result replaces those files' sets. A
  `project` result replaces the set of every file in the project, so a file it no longer names
  is clean.
- **Incomplete runs never clear.** Some checkers stop reporting once one file is broken, and a
  project result read naively would then draw every other file clean, the false "clean" this ADR
  promises never to show. The trial paid to learn it for tsc ([stack-trial-hooks.md](../stack-trial-hooks.md),
  "Incomplete checks"), and the `tsc` format takes its rule:
  - tsc stops reporting type errors anywhere once any file has a syntactic, options or global
    error. So a run is **incomplete** when its output has an error whose code is on the
    syntactic list, or an error with no file or in a file outside the program (`tsconfig.json`'s
    TS5xxx, TS6053, TS2318), **unless** it also has an error in a program file whose code isn't
    on the list (that proves the type pass ran).
  - The list is pinned to a TypeScript version: neither "TS1xxx" nor "below 2000" works (TS2657
    in JSX, TS8010 in JavaScript files are on it). geex keeps the lists as data, starting with
    6.0.3's 157 codes from the trial contract. A `tsc` check names how to ask the version
    (`version = "npx tsc --version"`), which geex runs once per project and session; with no
    version, or one geex has no list for, **every result of that check is incomplete**.
  - An incomplete run only **adds** what it found. It never clears a file's marks; the files
    it didn't report on keep theirs, drawn stale.
  - Other checkers can stop the same way: a compile error in `mix compile` stops the files that
    depend on it, and `mix compile` reports warnings only for the files it recompiles (its
    `--all-warnings` flag reports the rest). A `lines` check can name a pattern that marks a run
    incomplete (`incomplete = "== Compilation error"`), with the same rule; a `mix compile`
    check needs both, the flag and the pattern.
- **Exit status.** A run that produced parseable output is a result, whatever its status (tsc
  exits non-zero when it finds errors). A non-zero exit with nothing parseable is **failed**: the old
  marks stay, drawn stale, and the notice offers the output in the pane. Exit 0 with nothing
  parseable is clean.
- **One run per check and project.** A new trigger stops the run under way and starts again
  (ADR-0035, as a new search does). A run is stopped at its time limit (120 s unless the check
  says) and is then failed.
- **Hashes decide freshness.** geex keeps the sha256 each file had when the run started. A file
  whose disk changed during the run gets its result drawn as unsure.

**6. The overlay.** Per file: the set of diagnostics (a grapheme range, severity, code, source,
message), the hash they were made for, and the check's status. **It is display data, like the
highlight overlay and the blame marks:** never text, never a command, never in the history or
the ledger, so the shared path, replay and the cassette are untouched. It lives in its own
process (a `Geex.Checks` owning the runs and the sets), and the loop draws what it says.

- **Fresh:** the file's synced text has the set's hash. Drawn as found.
- **Unsaved edits since:** the marks move with the edits, as the highlight overlay does
  (`Geex.Edit.Footprint`), so a problem stays on its line when lines are added above it, and are
  drawn dim: they describe the saved file (ADR-0010).
- **Stale:** the disk no longer has the set's hash (an agent's write, an outside change), or the
  last run failed. Drawn dim until a run brings a new set.
- **Unsure:** pharos's `unsure`, or a hash that moved during the run. Drawn in their own way,
  **never as clean** (the promise recorded on geex#2).
- A result for a hash older than the set's is dropped.

**7. What is drawn, least intrusive first.** The first build:

- **The gutter:** the line number in the colour of the line's worst severity, and a glyph in the
  gutter's last column, the blank one between the number and the text: `●` error, `▲` warning,
  `·` information or a hint, `○` unsure. The agent mark keeps the first column (`▌`), so both
  can show. The gutter doesn't widen.
- **The status line:** the message for the line under the cursor, after the agent's `✎` when
  there is one, and the file's count (`✖ 2 ▲ 1`).
- **`problems`:** every diagnostic of every file in the output pane, worst first, one per line in
  `path:line:col` form, so Enter opens it and `Alt+N` steps, as with search results.
- **`check`:** runs the current file's checks now, as a save would.

Not in the first build: underlining the exact range, messages drawn at a line's end (Neovim's
virtual text), popups, marks on tree rows and tabs.

**8. Configuration: the user's own, never the project's.** A check runs a command, so it is code
in ADR-0025 §4's sense (after ADR-0023 §5): loading it "must be a declared, auditable act, never
auto-scan magic". Checks live only in the
user's config, each naming the project roots where it is on; geex never reads a check from a file
inside a project, so opening a cloned repository runs nothing. The first build reads them from
the hand-edited config of ADR-0025, which this makes that layer's first named consumer; its
project file (`.geex.toml`) never carries checks:

```toml
[[checks]]
name     = "tsc"
projects = ["~/work/app"]
match    = ["*.ts", "*.tsx"]          # which saved files start it
command  = "npx tsc --noEmit --pretty false"
version  = "npx tsc --version"        # picks the syntactic list (§5)
format   = "tsc"                      # json | tsc | lines
scope    = "project"                  # files | project
on       = ["save"]                   # save | disk
```

An app gate, `checks`, off under `mix test`; tests start `Geex.Checks` with their own checks and
a stub runner.

**9. pharos is one more check (tier 1).** With pharos installed:

```toml
[[checks]]
name     = "pharos"
projects = ["~/work/app"]
match    = ["*.ts", "*.tsx"]
command  = "pharos diagnostics --json {files}"
format   = "json"
scope    = "files"
```

It joins the shared daemon as any `pharos` command does (stack.md rule 7), so it costs no second
language server. Its `unsure` answers are drawn as unsure; the trial's dry run found tsserver's
`projectInfo` timing out under load and giving spurious `unsure` answers, a pharos fix that
would also cut spurious unsure marks here. geex runs the same without it (rule 8);
a missing `pharos` is a failed check, said once. pharos-mcp#16 (paths with a space or escaped
characters) applies until fixed. This adds a geex → pharos row to stack.md's connections table,
so this section went through stack.md's owner (reviewed 2026-11-18; its row is added now, with status "built" when this ships).

**10. Fail open.** A check that is slow, crashes, prints junk or isn't installed costs its marks,
never an edit, a key or a save. Its process holds nothing the loop waits on.

## Consequences

- geex shows problems in the code from any checker the user already has, in any language, with no
  language server; pharos's diagnostics fit the same overlay unchanged.
- The agentic case gets a human-side view: with `on = ["disk"]`, what an agent's write broke shows
  in the human's gutter. Later, maybe: the blame says who wrote each marked line, so "2 new errors
  on lines claude wrote" is a join of two things geex already has.
- New work: the trigger and runner (`Geex.Checks`), three output parsers and the position
  conversion (pure, with properties), the overlay's shift and freshness, the gutter column, the
  status line, `problems` and `check`. ADR-0025's first build (the config loader and a TOML
  dependency) comes with it, scoped to `[[checks]]` (decision 1).
- Costs: a check runs on every save, and tsc on a big project is slow (one run at a time, a new
  save stopping the old, keeps it bounded); when the user also runs an agent-side compiler hook
  (captAInHook's), it and a `disk` check both run tsc on the same write. The gutter's last column
  now carries meaning. The tsc syntactic lists are data geex keeps per TypeScript version: a new
  version needs its list before its results can clear anything.
- The invariants: no buffer change, so 1 to 3 are untouched; check output is piped, never the tty
  (4); positions become graphemes at the edge (5); attribution isn't touched (6); no LLM, the
  user's own commands (7); nothing listens (8). Checks read none of the user's files themselves;
  the hashes come from text geex already holds.

## Alternatives considered

- **Checks from a project file** (`.geex/checks.json` in the repository): convenient to share, but
  opening a cloned repository would run its commands. A trust step (VS Code's "workspace trust")
  could allow it later; the user's own config is enough to start.
- **captAInHook as the dispatcher:** geex registers as a harness, and captAInHook's payloads
  (`pharos-hook.sh`, the trial's compiler hook) serve the human and the agent from one registry.
  It would make a core editor feature depend on another tool (stack.md: geex runs without its
  peers), those payloads answer an agent in text where geex wants diagnostics, and it changes the
  cross-repo contract. captAInHook's shim exists because a harness runs a fresh command per hook;
  geex is already the long-lived process, so it needs no shim. The envelope in §3 keeps this road
  open.
- **A language-server client first** (tier 2): the interactive features need it, diagnostics
  don't, and it needs unsaved text (ADR-0010) and its own servers or a pharos bridge (stack.md
  rule 7). The overlay built here is what it would feed.
- **Checking as you type:** answers about unsaved text, against ADR-0010, and a run per pause in
  typing. Saving is the trigger.
- **Format on save as a check:** a formatter writes the file, which reconcile would record as
  `:external`, outside the save's undo step, and a `disk` check would see its write and run
  again. If it comes, the formatter reads the buffer on stdin and geex applies the difference as
  the human's command through `Dispatch.run/1`: its own decision.

## Decided 2026-11-18 (the maintainer took the recommended answers)

1. **Where checks live:** ADR-0025's `config.toml`, its first build being only the `[[checks]]`
   section and the TOML dependency it already decided on (ADR-0025's amendment of this date).
   TOML takes hand-written shell commands without escaping and allows comments; a third file
   beside `settings.json` had no plan behind it.
2. **The `disk` trigger:** in the first build, off unless a check asks for it. It is the agentic
   case, and reconcile already reads the new text and its hash.
3. **The gutter:** the glyph in the gutter's blank last column and the number coloured. The
   gutter never widens, so the text doesn't shift when the first problem comes or the last goes.
4. **The status line:** the agent's `✎` first, then the message. `✎` is short and fixed; a long
   message is cut at the end, and `problems` shows it whole.
5. **pharos (§9):** in the first build, as a capability, not a default: the `json` form and the
   unsure state are built anyway, and nothing runs pharos unless the user's config names it.
   stack.md's owner adds the geex → pharos row (status "built" once this ships); the MCP row stays
   parked for definitions, references and hover.

## See

[ADR-0021](0021-capability-connections.md), [ADR-0010](0010-disk-truth-lsp-v05.md),
[ADR-0008](0008-pharos-not-bundled.md), [ADR-0025](0025-user-config-layer.md),
[ADR-0023](0023-theming-and-extension-loading.md) §5, [ADR-0035](0035-the-loop-never-waits.md),
[ADR-0042](0042-shell-commands.md), [ADR-0034](0034-panes-tree-edits-hold.md), [stack.md](../stack.md), pharos ADR-040 (`pharos
diagnostics`), [roadmap](../roadmap.md) items 22 (autocomplete) and 23 (this).
