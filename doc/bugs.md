# geex — Known bugs (triage shelf)

Bugs found but deliberately **not fixed yet** — captured so they aren't lost and so a fix
starts from a real root cause, not a guess. Each entry: symptom, status, the *verified*
cause, the recommended fix, and what was ruled out. When one is fixed, move it to
[testing.md](testing.md) with the verification.

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
