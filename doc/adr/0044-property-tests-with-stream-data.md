# ADR-0044: Property tests with StreamData

- **Status:** Accepted 2026-11-09. The maintainer asked for property tests to help the agentic
  workflow, naming StreamData; the rest was proposed in the same conversation, drafted here at
  the maintainer's request, and accepted by the maintainer the same day. **Slice 1 built
  2026-11-09** ([testing.md](../testing.md) 2026-11-09); amended below (§3, §5) where building it
  changed the design.
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

## See

[testing.md](../testing.md) § Strategy and its 2026-06 edit-tool entry ("not tested / deferred");
the seven files in Context; [ADR-0020](0020-diff-edit-tool.md)'s risk list (the first seeded
property).
