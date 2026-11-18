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
- **In scope:** the files in the tsconfig's program, listed at warm start with
  `tsc -p <tsconfig> --listFilesOnly`, plus new files the tsconfig would include (by its
  `include`, `exclude` and `files`).
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
  overlapping events and parallel subagents in the same session. The contract assumes a
  subagent's hook events carry the parent's session id; #7's dry run confirms it.

## The checkers

- **Arm 2:** `<project>/node_modules/.bin/tsc --noEmit --incremental --pretty false
  --tsBuildInfoFile <run dir>/hook.tsbuildinfo -p <project>/<tsconfig>`, on the whole project.
  The paths are absolute, because a payload runs in the event's working directory.
- **Arm 3:** `pharos diagnostics` for the files in question, through the run's own pharos
  daemon.
- **Errors only:** tsc's `error` category, or LSP severity 1. Warnings, hints and tsserver's
  suggestion diagnostics are out.

## Seams

Both hooks register the same four captAInHook events:

- UserPromptSubmit: the turn starts;
- PreToolUse on the writer tools, Bash and Task. On Bash and Task it only bumps the
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
  - Each PreToolUse on a writer tool, Bash or Task call bumps a generation counter atomically,
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
- **Reach:** arm 2 checks the whole project, and arm 3 checks the files touched this turn. That
  difference is part of what the trial measures.

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
  whether reported before or not. If there are any, block with this reason. Block at most once
  per turn: when `stop_hook_active` is set, let the turn end. Registered fail-open.

  ```
  These errors appeared during this turn and are still present:
  <error lines>
  ```

## Silence

- A check or baseline that fails, can't be parsed, runs past the budget, or comes back unsure
  (`pharos.carried_over`, `pharos.not_reported`) says nothing.
- Each hook writes one line to stderr for it:
  `trial.unsure reason=<failed|unparsed|no-baseline|unsure> event=<baseline|PostToolUse|Stop>`.
- A budget kill shows in captAInHook's own trail.

## Measures and the verdict

- **The measuring check:** after each turn has ended (after its final Stop), the trial runs
  arm 2's compiler on the whole project, whatever the arm. It uses its own build info file
  (`<run dir>/measure.tsbuildinfo`). Its time isn't counted in the run's wall time.
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
