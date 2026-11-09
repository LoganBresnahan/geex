# geex — Known bugs (triage shelf)

Bugs found but deliberately **not fixed yet** — captured so they aren't lost and so a fix
starts from a real root cause, not a guess. Each entry: symptom, status, the *verified*
cause, the recommended fix, and what was ruled out. When one is fixed, move it to
[testing.md](testing.md) with the verification.

---

## BUG-9 — An attestation doesn't relabel the blame a compacted ledger's checkpoint carries

- **Status:** open, found 2026-11-09 by a verify pass over ADR-0044 (session geex-d3) and
  reproduced in `History` directly. Very rare: it needs a compaction that splits a reconcile
  group (some of its commands folded into the checkpoint, some still recorded), a restart, then
  a late attestation for that group.
- **Symptom:** `History.from_checkpoint("a\nb", [{:external, 7}, {:external, 7}], "a\nb", 8)`,
  a command of group 7 on line 1, `attest(h, 7, agent)`: both lines show the agent. Then any
  edit and its undo: line 0 shows `{:external, 7}` again, and `unattested?(h, 7)` is false, so a
  repeat attestation is ignored and the line stays an outside change.
- **Verified cause:** `History.attest/3` relabels `blame` and the commands but not `base_blame`;
  `undo/1` rebuilds the blame from `base_blame` plus the remaining commands
  (`Blame.replay(h.base, …, h.base_blame)`), so the checkpoint's lines of the group come back as
  they were.
- **Recommended fix:** `base_blame: Blame.relabel(h.base_blame, group, actor)` in
  `History.attest/3`, with the example above as a test. The ledger replays `{:attest, …}` through
  the same function, so restore stays equal to live.
- **Ruled out:** compaction itself (`Ledger.Compact` writes the blame it replayed, correctly).

---

## BUG-8 — A late attestation missed the undone hunks of its group  ✅ FIXED (2026-11-09)

- **Status:** **FIXED** 2026-11-09, in two steps. Found by the history property's new law, "a
  reconcile group's commands carry one actor" (ADR-0044 §8.2), on the first of five runs (the
  law alone catches it on about 3 seeds in 10 at 100 runs). Fixed for a **partly** undone group
  in the same commit (`ff1e66b`); a verify pass (session geex-d3) then found the **fully**
  undone case still open, fixed the same day; its recheck found the first version of that fix
  let an attested undone group shadow an applied one, also fixed. Verification is in the [testing.md](testing.md)
  2026-11-09 entries "property tests, slice 2" and "the verify pass".
- **Symptom (partly undone):** a reconcile group of two hunks; undo one; the attestation arrives
  and matches (the group's stamp is on the hunk still applied); redo. The redone hunk's line
  shows as an outside change while the rest of the group shows the agent, and a repeat
  attestation is ignored, because `History.unattested?/2` finds the group partly credited.
- **Symptom (fully undone):** undo both hunks before the attestation arrives: it is `:held` (no
  applied group matches), never links at the next fast-forward (the held entry starts from the
  text before the group, the chain from the disk after it), and is dropped; the redo brings both
  hunks back `:external`. ADR-0032 step (e)'s "an undone hunk loses its mark, and redo restores
  it" didn't hold after a late attestation in either case.
- **Verified cause:** `History.attest/3` mapped over `h.commands` only, so an undone hunk waited
  on `h.redo` with its old actor; and `Buffer.attest/2` matched only `History.newest_group/1`,
  which scans the applied commands, so a fully undone group wasn't attestable at all. The shrunk
  counterexample (partly undone): base `""`, the disk becomes `"a"` (group 1), then `"\na\n"`
  (group 2, two hunks), undo, attest group 2, redo: group 2's actors were `[:external, agent]`.
- **Fix:** `History.attest/3` relabels `h.redo` too; `History.attestable_groups/1` gives the
  stamps an attestation may match, the newest undone group first, then the newest applied one;
  `Buffer.attest/2` credits the first that matches and is still unattested, so an attested
  undone group with the same hashes doesn't shadow the applied one (the recheck's
  counterexample, now an example test) and nothing that matched before stops matching;
  `unattested?/2` counts undone commands. As before, only the newest write's group is tried
  among the undone ones: undo two groups in full, and a late attestation for the older is still
  held and lost, under ADR-0032's "only the newest group". The ledger replays `{:attest, group, actor}`
  through `History.attest/3`, so a restored history matches the live one. Ledgers written
  before the fix restore an attest-then-redo with the redone hunk credited, where the live
  session had left it `:external`: a correction. Examples in `history_test.exs` and
  `attest_test.exs`; a targeted property (below) catches either half of the fix removed on 10
  seeds in 10.
- **Ruled out:** the hashes. The attestation matched the stamp correctly.

---

## BUG-7 — After a terminal resize, stale text stays in the cells the new frame leaves blank  ✅ FIXED (2026-11-06)

- **Status:** **FIXED** 2026-11-06 on the branch `markdown-preview`, at the maintainer's word
  ("yeah fix bug 7 too"): `Renderer.handle_cast({:resize, …})` now resets the model to
  `Screen.new(0, 0)`. Verification is in the [testing.md](testing.md) 2026-11-06 entry "BUG-7:
  a resize redraws the whole screen". Found 2026-11-06 while dogfooding the markdown preview
  (ADR-0043 slice 5); not the preview's: main (`464bd3b`) did the same.
- **Symptom:** in tmux, `resize-window` from 120 to 96 columns leaves the old text in every cell
  the new frame draws blank, so rows read like `1 Agent intro line. line.` and
  `3 # Previewrtestw##est ##`. It stays until something draws over those cells; Esc or another
  repaint doesn't clear it. The log is clean.
- **Verified cause:** `Geex.Renderer.handle_cast({:resize, w, h}, …)` sets the model of the
  terminal to `Screen.new(w, h)`, a blank screen **of the new size**. The next flush's `diff/2`
  then sees equal dimensions, so it takes the incremental path: no `\e[2J`, and every cell blank
  in the new frame matches the blank model and isn't written. But the terminal isn't blank
  after a resize (tmux reflows what was there), so the old text stays in those cells. The
  moduledoc's own contract ("Dimension changes (initial flush, terminal resize) emit `\e[2J`") is
  what breaks.
- **Recommended fix:** reset the model to `Screen.new(0, 0)` on resize, as `init/1` does, so the
  next flush sees new dimensions and clears and redraws everything. Tried in a throwaway
  worktree of main: the same resize then draws a clean frame. A renderer test should assert that
  the flush after `resize/2` starts with `\e[2J`.
- **Ruled out:** tmux's window and pane really are 96 wide after the resize (`#{pane_width}`),
  and geex lays out at 96 (its tab bar's `×` is at the new right edge), so it isn't a missed
  SIGWINCH.

---

## BUG-6 — The installed binary carried every earlier geex release, the bundled grammars included  ✅ FIXED (2026-10-18)

- **Status:** **FIXED** 2026-10-18. `mix geex.deploy` removes `_build/prod/rel/geex` before
  building, and Burrito's working copy after. Verification is in the
  [testing.md](testing.md) 2026-10-18 entry "BUG-6: one release in the binary". Found by the
  coordinator session in the unpack of `0.1.0+1cbe3f34.89a87236`, the first "bare" binary.
- **Symptom:**
  - The unpack's `lib/` held 23 `geex-0.1.0+<sha>` application directories, one per deploy since
    the first (`.dirty` builds too). That is 46 MB of a ~114 MB unpack and a 22.3 MB binary,
    growing with each deploy.
  - Several still carried `priv/grammars/{elixir,json}` and `priv/themes/birds-of-paradise.json`.
    So the bare binary redistributed them, and without the NOTICE entries, which now name only
    the catalog and the test fixtures.
- **Verified cause:** `mix release` keeps the releases already in `_build/prod/rel/geex/{lib,
  releases}` beside a new one, and every build's version differs (it names the commits). Burrito
  packs the whole release directory. The boot script names one release, so the old ones were
  never loaded: a cost and a licence problem, not a correctness one.
- **Also found:** Burrito's working copy of each build, `/tmp/burrito_build_*` (~120 MB), was
  never removed: 15 from this one day's deploys. The deploy now removes the ones its build made,
  found by listing before and after, so another project's build isn't touched.

---

## BUG-5 — Flaky: the reconcile quiet-period test finds the buffer behind an *empty* file  ✅ FIXED (2026-10-18)

- **Status:** **FIXED** 2026-10-18: a test timing assumption, not a product bug. The cause and
  the verification are in the [testing.md](testing.md) 2026-10-18 entry "BUG-5: the
  quiet-period test assumed a deadline". `reconcile_test.exs:299` once found the buffer behind
  `""` inside its reconciler's 150 ms quiet period (seed 125550).
- **Verified cause:** the test's own reconciler, its quiet period running out as designed while
  the test process was descheduled past 150 ms. Reproduced under CPU load with the test alone.
  - A stall mid-`File.write!`, after the truncate and before the bytes, reads `""`: the first
    sighting.
  - A stall after both writes reads the final bytes: the reproduction (sha of "v2 done\n").
  - A probe in `Buffer.disk_changed/2` ruled out any other caller.
  - The suspect noted here before, `session_test`'s reconciler with a real inotify backend, is
    a hazard but not this cause. It is stubbed now too.

---

## BUG-4 — A deploy deletes the unpack a running geex runs from, and that geex crashes  ✅ FIXED (2026-10-18)

- **Status:** **FIXED** 2026-10-18. `mix geex.deploy` keeps any unpack a running process uses,
  and `geex.prev`'s. Verification is in the [testing.md](testing.md) 2026-10-18 entry "A deploy
  keeps the unpack a running geex uses (BUG-4)". Found by the coordinator session: the deploy
  of `dcce38b` crashed the maintainer's open `geex .`.
- **Symptom:** the maintainer's geex (`0.1.0+839c64cb`, started from the installed binary)
  died during a deploy. The terminal filled with "DEFAULT FORMATTER CRASHED" and the UI stopped
  answering. The VM was still alive and quit on SIGTERM, cleanly (discovery file removed, no
  ledger locks left).
- **Verified cause:** the deploy's prune (`prune_unpacks/1`) removed every `geex_erts-*` but the
  new build's, `geex_erts-16.1_0.1.0+839c64cb` included, which that geex ran from. A running
  VM loads modules from its unpack as it first needs them (interactive mode), so the next ones
  were missing: `{undef, [{sys, get_log, …}]}` in ThousandIsland's shutdown, and
  `io_lib_pretty` `nofile` in the logger's formatter, whose crash report went to the
  terminal. The earlier note "restart running editors after a deploy" assumed only an unloaded
  grammar would fail.
- **Fix:** the prune skips an unpack named by a process's `/proc/<pid>/exe` (Burrito's
  `beam.smp` lives in the unpack) or by a path in its `cmdline` (`-root <unpack>`), and
  `geex.prev`'s. The removal of the new build's own unpack, before its first run, is skipped
  the same way for a committed build (the same code); a dirty one stops the deploy.

---

## BUG-3 — Ctrl-C kills geex outright: the terminal, the ledger lock and the discovery file are left behind  ✅ FIXED (2026-10-16)

- **Status:** **FIXED** 2026-10-16. `Geex.TerminalIO` runs `stty -isig -ixon` on the tty after
  `:prim_tty` takes it, and puts the earlier settings back on exit. Verification is in the
  [testing.md](testing.md) 2026-10-16 entry "Ctrl-C and the other tty keys reach
  geex (BUG-3)". Found by the coordinator session while checking the installed binary (ADR-0036). It
  happened the same under `mix run`, so the binary didn't cause it.
- **Symptom:** Ctrl-C in geex didn't quit through the keymap. The VM died at once, and the shell
  that ran it died of SIGINT too (`tmux` reported the pane dead by signal 2). Nothing's
  `terminate/2` ran, so:
  - the terminal stayed on the alternate screen;
  - `$XDG_RUNTIME_DIR/geex/<pid>.json` was left behind;
  - an open buffer's `<key>.lock` stayed in the ledger directory;
  - unsaved edits were lost.

  Ctrl-Z (SIGTSTP) suspended geex with the frame and raw mode left on screen, and `kill %1`
  couldn't end it: the coordinator saw it under the binary, and a `mix run` geex of the
  maintainer's sat suspended for hours holding `ansi.ex`'s ledger lock. Ctrl-\\ (SIGQUIT) ended
  the VM with no restore. Ctrl-S (XOFF) froze the screen, and Ctrl-Q (XON), a quit key, never
  reached geex.
- **Verified cause:** `:prim_tty`'s raw input mode turns off `icanon` and `echo` but leaves `isig`
  and `ixon` on. Checked with `stty -F <pane tty> -a` while geex ran: `ixon isig -icanon
  -echo`. So the terminal turned Ctrl-C into SIGINT for the foreground process group, and the
  keymap never saw the byte. With `+Bd` the break handler is off, so SIGINT ended the VM with no
  cleanup.
- **Fix notes:**
  - `stty` runs on the VM's own stdin device (`/proc/<pid>/fd/0`), because a port's child has no
    controlling terminal and can't open `/dev/tty`.
  - After SIGCONT, `:prim_tty` sets its raw mode again, so `TerminalIO` turns the keys off again.
  - Bytes 0 and 28–31 (Ctrl-@, Ctrl-\\, Ctrl-], Ctrl-^, Ctrl-_) now parse as Ctrl keys. They
    used to come through as text, so Ctrl-\\ would have typed a control byte into the buffer.
  - The minibuffer quits on Ctrl-Q and Ctrl-C as well as Ctrl-X, like the editor and the panes.
- **Ruled out:** the binary. `mix run` with `--erl "-noshell -noinput +Bd"` behaved the same.

---

## BUG-2 — Flicker at the line tail while typing (the highlighter's two-pass)  ✅ FIXED (2026-06-09)

- **Status:** **FIXED** — the optimistic highlight-overlay shift. Verified: 503 tests + 9
  doctests green, adversarially reviewed (5 findings fixed), live-smoked. See the
  [testing.md](testing.md) 2026-06-09 entry.
- **Symptom (user-reported, after BUG-1):** "when I type a character, the end characters or
  close to the end characters per line flicker a little bit." Confirmed by the user: typing in
  a **no-grammar scratch buffer does not flicker** — so it's the highlighter, not the renderer.

**Verified cause.** Every keystroke triggers two repaints. The **immediate** one (so the typed
char appears with no latency) painted with the highlight spans computed for the *previous* text
— but spans are **byte offsets** ([`Span`](../lib/geex/highlight/span.ex)), and the edit shifted
every byte after the cursor. So the colours past the edit point were misaligned by the edit's
byte delta for one frame, until the **async re-highlight** ([`Reactor`](../lib/geex/highlight/reactor.ex))
landed and corrected them. Misalignment clusters at token boundaries → "the end characters
flicker." The loop even had the overlay's version available but discarded it.

**Fix (carry the edit, shift the overlay optimistically).** The buffer now emits the edit's
**byte footprint** `%{at, removed, added}` on its change event ([`Geex.Edit.Footprint`](../lib/geex/edit/footprint.ex)
+ [`Doc.byte_offset/2`](../lib/geex/buffer/doc.ex)) — on the *event*, so it covers human, agent,
and reconcile edits alike. The reactor shifts its overlay across the footprint
([`Span.shift_all/2`](../lib/geex/highlight/span.ex)) into an **optimistic** overlay served by a
new `render/1`, which the loop paints — so the immediate frame is already colour-aligned. The
exact re-highlight then supersedes it. `highlights/1`/`await/3` stay exact (tests unperturbed).

**Adversarial review fixed 5 issues** (4 dimensions, 14 agents): the span-shift boundary was
asymmetric-wrong (a char typed at a token's *start* stretched the token over it — fixed with
`shift_start` strict-`<` / `shift_end` inclusive-`<=`); an `:unknown` footprint (the multi-block
`edit` tool) regressed the overlay buffer-wide (now retains the prior overlay); plus two low items
(the loop's two-read version-skew window — documented; a stale `subscribe/2` docstring — fixed).

**Lays the groundwork for incremental reparse:** the same `{at, removed, added}` is what
tree-sitter's `Tree.edit` needs — a deferred ADR-0022 optimization.

**Deferred (low):** version-reconcile the loop's two reads (text@Session vs spans@Reactor) so a
concurrent MCP/reconcile edit can't briefly pair mismatched versions — documented at the read
site, one-frame self-correcting, not worth a guard yet.

---

## BUG-1 — Flicker while typing  ✅ FIXED (2026-06-09)

- **Status:** **FIXED** — `Geex.Renderer.frame/3` (atomic frames via DEC 2026 + conditional
  show/position cursor). Verified: 466 tests + 9 doctests green, live-smoked in tmux. See the
  [testing.md](testing.md) 2026-06-09 entry. *Visual "flicker gone" confirmation is the user's
  to make — `capture-pane` can't show intermediate frames.* The diagnosis + fix below are kept
  as the record.
- **Symptom (user-reported):** visible flicker/jitter on each keystroke.

**What it is NOT** (ruled out by reading the render path):
- **Not a full-frame repaint.** `Geex.Renderer` is a true damage/diff renderer — `diff/2`
  compares the prev/next `Screen` cell-by-cell and emits only changed cells, grouped into
  runs ([renderer.ex:77-86](../lib/geex/renderer.ex#L77-L86), `diff_row`/`group_runs`).
- **Not clear-then-redraw.** `\e[2J` is emitted **only** on a dimension change (initial
  flush + resize), never on a keystroke ([renderer.ex:84](../lib/geex/renderer.ex#L84)).
- **Not many small writes.** Each frame is a single `:prim_tty.write` of one iolist
  ([renderer.ex:175](../lib/geex/renderer.ex#L175) → [terminal_io.ex:133](../lib/geex/terminal_io.ex#L133)).
- **Not the wide-glyph continuation cell.** Emitting `""` for the right half of a wide
  glyph is intentional and correct ([cell.ex:17-21](../lib/geex/cell.ex#L17-L21)); the
  terminal advances two columns for the lead glyph, so position stays correct. Checked —
  not the cause.

**Verified root cause (the honest, post-adversarial picture).** The frame is a *single
atomic* `:prim_tty.write` with the cursor emitted **last by deliberate design**
([renderer.ex:48-52](../lib/geex/renderer.ex#L48-L52)), so the early "visible cursor
teleports across each changed run" theory does **not** hold — intermediate CUP moves inside
one write are not independently presented. Two genuine, code-grounded causes remain:

1. **No synchronized output.** There is no `\e[?2026h … \e[?2026l` (Begin/End Synchronized
   Update) anywhere in `lib/` (grep: zero hits). A keystroke frame can touch several
   non-adjacent runs (edited text + the status col counter, and on a line-change the
   active-line background + possibly the gutter). A large enough frame can be **presented
   torn** across the terminal's refresh boundary → flicker. *This is the primary cause.*
2. **Unconditional show-cursor every frame.** `cursor_seq({x,y})` re-emits `\e[?25h` on
   **every** frame ([renderer.ex:94-95](../lib/geex/renderer.ex#L94-L95)) even when the
   cursor was already visible and didn't move — which can **reset the cursor blink state**
   each keystroke and read as cursor flicker on some terminals.

**Recommended fix (in order):**
1. **Wrap each frame in synchronized output** — prepend `\e[?2026h` and append `\e[?2026l`
   around the `[diff, cursor_seq]` iolist in `flush/1` and `flush/2`
   ([renderer.ex:164-177](../lib/geex/renderer.ex#L164-L177)). Terminals that support DEC
   2026 (kitty, foot, recent iTerm2, WezTerm, Ghostty, Windows Terminal) present the frame
   atomically; others ignore the unknown private mode, so it is always safe to emit. Keep
   the existing "skip the write when `diff == []` and the cursor is unchanged" fast path so
   idle frames still cost nothing, and don't emit the wrapper around an empty payload.
2. **Emit show/position only on a transition** — send `\e[?25h` + CUP when the cursor's
   visibility or position actually changed, not on every frame, to stop the blink-state
   reset.
3. *(belt-and-suspenders, optional)* hide the cursor for the paint (`\e[?25l` before the
   diff). Mostly cosmetic given the single atomic write + cursor-last ordering above; do it
   only if 1–2 don't fully resolve it on a non-2026 terminal.

**Layered perf note (not the fix):** `highlight_line/4`
([loop.ex:380](../lib/geex/loop.ex#L380)) re-tints the active line's whole-width background
every frame; trimming the per-keystroke damage to only the rows whose active-line state
changed shrinks each frame (fewer runs), compounding the benefit on terminals that ignore
synchronized output. Medium effort, layered on top of fixes 1–2 — not a substitute.

**Verification when fixed:** drive a keystroke burst in the tmux dogfood and confirm no
visible tearing; on a DEC-2026 terminal confirm the frame is atomic; check the cursor no
longer blinks-resets on same-position frames.
