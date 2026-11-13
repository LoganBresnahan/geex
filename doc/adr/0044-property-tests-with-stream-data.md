# ADR-0044: Property tests with StreamData

- **Status:** Accepted 2026-11-09. The maintainer asked for property tests to help the agentic
  workflow, naming StreamData; the rest was proposed in the same conversation, drafted here at
  the maintainer's request, and accepted by the maintainer the same day. **Slices 1–3
  built 2026-11-09** ([testing.md](../testing.md) 2026-11-09); amended below (§3, §5, §8) where
  building them changed the design. Slice 2 found and fixed BUG-8. A verify pass the same day
  (session geex-d3) found BUG-8's fix incomplete, three weak properties and some overclaiming;
  all addressed below ("the verify pass"), and BUG-9 logged. §8.4's slices wait for their
  consumers. **Amended 2026-11-12:** the shared generators are the default for any property over text, and carry invalid bytes, more awkward characters and long lines.
- **Date:** 2026-11-09
- **Relates to:** [ADR-0006](0006-elixir-not-gleam.md) (which promised property tests for the
  boundary), [ADR-0020](0020-diff-edit-tool.md) (the edit tool's grapheme property),
  [ADR-0027](0027-grid-command-addressing.md) (width renders, never addresses),
  [ADR-0032](0032-listener-first-agent-integration.md) and
  [ADR-0033](0033-durable-ledger.md) (attestation matches exact hashes; the chain rule),
  [ADR-0034](0034-panes-tree-edits-hold.md) (merging a buffer that is behind), the sacred
  invariants "the pure core stays pure and replay stays deterministic" and "never infer an actor"
- **Amends:** [ADR-0006](0006-elixir-not-gleam.md) (its "property tests" consequence is met
  by this ADR; Dialyzer is still not adopted), [testing.md](../testing.md) § Strategy layer 2
  (rewritten when slice 1 lands)

## Context

geex already has property tests, written by hand. Seven test files run a fixed-seed `:rand`
loop over a pure function and check a law on every case:

| File | Law |
|---|---|
| `test/geex/edit/resolve_test.exs` | resolve + `Doc.replace` equals a naive `String.replace` |
| `test/geex/edit/line_diff_test.exs` | applying `spans(old, new)` to `old` gives `new` |
| `test/geex/edit/merge_test.exs` | the merge identities (no change on one side takes the other) |
| `test/geex/history_test.exs` | random dispatch/undo/redo, then replay rebuilds text and blame |
| `test/geex/edits_test.exs` | `Edits.fold/1` over loaded rows equals adding them one by one |
| `test/geex/ledger_test.exs` | after random edits, undos, outside writes, credits and saves, the restored ledger equals the live buffer's history |
| `test/geex/highlight/span_index_test.exs` | the span index agrees with a linear scan |

The verification log noted the gap on 2026-06 (ADR-0020's entry): "a generated (vs
seeded-random) property harness (no stream_data dep)". These loops have three weaknesses:

1. **No shrinking.** A failure prints whatever random case broke: a 7-line string, or the
   state after 300 steps. Someone has to reduce it by hand before they can see the bug.
2. **Always the same cases.** A fixed seed checks the same 300 inputs on every run, forever. A
   bug outside them is never found.
3. **No shared vocabulary.** Each file has its own small `pool` of awkward strings. The awkward
   cases (CRLF, a lone `\r`, combining marks, ZWJ emoji, wide CJK, no trailing newline) are
   picked again per file, and some files miss some of them.

The maintainer's reason is the agentic workflow, in two senses:

- **Agents working on geex.** An agent writing code also writes the example tests, and it
  writes them for the cases it thought of: the same cases its code handles. A property states
  what must always hold and lets a generator look for the case nobody thought of. A shrunk
  counterexample is something an agent can act on directly; a large random one invites guessing.
- **Agents working through geex.** Since ADR-0032, an agent's edit reaches geex as a change on
  disk, which goes through reconcile, `LineDiff`, `Merge`, attestation matching and `Blame`. That
  path is pure, so property tests suit it well, and two of its laws are sacred invariants
  (deterministic replay; an actor only from an exact hash match).

## Decision

### 1. StreamData, as a test-only dependency

- `{:stream_data, "~> 1.x", only: :test}`, pinned to the current 1.x release when slice 1 lands.
  (The machine's hex cache holds 0.6.0, which is too old.) It is maintained by the Elixir core
  team, Apache-2.0 like geex, and integrates with ExUnit (`use ExUnitProperties`, `check all`).
- `only: :test` keeps it out of the release: `mix geex.deploy` and `release.yml` build in
  `prod`, so the tarball and its native-library check are unchanged.

### 2. Properties test the pure core only

- They go where invariant 3 already makes functions `value -> value`: `Dispatch.apply_command/2`
  and `replay/2`, `History`, `Blame`, `Coord`, `Width`, `Selection`, `Fuzzy`, and the `Edit.*`
  and `Ledger.Spool` functions.
- Processes stay example-tested. When a law lives in a process, the slice that tests it first
  extracts the law into a pure function, and the process calls that function. The first case
  is `Buffer`'s private `matches?/2` (the attestation hash check).

### 3. One shared generator module

- `test/support/gen.ex`, `Geex.Gen` (`test/support` is already on the test `elixirc_paths`).
  It defines generators for graphemes and lines weighted toward the awkward cases above, for
  texts (any line count, trailing newline or not, LF or CRLF), for documents and positions in
  them, for edit operations, and for actors and `meta`.
- Each test's own `pool` goes away. A new awkward case is added once, in `Geex.Gen`, and every
  property picks it up.

### 4. A property failure is a bug, never a flake

- The ExUnit seed drives StreamData, so every run explores new cases and `mix test --seed N`
  replays a failure exactly. The two runs required before shipping are two different seeds,
  which is wanted.
- Never re-run to get green. The shrunk counterexample becomes an **example test** next to the
  property, so it stays covered after the seed moves on. If the bug isn't fixed in the same
  commit, it goes in [bugs.md](../bugs.md) with the counterexample and the seed.

### 5. A budget that keeps the suite fast

- StreamData's defaults (100 runs, small sizes). Slice 1 measures the cost; the target is that
  the property layer adds no more than ~2 s to the ~13 s suite.
- `GEEX_PROPERTY_RUNS=N mix test` raises `max_runs` for every property, for a deep run before a
  release or after a change to the reconcile path. It is never set in CI's default run.

### 6. Model-based tests without a stateful library

- StreamData has no stateful mode. geex doesn't need one: generate a **list of operations**,
  fold it through the real pure function and through a naive model, and compare. For example,
  `History` against a plain stack of texts, or `Doc` edits against `String` functions. Shrinking
  works on the list, so a failure shrinks to the fewest operations that still break it.
  `history_test.exs` already has this shape.

### 7. The oracle is never the code under test

- Invariant 3 forbids regenerating the golden cassette from the replay under test. The same rule
  applies here: a property compares against a law (round-trip, identity, commutation) or an
  independent naive implementation, never against output of the function being tested.
- Properties don't replace the §15c golden cassette. The cassette pins a recorded history's
  exact result; properties check laws over histories nobody recorded. Both stay.
- Where `git merge-file` is a useful second implementation (comparing it with `Merge`), the
  test is tagged and left out when git is missing, the way `test_helper.exs` handles
  `inotifywait`.

### 8. The slices

1. **Move over what exists.** Add the dependency and `Geex.Gen`, and rewrite six of the seven
   seeded loops as `check all` properties stating the same laws. No new laws. Measure the time.
   The ledger loop stays as it is: it drives a live `Buffer` and real files, so under §2 it
   becomes a property only once its live side is a pure fold (`History` over the generated
   operations) compared with `Ledger.Restore`.
2. **The attestation path** (invariant 6). `Ledger.Spool.chain/3` credits a chain only when the
   hashes link exactly from `synced` (or its LF form) to the disk, and changing the disk by one
   byte gives `:none`. `Buffer`'s hash check, extracted (§2), holds for any attestation whose
   `sha256` or `before` differs. `Blame.relabel/3` changes only its own group's lines, and every
   actor in a blame appears in the history.
3. **Addressing and the parse round-trip.** `Width.col_at_display/2` never lands inside a
   grapheme, and `Coord.to_span/2` stays inside the document (ADR-0027). A minibuffer string and
   the matching MCP arguments parse to the same `%Command{}` (testing.md's original layer-2
   promise). That tests the frozen MCP surface without adding to it.
4. **Later, each when its first real consumer appears** (the named-consumer rule): the markdown
   layout's source-line anchors, `Fuzzy`'s ranking laws, `Selection`.

### 9. A convention for agents (and humans)

CLAUDE.md's "Conventions when you touch code" gains one line: *a pure function with a law gets
a property; a shrunk counterexample gets an example test.* `/shipshape` doesn't enforce it.

## Alternatives considered

- **Keep the seeded loops.** No dependency, but no shrinking and the same cases forever:
  the three weaknesses in Context stay.
- **PropCheck (PropEr).** It has real stateful testing, but PropEr is GPL-3.0, and §6 covers
  what geex would use it for. Test-only use would not reach the release, but a GPL dependency
  in an Apache-2.0 tree is still a question nobody needs to answer.
- **Properties over processes too** (`Buffer`, `Reconcile`, the loop). Timing makes them slow
  and flaky. §2's rule (extract the law, test it pure) gets the coverage without the timing.

## Consequences

- One new test-only dependency and its lock entry. The release, the launcher and the
  native-library check are unchanged.
- Each run checks new cases. A red run can be a real, old bug that a previous seed missed. §4
  says what to do: keep the counterexample as an example test, never re-run.
- The suite gets slightly slower (§5 bounds it).
- A failure arrives shrunk, which helps whoever fixes it, agent or human.
- `Buffer.matches?/2` and any later law found in a process become public pure functions,
  which widens the pure core slightly.
- ADR-0006's Dialyzer half is still not done. It is out of scope here.

## Amendment — 2026-11-09: what slice 1 changed

- **§5: every generated list has a `max_length`.** StreamData's generation size rises by one per
  run with no ceiling, and a list without a bound is as long as the size allows. At the default
  100 runs that is harmless; the first `GEEX_PROPERTY_RUNS=10000` run made lists of thousands of
  operations and rows, and the history and edits properties timed out. A bound on the list (100
  operations, 60 rows, 300 spans, 20 windows, 8 lines of text) keeps the inputs the same shape
  however many runs are asked for. `max_generation_size` would do it too, but only as an option
  on each property, and properties set no options (§5).
- **§3: `Geex.Gen` holds only what two or more properties share** (the named-consumer rule):
  `piece/0`, `fragment/1`, `line/0`, `text/1`, `insertion/0`, `actor/0`. Generators one test
  uses stay in that test: the history's operations, the edits list's rows, the highlighter's
  spans. The history's operation list moves to `Geex.Gen` when the ledger property (§8.1's
  deferred loop) needs the same one.
- **The vacuity guard.** The resolve property counts the runs that reach the exact tier and
  requires more than a fifth of `max_runs` (measured: ~72%), as the seeded loop required more
  than 50 of 400.
- **Formatting.** geex has no `.formatter.exs`, so `mix format` writes `check all(...)` and
  `gen all(...)` with parentheses. Left so: adding a formatter config would reformat files this
  ADR doesn't touch.

## Amendment — 2026-11-09: slice 2, the attestation path

- **`Geex.Attest.matches?/2`** is `Buffer`'s hash check, extracted (§2's first case). Its
  property starts from contents: the stamp is the one `Reconcile.external_commands/4` records
  for `baseline` to `disk`, the attestation hashes what a hook might report (the true text, its
  LF form, a byte changed or added, another text), and they must match exactly when the after is
  the disk and the before is the baseline or its LF form.
- **`Ledger.Spool.chain/3`** is checked against a naive oracle (§7): the longest exact chain by
  dynamic programming over the entries in time order. A credit must also be in time order, link
  exactly from the synced text (or its LF form) to the disk, come from one session, and name the
  last write's turn and tool call. A second property states §8.2's line: a chain that explains
  the disk explains nothing once the disk differs by one byte. Writes mostly follow on from the
  previous one, so about 30% of runs credit something and 11–17% credit a chain of two or more.
- **A scenario carries its story.** A generator whose values are hashes also returns the same
  inputs as text (`"u1 s1: \"a\" -> \"\""`), so a shrunk counterexample reads as contents.
  Kept for every later property over hashed or encoded inputs.
- **One law added to the list:** "a reconcile group's commands carry one actor" (with "the blame
  names only recorded writers"), over a history whose transitions now include reconcile groups,
  attestations taken as `Buffer` takes them, and saves. On the first of five runs it found
  **BUG-8**: an attestation landing while part of its group was undone left the redone part
  `:external` (the law alone catches it on about 3 seeds in 10; the verify pass added a targeted
  property, and completed the fix for a fully undone group). Fixed for the partly undone case
  in the same commit (`History.attest/3` relabels the redo stack too, [ADR-0032](0032-listener-first-agent-integration.md)'s
  2026-11-09 amendment); the shrunk counterexample is an example test (§4).
- **Teeth.** A bug planted in each function under test was caught and shrunk: `chain/3` ignoring
  the session (two writes, two sessions, `"" -> "a" -> ""`), and `matches?/2` ignoring `before`
  (a before one byte off).

## Amendment — 2026-11-09: slice 3, addressing and the parse round-trip

- **Two width walks, pinned together** (three, after the verify pass: the painter too). Besides `Width.col_at_display/2` against a naive
  one-entry-per-column model, a property checks it against the draw walk, `Loop.cursor_xy/3`:
  the column a grapheme's cursor is drawn at addresses that grapheme. A click or a grid line can
  only address what was drawn there if the two agree (ADR-0027 §2).
- **`Coord.to_span/2`** is checked through `Doc.slice`: the span's text is exactly the graphemes
  between the ends, inclusive, by a walk over `{y, x}` coordinates, with ADR-0027 §7's clamping
  stated in coordinates (a line's newline at `x = length + 1`).
- **What "the minibuffer/MCP round-trip" became.** The minibuffer has no typed grammar for the
  edit commands (its verbs are actions), so §8.3's law is stated over what each surface really
  hands the one parser: native atom-keyed values (the keymap), raw strings (`Type.cast/2`'s typed
  form), and JSON decoded as `tools/call` delivers it. It runs over every command in the running
  `CommandRegistry`, so a new command is covered on registration, and a new argument type without
  a generator fails the property by name. Where both surfaces do have a typed form, the grid, the
  human's `Verbs.parse_grid/1` and the agent's `goto`/`copy` field-specs must parse the same text
  to the same coordinates and refuse the same lines.
- **Teeth.** Planted bugs in `to_span/2`, `col_at_display/2`, `cursor_xy/3` and
  `Type.cast(:string, _)` were each caught and shrunk to a one-line case. The slice found nothing
  in the code.

## Amendment — 2026-11-09: the verify pass

A second session (geex-d3) adversarially verified slices 1–3 the same day, planting bugs and
measuring what the properties catch. What it found, and what changed:

- **BUG-8 was fixed only for a partly undone group.** With every hunk undone, a late attestation
  matched nothing and was lost. Completed: an attestation may match the newest undone group, then
  the newest applied one ([ADR-0032](0032-listener-first-agent-integration.md)'s 2026-11-09
  amendment, revised). The history property's model missed it because its attestation step
  copied the old rule; it now copies the new one. geex-d3's recheck then found the first version
  of that fix stopping at the first matching group even when it was already attested, losing a
  credit the old rule gave (an attested undone group shadowing an applied one with the same
  hashes); `Buffer.attest/2` now credits the first match still unattested, with the case as an
  example test. No property generates two groups with the same hashes, which is why none caught
  it. A **targeted property** (a multi-hunk group,
  any number of hunks undone, an attestation, any number redone: the whole group credited, and
  attestable throughout) catches either half of the fix removed on 10 seeds in 10 at 100 runs,
  where the general "one actor" law caught it on about 3.
- **The spool property never varied the harness**, so a chain keyed by session alone passed
  every test. Writers now include another harness reusing a session id, and the oracle returns
  the very chain `chain/3` must credit (ties broken by the first found, as documented), not just
  its length. Keying by session alone, and ties going to the last found, each fail on 5 seeds in 5.
- **`Blame.relabel/3`'s property restated the function** (§7). Replaced by a law the function
  doesn't define: relabelling a replayed blame equals replaying the commands with the group's
  actors relabelled.
- **The grid property almost never generated an empty range** (two uniform points rarely
  coincide): a `Coord.parse` accepting one passed 20 seeds in 20. The second point is now
  sometimes the first (caught on 10 in 10); `cut` and the refusal of an invalid bare coordinate
  are covered. Both surfaces call `Coord.parse/1`, so the property mostly guards what each does
  around it; said so in the test.
- **Three width walks, not two.** The painter (`Highlight.Paint.to_screen/9` through
  `Screen.put_grapheme/4`) now joins the property: each grapheme drawn in the columns
  `col_at_display/2` gives it.
- **Slice 1's default runs are smaller than the loops they replaced.** At 100 runs a list is
  capped by the generation size (at most ~100), not its `max_length`: SpanIndex had 2,000 spans
  over 10,000 bytes, now at most 100 over ~2,300; the history loop was one 300-operation run, now
  up to ~100 operations per run over 100 runs; resolve, line-diff and merge drop from 400/500/300
  cases to 100. The laws are the same and the inputs more varied; depth comes from
  `GEEX_PROPERTY_RUNS`. A trade-off, stated here rather than hidden in "the same laws".
- **BUG-9**, older than this ADR: an attestation doesn't relabel a checkpoint's `base_blame`.
  Logged in [bugs.md](../bugs.md), not fixed.

## Amendment — 2026-11-12: the shared generators by default, wider

**Context.** The reviews of ADR-0052 and the long-line work found bugs the suite's properties
missed because their generators never made the input: the editing keys' move property had no
`\r`, the long-line properties no invalid bytes, and a paint property's failure surfaced only in a
deep run. Several properties carried their own small generators beside `Geex.Gen`. The
maintainer, 2026-11-12, of the proposals that followed: "i agree with just 2", putting the awkward
inputs in the shared generators.

**Decision.**

1. **`Geex.Gen` is the default** for any property over text. A property with a generator of its
   own for the cases its law is about (indents, comment markers, brackets, a marker's bytes) mixes
   in `Geex.Gen.line/1` or `piece/1` beside it, so the awkward cases still reach it.
2. **The awkward set grows:** a keycap, VS16 alone, Prepend characters (U+0600, U+0D4E), and
   whitespace that isn't a space or a tab (no-break space, form feed, vertical tab, U+3000), so a
   rule about "blank" or "whitespace" has to say which it means.
3. **Invalid UTF-8, by default, rarely** (`Geex.Gen.invalid_byte/0`: a continuation byte, a Latin-1
   `é`, a truncated lead, `0xC0`, `0xFF`; each one grapheme, BUG-15). A property whose law or
   oracle can't hold for them passes `invalid: false` and says why in a comment: an MCP argument's
   JSON round trip (JSON strings are UTF-8), the reference paint from before BUG-15.
4. **Long lines in a deep run** (`Geex.Gen.long_line/1`: past 4 KB, ASCII or not, words, gaps
   and brackets, now and then a word or a gap longer than a window), by default only when
   `max_runs` is 1,000 or more (`GEEX_PROPERTY_RUNS`), so the default `mix test` stays quick; a
   property asks for them always with `long: true`.
5. **Oracles say what text they handle.** A property's own model reads graphemes with
   `Geex.Text`, not `String`, so it doesn't raise where the code under test doesn't. Where a law
   genuinely excludes a case, the property says so in a comment and a guard, never by narrowing
   the generator silently: a line ending in `\r\r` (which `\r` is the ending can't be told), a
   move that joins or parts graphemes at its seams (bytes compared, positions only where the
   segmentation is unchanged).

**Consequences.** The wider generators found a crash and a lost character, fixed with them:
`Alt+\\` reading forward past an emoji before an invalid byte (`Keymap`'s bracket search still
stepped with `String.next_grapheme/1`); and uncommenting a line whose text starts with a combining
mark or a lone VS16, which took the mark with the marker's space (the space and the mark are one
grapheme). The deep run takes a little longer for the long lines.

## See

[testing.md](../testing.md) § Strategy and its 2026-06 edit-tool entry ("not tested / deferred");
the seven files in Context; [ADR-0020](0020-diff-edit-tool.md)'s risk list (the first seeded
property).
