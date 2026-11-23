# ADR-0055: Checks on save: triggers, payloads and a diagnostics overlay

- **Status:** Accepted 2026-11-18 (drafted at the maintainer's ask, reviewed by mod against
  stack.md and the trial contract, accepted with the recommended answers to its five questions);
  not built. **Parked 2026-11-23** (the maintainer): nothing of it is built, and nothing will be
  while it is parked. Less invasive first: the user runs a checker with `!` and its output's
  locations are clickable ([ADR-0042](0042-shell-commands.md)'s amendment of that date). See
  "Parked 2026-11-23" below.
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
  The run starts no sooner than 2 s after the newest write the trigger saw, so the files that
  started it are outside §5's 2 s margin and only writes during the run come back unsure (the
  `save` trigger needs no wait: the saved file is held and goes by its hash).
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
arguments and ignore stdin (`pharos diagnostics --json {files}`). **A check is meant to read,
not write:** the command is the user's, so geex can't stop it writing, but anything it writes
besides its own build output (`mix compile`'s `_build`) reaches geex like any outside change,
recorded `:external` by reconcile (ADR-0034), never as the human's or a check's edit. A
formatter is not a check (see Alternatives).

**4. Output, in one of three forms the check declares:**

- **`json`**: `{"files": [{"path", "status", "reason"?, "diagnostics": [...]}]}`, each
  diagnostic LSP's shape (`range` with 0-based `line` and `character`, `severity` 1 to 4, `code`,
  `source`, `message`), and an optional `"positionEncoding"` (`"utf-16"`, the default, `"utf-8"`
  or `"utf-32"`, LSP 3.17's names). `status` is `ok`, `unsure` or `failed`. Fields geex
  doesn't know are ignored. This is `pharos diagnostics --json`'s shape as it stands (it also
  prints `file`, `uri` and `project`; an `unsure` file's `reason` is `no_publish`, `carried_over`,
  `not_reported` or a project one (`no_project` in 0.3.2, `project_unknown` from 0.3.3),
  comma-joined when there are several, and a
  `failed` file's is free text), so pharos needs no wrapper. **geex keys on `status` only**; a
  `reason` is shown, never interpreted.
- **`tsc`**: `path(line,col): error TS1234: message`, 1-based, UTF-16 columns.
- **`lines`**: `path:line[:col][:] [severity:] message`, 1-based, columns counted as the check
  says (`codepoint` by default), the severity word read when present (`error`, `warning`,
  `info`, `note`, `hint`).

Positions become graphemes at this edge, pure and property-tested (invariant 5). A position past
the line's end lands at its end; past the file's end, on its last line. The conversion needs the
line's text, so it happens only for a file geex holds. For one it doesn't (a project check names
files that aren't open), the position is kept as the check gave it (line, column and the
column's unit) and becomes graphemes when the file is opened; until then `problems` lists it by
its line (2026-11-23).

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
- **Versions decide freshness.** geex keeps the version each file had when the run started:
  for a file geex holds, the sha256 of its synced text (the disk as geex last read it, which is
  what a check reads, unsaved edits or not); for one it doesn't, its modification time and
  size, read with `Geex.Disk` (BUG-22) in `Geex.Checks`, off the loop (ADR-0035: the count grows
  with what a project check reports), once at the run's start and once at its end. A file whose
  version changed during the run gets its result drawn as unsure, in the gutter and in
  `problems` alike (2026-11-23). Time and size miss a rewrite that keeps the size within one
  tick of the modification time (git's "racy clean" case), and geex reads modification times
  to the second (`:file.read_file_info` has no finer field, whatever the filesystem stamps), so
  the margin is 2 s: that one second of resolution, and FAT/exFAT's 2 s stamps. As git does, a
  file whose modification time isn't older than the run's start by at least 2 s gets its result
  drawn unsure too. Shrinking the margin needs a finer stat than geex has, not a faster
  filesystem.

**6. The overlay.** Per file: the set of diagnostics (a grapheme range, severity, code, source,
message), the version they were made for (§5: the hash, or the time and size of a file geex
doesn't hold), and the check's status. Every file a check reported on has a set, open or not;
the gutter and `problems` look a file up in it when they draw, so nothing marks a closed file and
nothing has to visit it when its problems go away. **It is display data, like the
highlight overlay and the blame marks:** never text, never a command, never in the history or
the ledger, so the shared path, replay and the cassette are untouched. It lives in its own
process (a `Geex.Checks` owning the runs and the sets), and the loop draws what it says.

- **Fresh:** the file's synced text has the set's hash. Drawn as found.
- **Unsaved edits since:** the marks move with the edits, as the highlight overlay does
  (`Geex.Edit.Footprint`), so a problem stays on its line when lines are added above it, and are
  drawn dim: they describe the saved file (ADR-0010).
- **Stale:** the disk no longer has the set's hash (an agent's write, an outside change), or the
  last run failed. Drawn dim until a run brings a new set. For a file geex doesn't hold, stale
  when its time or size no longer match the set's: `problems` reads them again (off the loop)
  each time it lists, and opening the file compares them before its marks are drawn. The set is
  adopted under the opened text's hash only when the time and size read both before and after
  the text match the set's (and §5's 2 s rule didn't make it unsure); otherwise it is stale. Stale marks are dimmed, never dropped: a change
  may have fixed the problem or made a new one, and only a run can say which.
- **Not watched:** a closed file changed by an outside command (`!npm run lint --fix`) keeps
  its set, drawn stale once read again, until the next run of the check (a `project` run
  replaces every file's set). Re-running on every change to any project file would mean watching
  every file's contents and running the check on each outside write; it isn't done.
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
  user's own commands (7); nothing listens (8). Checks read none of the user's files' contents
  themselves: the hashes come from text geex already holds, and a file it doesn't hold is only
  stat-ed (its time and size, through `Geex.Disk`).

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
   section and the TOML dependency it already decided on (ADR-0025's amendment of this date),
   read with the [`toml`](https://hex.pm/packages/toml) package (bitwalker/toml-elixir; chosen
   2026-11-19, the comparison in that amendment).
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

## Decided 2026-11-19, for the build (the maintainer; reviewed in part 2026-11-23, then parked)

Reviewed on 2026-11-23: item 3 (the switch governs only geex's own runs; a typed `check` is
always shown; its marks stay dim while the switch is off), item 2's keys, the wording of §3 and
§5–§6, and item 6 (files geex doesn't hold). Item 5's defaults were not confirmed before the
ADR was parked.

1. **A fourth format, `elixir`,** for `mix compile`: its warnings and errors span several lines
   (the message, a code excerpt, then `└─ lib/w.ex:2:9: W.f/1`), which `lines` can't read. geex
   itself is one of the first checks (`mix compile --all-warnings` on its own repository), with
   the `incomplete` pattern of §5 for a compile error.
2. **Keys:** `Alt+3` runs `check` (the current file's checks, now) and `Alt+4` shows `problems`
   (both free since ADR-0051; `Alt+5` stays kept for multiple cursors). Both are named commands
   in the bindings table (ADR-0047), so they can be moved like any other. ADR-0051 had left
   `Alt+3` and `Alt+4` to the user; the maintainer agreed on 2026-11-23 to amend it, but with
   this ADR parked the amendment wasn't made, and the keys stay the user's.
3. **A switch in `Alt+Y`:** a General setting, "Run checks on save" (`run_checks` in
   `settings.json`, ADR-0040 §7), **off by default** (the maintainer, 2026-11-20): configured
   checks run on their own only once it is turned on. **The switch governs only the runs geex
   starts on its own** (the maintainer, 2026-11-23). Off, no check runs on a save or a change on
   disk, and turning it off stops any run under way and clears every check's marks;
   `config.toml` is untouched, so turning it on runs what is configured. **The typed `check` (and `Alt+3`) runs
   whether it is on or off, and its results are drawn as any run's are**: the marks, the status
   line's message and `problems`. A deliberate run is always shown. With the switch off, nothing
   runs again on a save, so those marks follow §6: dim after an edit, stale once the saved file's
   hash moves, until the next typed `check`. No notice points at the
   switch when checks are configured and it is off: the setting is found in `Alt+Y` (the
   maintainer, 2026-11-23).
4. **Global, not per project.** The `Alt+Y` settings are geex's one file; checks are already per
   project in `config.toml` (each names its projects), which is where one project goes quiet. A
   session-only `checks-pause` for the current project is a possible later addition, not built.
5. **Defaults the maintainer agreed to, to review tomorrow:**
   - `projects` names directories: a check applies to a file saved under one and runs there; a
     check naming no project does nothing (never global by accident).
   - `match` reads like `.gitignore`: a pattern without a `/` matches a file's name at any depth;
     one with a `/` matches from the project's root.
   - A tsc whose version has no syntactic list makes every run of that check incomplete (it only
     adds marks), with a notice once saying why. The installed tsc here is 6.0.3, the one list the
     trial contract carries.
   - Severity colours come from the theme when it has them, else red, yellow and blue (the ANSI
     colours under the terminal theme); no catalog theme changes in the first build.
   - `config.toml` is read again when it changes; a malformed one gives one notice and loads no
     checks until it is fixed, never a crash. The `run_checks` setting is untouched by it.
   - A `projects` entry may start with `~`, which is expanded to the home directory.
   - pharos's `json` form is tested against recorded `pharos diagnostics --json` output; a live
     pharos run only if the installed one works.
   - **Build order:** slice 1, the config, the runner, the `tsc`, `elixir` and `lines` formats,
     the overlay, the gutter, the status line, `check` and `problems`, on save, with the `Alt+Y`
     switch; slice 2, the `disk` trigger, the `json` form (pharos), polish. Each slice reviewed
     before the next.
6. **Files geex doesn't hold** (the maintainer, 2026-11-23): a `project` check reports on files
   that aren't open. Their sets are kept like any other, tagged with the file's time and size
   instead of a hash, drawn stale when those move and unsure when they moved during the run, and
   their positions become graphemes when the file is opened (§4, §5, §6). geex still never reads
   their contents for a check, and doesn't watch them between runs.

## Parked 2026-11-23

The maintainer, reviewing the build decisions: handling each checker's quirks in geex (tsc's
syntactic codes, rustc going quiet after an error, `mix compile`'s multi-line messages) is the
part they don't want. Two roads were weighed that day, then both set aside for something less
invasive:

- **pharos as the only source** (only the `json` form; pharos absorbs each language's
  quirks). Set aside for now, on facts mod and verifier-two gathered from pharos main 4fc68f2,
  its v0.3.x tags and live runs:
  - pharos reports only the files it is asked about: no `workspace/diagnostic`, none planned.
    What an edit broke in a closed file, the main thing tsc and `mix compile` give, can't be
    shown.
  - Elixir, geex's own language, isn't usable through it today (next-ls): a clean file is never
    published, so it answers unsure after the full timeout; a first ask after an edit compiles
    nothing; after a fix the first answer is usually the old set, marked `carried_over`; and
    next-ls is archived (pharos#53 proposes Expert). When next-ls does publish, its set matches
    `mix compile --all-warnings` exactly.
  - geex's runs would act on the agent's session: a re-sync starts rust-analyzer's cargo check
    (the target-dir lock), a short timeout restarts ruby-lsp, and a language server keeps the
    environment of whichever session started it, so a run without the project's mise env breaks
    Elixir for every session sharing the daemon.
  - pharos's side was filed: pharos#59 (next-ls clean files, the first ask), #60 (the stale
    `carried_over` after an edit), #61 (a missing file waits out the timeout), #62 (a server keeps
    its starter's env). #60–#62 are going into pharos 0.4.0; #59 waits for the Expert switch.
- **Only the `json` form, with small scripts** printing it for project checks: no language
  knowledge in geex, but the quirks move into scripts, and §5–§6's machinery stays.

**What replaces it for now:** layer 1, made easier. The user runs their checker with `!`; the
output pane draws each line's location as a link, a click opens it, and `Alt+N` steps through
them ([ADR-0042](0042-shell-commands.md)'s amendment of 2026-11-23). Nothing runs on its own,
and nothing marks the code.

**If it comes back,** the text above is where it stood: reviewed by geex-mod through the racy-clean
rule (§5) and the files geex doesn't hold (item 6). The `json` form's safety rules from that
review, for any future call of `pharos diagnostics`:

1. Ask `pharos --version` first (the shim answers without its runtime) and require 0.3.5 or
   later (paths with spaces, pharos#16). An older pharos runs an MCP server and can wait
   forever: stdin from `/dev/null`, a kill timeout, and a run whose output has no `{"files": …}`
   is failed (exit 0 with nothing printed happens).
2. Run it in the project's directory with the project's full environment (mise's included), so it
   joins the agent's daemon and servers (stack.md rule 7) and never starts a server the agent
   can't use (pharos#62).
3. Budget: files × (timeout + 10 s) within the run's limit; the CLI answers files in order, so send
   the saved file, never the project, and never a file that's gone (it waits out the timeout,
   pharos#61).
4. No version or hash in the output: hash each file before and after the run.
5. `failed` with exit 0 (no server, an unserved type) is "this check can't answer", never clean;
   exit 1 is a failed run. An `unsure` answer can carry real diagnostics: draw them unsure.
6. Keep pharos's default timeout (a short one restarts ruby-lsp).

The `Alt+3`/`Alt+4` keys, ADR-0025's config layer and the geex → pharos row in stack.md wait
with it.

## See

[ADR-0021](0021-capability-connections.md), [ADR-0010](0010-disk-truth-lsp-v05.md),
[ADR-0008](0008-pharos-not-bundled.md), [ADR-0025](0025-user-config-layer.md),
[ADR-0023](0023-theming-and-extension-loading.md) §5, [ADR-0035](0035-the-loop-never-waits.md),
[ADR-0042](0042-shell-commands.md), [ADR-0034](0034-panes-tree-edits-hold.md), [stack.md](../stack.md), pharos ADR-040 (`pharos
diagnostics`), [roadmap](../roadmap.md) items 22 (autocomplete) and 23 (this).
