# geex — Known bugs (triage shelf)

Bugs found but deliberately **not fixed yet** — captured so they aren't lost and so a fix
starts from a real root cause, not a guess. Each entry: symptom, status, the *verified*
cause, the recommended fix, and what was ruled out. When one is fixed, move it to
[testing.md](testing.md) with the verification.

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

## BUG-5 — Flaky: the reconcile quiet-period test finds the buffer behind an *empty* file  (OPEN, 2026-10-18)

- **Status:** open. Seen once in about 13 full-suite runs, while checking the step 6 review's
  fixes (seed 125550). It didn't recur in 3 runs of that seed, so it depends on timing. No code
  in this run touched reconcile, apart from its watch dropping `-r` (`31a56fa`).
- **Symptom:** `test/geex/reconcile_test.exs:299` ("nothing is read until the path is quiet")
  failed its first assertion: `Buffer.snapshot(buf).behind` was
  `%{sha256: "e3b0c442…b855", …}` (the sha256 of `""`) right after the two injected events,
  inside the test's own reconciler's 150 ms quiet period.
- **What that means:** something called `Buffer.disk_changed/2` with `""` for this test's file.
  Reading `""` fits a read between `File.write!`'s truncate and its write (the test writes
  "v2 half", then "v2 done\n"). The test's own reconciler reads only after 150 ms of quiet, and
  then the file holds "v2 done\n".
- **Suspects, not confirmed:**
  - Another reconciler with a real inotify watch on `System.tmp_dir!()`, where this test's
    file lives. For example `session_test.exs` starts the global `Geex.Reconcile` with the real
    backend; it says "no real inotify", but its default `start_watcher` is `FileSystem`. Since
    `BufferSupervisor.whereis/1` is global, any such reconciler finds this test's buffer.
  - Both modules are `async: false`, so one would have to outlive its test: an `inotifywait`
    still delivering after its owner stopped.
- **Next step:** give the reconcile tests their own temp directory (not `/tmp` itself), and make
  `session_test`'s reconciler use a stub watcher. If the flake stops, that was it.

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
