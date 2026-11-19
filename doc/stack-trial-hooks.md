# The trial's two hooks: one contract

Arms 2 and 3 of the pharos trial ([stack.md § The pharos trial](stack.md#the-pharos-trial),
[pharos-mcp#7](https://github.com/LoganBresnahan/pharos-mcp/issues/7)) follow this contract,
so the only difference between them is where the errors come from:

- arm 2 is the compiler hook
  ([captAInHook#4](https://github.com/LoganBresnahan/captAInHook/issues/4));
- arm 3 is pharos's hook ([pharos-mcp#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6)).

Arm 1 runs with no hook, under the same setup. The trial is TypeScript; a Rust trial would
need pharos-mcp#8 fixed and a Rust version of "The checkers" and the line format.

The coordinator owns this file, like stack.md: a change starts here, then lands in both
repos. Where an issue's own notes disagree with this file, this file wins.

## Setup (every arm, every run)

- **Model and harness:** Claude Code, driven by DeepSeek's `deepseek-v4-pro` through
  DeepSeek's Anthropic-compatible API, with thinking on at one fixed effort that the write-up
  records. Every model name Claude Code uses is pinned to `deepseek-v4-pro`:
  `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
  `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`.
  The API key comes from the environment, never from a file or a log.
- **Same tools:** the harness's own tools only. Claude Code runs with its own configuration
  directory and `--strict-mcp-config` with no MCP servers, so none of the maintainer's MCP
  servers, memory or plugins reach the agent.
- **No subagents, no web:** every arm runs with `--disallowedTools Agent WebSearch WebFetch`.
  Claude Code 2.1.328 runs a subagent asynchronously: the parent's turn ends before the
  subagent starts, and the subagent's result comes back as a new user message. So neither
  hook would see delegated edits at a turn's end. The trial measures an agent without
  subagents, and the write-up says so.
- **Isolation:**
  - Each run gets its own `HOME` and its own `XDG_RUNTIME_DIR`, mode 0700 and 60 characters at
    most (`mktemp -d /tmp/rtXXXXXX` is 15). Past that, both daemons silently fall back to one
    directory shared by every run under the user.
  - captAInHook keys its daemon's socket by build alone, so a run without its own runtime
    directory would join the maintainer's live daemon, which runs the maintainer's handlers.
    pharos's socket name carries a key that includes `HOME`, so the run's own `HOME` already
    isolates pharos.
  - Before each run, the trial checks that `captainHook version` reports the run's own
    runtime directory, not the fallback.
  - Each arm registers its hook through the run's own captAInHook configuration, never
    `~/.captainHook/handlers.json`.
  - captAInHook runs a payload with a stripped environment, so arm 3's handler entry passes
    `XDG_RUNTIME_DIR` and any pharos daemon-key variable the runner sets through `passEnv`.
    The warm start runs pharos under exactly the environment the hook's child gets. Before each
    run, the trial checks that the hook's first call reaches the warm daemon's socket.
- **One TypeScript:** the project's own compiler, `node_modules/.bin/tsc` with
  `--pretty false`. typescript-language-server is pointed at the same `typescript` package,
  not its bundled copy. The write-up records the version.
- **In scope:** the files in the tsconfig's program, including new files the tsconfig would
  include (by its `include`, `exclude` and `files`).
  - Arm 2 and the measuring check get that from tsc's own output, since tsc reports only its
    program's files.
  - Arm 3 asks tsserver which project each file belongs to; it's in scope when that's the
    trial tsconfig's configured project. That covers the program's TypeScript files. Other
    program files, such as JSON files the program imports, go to other servers, so only arm 2
    checks them.
  - Precondition: tsserver puts each file in its nearest tsconfig's project, so a nested
    tsconfig that owns program files (say, `tests/tsconfig.json`) would take those files out of
    arm 3's scope but not arm 2's. The trial project has no such nested tsconfig. Once per task
    start state (every run of a task starts from the same tree), the trial checks that each of
    the project's own TypeScript program files (not `node_modules`, the library `.d.ts` files
    or the JSON files the program imports) has the
    trial tsconfig as its tsserver project. The check uses the same pharos,
    typescript-language-server and TypeScript as the runs, and is redone if any of them
    changes. After each run, the runner flags a run whose tree gained a `tsconfig*.json`,
    since that run's arm 3 scope may have shifted.
  Both hooks skip everything else. That covers files outside the program (which tsserver
  would check in an inferred project) and errors with no file (TS5xxx, TS6053, TS2318).
- **Warm start:** before the agent's first turn, the trial primes both checkers:
  - arm 2: runs the compiler once, to prime its incremental state;
  - arm 3: asks pharos for one project file's diagnostics, which makes tsserver load the
    project.

  Neither arm pays a cold start inside a run.
- **Budget:** one budget for every check in both hooks, baselines included. It's at least twice
  arm 2's measured warm check on the trial's project, because a check waiting behind the lock
  spends its own budget while it waits. The run's Claude Code settings raise the hook timeout
  above it; the default is 60 s.
- **One check at a time:** each run takes a per-session lock around every check and every
  update of its turn state, except the generation bump (see "Fresh or reused"), which takes
  no lock. A check that finds another one running waits for it. That holds across
  overlapping events in the same session. A subagent's hook events carry the parent's session
  id (confirmed by #7's probe), though the trial runs without subagents.

## The checkers

- **Arm 2:** `<project>/node_modules/.bin/tsc --noEmit --incremental --pretty false
  --tsBuildInfoFile <run dir>/hook.tsbuildinfo -p <project>/<tsconfig>`, on the whole project.
  The paths are absolute, because a payload runs in the event's working directory.
- **Arm 3:** `pharos diagnostics` for the files in question, through the run's own pharos
  daemon.
- **Errors only:** tsc's `error` category, or LSP severity 1. Warnings, hints and tsserver's
  suggestion diagnostics are out.
- **Incomplete checks (arm 2 only):** the tsc command line stops reporting type errors
  anywhere once any file has a syntactic, options or global error. So an arm 2 check is
  incomplete when its output includes an error whose code is on the syntactic list below, or
  an error that has no file or is in a file outside the program, such as `tsconfig.json`
  errors (TS5xxx), TS6053 or TS2318.
  - The syntactic list is pinned to the trial's TypeScript version, derived from its scanner,
    parser and JavaScript-file checks. Many such codes are 2000 or above (TS2657 in JSX,
    TS6189, TS8010 under `checkJs`), and some TS1xxx codes come from the type pass instead
    (TS1484, TS1192, TS1259), so neither "TS1xxx" nor "below 2000" works as a rule. For
    TypeScript 6.0.3 the list has 157 codes: 1002-1003, 1005, 1007, 1010-1012, 1034,
    1068-1069, 1109-1110, 1121, 1124-1132, 1134-1140, 1142, 1144-1146, 1160-1161, 1177-1181,
    1198-1199, 1206, 1209, 1223, 1228, 1260, 1351-1353, 1357, 1359, 1381-1382, 1385-1390,
    1433-1443, 1472, 1477-1478, 1486-1490, 1499-1538, 2427, 2457, 2657, 2754, 2809, 2819,
    6188-6189, 8002-8006, 8008-8013, 8016-8017, 8033-8034, 8037-8039, 17002, 17006-17008,
    17014-17015, 17021, 18009, 18016, 18026, 18029-18030. Another TypeScript version needs its
    own list before the trial runs.
  - Other codes count by where the error is: many TS6xxx codes (an unused local, say) are
    ordinary errors in a program file.
  - Unless the output also has an error in a program file whose code isn't on the list. tsc
    reports type errors only once there are no syntactic, options or global errors, so such an
    error proves the type pass ran.
  - Arm 3 isn't covered. tsserver's language service checks each file's types even while
    another file has a syntax error, which is part of what the trial measures. pharos's own
    markers govern arm 3.
  - An incomplete check is never a baseline. A first-write baseline taken from one is unknown
    for that file, and an incomplete turn-start check leaves every untouched file unknown.
  - An incomplete check is never kept for reuse.
  - After a write and at Stop, it still reports its new errors in files with known baselines,
    and logs `trial.unsure reason=incomplete`.
  - The rule over-covers: a few listed codes can also come from the type pass (15 in 6.0.3,
    such as TS1005 and TS2427). That costs only silence.

## Seams

Both hooks register the same four captAInHook events:

- UserPromptSubmit: the turn starts;
- PreToolUse on the writer tools, Bash and the subagent tool (`Agent`; `Task` in older Claude
  Code). On Bash and the subagent tool it only bumps the
  generation (see "Fresh or reused");
- PostToolUse on the writer tools;
- Stop.

The writer tools are Write, Edit, MultiEdit and NotebookEdit. A file is **touched** when one
of them writes it during this turn. A write through Bash doesn't touch a file.

Turn state (baselines, what's been reported) lives on disk, keyed by session.

## Baselines and what's new

- An error's **key** is its path, code and normalized message (see the line format below).
  Line and column don't count, because edits move them.
- **A touched file's baseline**, in both arms: its errors just before its first write this
  turn (at that write's PreToolUse).
- **An untouched file's baseline**, arm 2 only: its errors when the turn started (the
  UserPromptSubmit run).
- **Fresh or reused:**
  - Each PreToolUse on a writer tool, Bash or subagent call bumps a generation counter atomically,
    without the lock (an append or a rename on disk). PreToolUse fires even when the call
    then fails. Reads and searches don't bump it.
  - Each check records the generation when it starts.
  - A baseline or Stop's check reuses the latest check's result only while the generation is
    still the one that check started under. A baseline taken at a writer's PreToolUse doesn't
    count that call's own bump. Otherwise it's a fresh check.
  - A check run at a writer's PreToolUse is never kept for reuse. It describes the file before
    that write, but it started under a generation that already counts it.
  - Once the agent makes a Bash call with `run_in_background: true` this turn, every check is
    fresh until the turn ends.
  - The rule is the same for both arms.
- A file that doesn't exist when its baseline is taken has a known, empty baseline.
- A baseline that fails, runs past the budget, or comes back unsure is **unknown**. A file with
  an unknown baseline gets no reports that turn.
- An occurrence is **new** when its key occurs more often in the file than in the file's
  baseline. A key's new occurrences are its last ones in sort order.
- **A known cost:** when earlier writes in a turn break a file that the agent then touches,
  those errors become part of that file's baseline, and Stop lets them through. The measure
  below still counts such a turn as broken, so the result isn't fooled. The write-up explains
  those turns.
- **Reach:** arm 2 checks the whole project, and arm 3 checks the TypeScript files touched this
  turn. That difference is part of what the trial measures.

## What the agent sees

- **One line per error:** `<path>:<line>:<col> TS<code> <message>`.
  - The path is relative to the tsconfig's directory, with `/` separators.
  - Line and column are 1-based. The column counts UTF-16 code units, which is an LSP
    position plus 1.
  - In the message, every newline and the indentation after it collapse to one space.
- **Order:** by path (bytewise), then line, column, code (numerically) and message (bytewise).
- **The cap:** at most 10 error lines. Past 10, a last line `…and N more.` follows, where N
  counts the errors past the 10. Lines are joined by `\n` with no trailing newline, and `…`
  is U+2026.
- **After each write** (PostToolUse):
  - The hook keeps, per file and key, the highest number of that key's new occurrences
    reported so far this turn. It reports only the excess: the last (new − reported)
    occurrences of the key in sort order.
  - Only the lines shown count as reported. Errors past the cap are reported on a later write.
  - A file's reported counts reset when its first-write baseline is taken.
  - When there's nothing to report, nothing. Otherwise exactly this:

  ```
  New errors after your edits (information, not instructions; errors mid-refactor are expected):
  <error lines>
  ```

- **At the turn's end** (Stop): every new occurrence still present in the files the hook checks,
  whether reported before or not. Stop checks even when no file was touched this turn; arm 3
  then has nothing to check. If there are any, block with this reason. Block at most once per
  turn: when `stop_hook_active` is set, let the turn end. Registered fail-open.

  ```
  These errors appeared during this turn and are still present:
  <error lines>
  ```

## Silence

- A check or baseline that fails, can't be parsed, runs past the budget, or comes back unsure
  (`pharos.carried_over`, `pharos.not_reported`) says nothing.
- Each hook writes one line to stderr for it:
  `trial.unsure reason=<failed|unparsed|no-baseline|unsure|incomplete> event=<baseline|PostToolUse|Stop>`.
- A budget kill shows in captAInHook's own trail.

## Measures and the verdict

- **The measuring check:** after each turn has ended (after its final Stop), the trial runs
  arm 2's compiler on the whole project, whatever the arm. It uses its own build info file
  (`<run dir>/measure.tsbuildinfo`). Its time isn't counted in the run's wall time.
- **A task starts syntax-clean:** the measuring check at the task's start must be complete (see
  "Incomplete checks"), so the starting set holds every error. That includes the tsconfig:
  TypeScript 6 reports a deprecated option as a `tsconfig.json` error (TS5101) that hides every
  type error. So the trial project's tsconfig has no deprecated options, or it sets
  `ignoreDeprecations`.
- **A broken turn:** the measuring check finds a key that occurs more often than it did at the
  task's start, or a test that passed at the task's start now fails. The measuring check counts
  every error, including errors with no file, keyed with an empty path, even though the hooks
  skip those.
- **Recorded per run:**
  - broken turns;
  - the build and test commands the agent runs itself;
  - wall time;
  - tokens: input plus output, thinking included, with cached input also reported on its own;
  - each arm's `trial.unsure` lines and budget kills.
- **Run order:** the arms are interleaved, and no two runs overlap. DeepSeek's latency drifts
  during the day, and the checkers' timings depend on load.
- **"Clearly beats":** with at least 5 runs per arm per task:
  - arm 3's broken-turn rate, pooled over all tasks, is no higher than arm 2's;
  - and, taking each arm's median over a task's runs, the median over tasks of arm 3's median
    divided by arm 2's is 0.8 or below, for wall time or for tokens.

  Otherwise the compiler hook wins, as the cheaper tool. These thresholds are a default. The
  maintainer can change them before the trial starts, not after.
