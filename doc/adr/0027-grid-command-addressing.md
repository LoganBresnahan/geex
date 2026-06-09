# ADR-0027: Grid command addressing — the coordinate model

- **Status:** Accepted
- **Date:** 2026-06-08
- **Relates to:** [ADR-0002](0002-commands-as-values.md) / [ADR-0003](0003-one-shared-path.md)
  (commands are recorded, replayable values on one path), [ADR-0014](0014-editor-state-and-dispatch-ownership.md)
  (cursor is view-local `{line, col}`; resolve-and-snapshot), [ADR-0015](0015-clipboard-subsystem.md)
  (copy/cut/paste registers), [ADR-0024](0024-tui-core-extractable.md) (display width / the render grid)
- **Sketch:** [doc/notes.md](../notes.md) "Grid command system (the differentiator)"

## Context

geex's headline differentiator is a **grid command system**: type coordinates in the
minibuffer and the cursor jumps / a selection happens / a range is copied —
`copy x5 y7`, ranges, blocks. The [notes](../notes.md) sketched it with spreadsheet
letters (`a1`, `a1-g6`, `a1:g6`) and left two load-bearing questions open: **viewport-
relative or buffer-absolute?** and **columns past 26?**

A coordinate scheme for geex must choose along axes geex *already distinguishes*:

- **Horizontally, three units exist** — byte offset (UTF-8 storage), **grapheme** index
  (the cluster unit `Geex.Buffer.Doc` and the cursor `col` use), and **display column**
  (the width-summed axis from [`Geex.Width`](../../lib/geex/width.ex); a wide `中` owns two
  columns via a lead + continuation cell). They diverge only on wide glyphs, tabs, and
  combining marks — i.e. almost never in code, but unavoidably in general text.
- **Vertically, two units exist** — the **logical buffer line** (split on `\n`, what the
  line-number gutter prints) and the **visual screen row** (shifted by `scroll`).
- A command is a **recorded value re-applied on replay** ([ADR-0003](0003-one-shared-path.md));
  `Dispatch.replay/2` folds recorded commands against a document that earlier replayed
  edits have already mutated. The keymap already respects this: it **bakes** a concrete
  `{line, col}` into `Insert`/`Delete`/`Replace` before dispatch, and paste bakes literal
  text — never a reference that re-resolves later.

## Decision

**1. Notation is numeric `x y`, not spreadsheet letters.** A coordinate is two 1-based
integers, labelled to fix order: `x5 y7` = column 5, line 7. Letters (`a1`) are **removed
from the coordinate model**. As *coordinates* they are strictly worse: they cap at 26 (the
notes' own Q2 cliff), force an asymmetry (column-is-letter, row-is-number), need a base-26
scheme the notes call unwieldy, and make an LLM base-26-encode a position. `x y` is
unbounded, symmetric, universal, and trivial to emit. (Letters return **only** if the
easy-motion overlay below is built — and there they are throwaway *jump labels*, relabeled
on scroll, **not** coordinates. The notes conflated the two; they are separate.)

**2. The canonical axis is grapheme-`x` + logical-line-`y`; display width is excluded from
addressing.** `x` = 1-based **grapheme** index within the logical line (`x1` = first
grapheme; a wide `中` advances `x` by 1; a base+combining cluster is one `x`). `y` = 1-based
**logical buffer line** (`y7` = the 7th `\n`-split line), scroll-independent. **`Geex.Width`
is never called in the resolution path** — it stays purely in the render path. The payoff is
a hard safety property: a width-table change (an OTP `:unicode_util` update, a new emoji,
an ambiguous-width call) can only ever **mis-render** a line, never **mis-address** an edit.
Resolution reuses the same `String.graphemes/1` walk `Doc.replace/3` already uses, so the
addresser and the editor share one model by construction.

**3. Two addressing modes, sigil-distinguished, the *same* numeric notation:**

- **Buffer-absolute** (the default, unprefixed) — `x5 y7` is line 7 / grapheme 5 of the
  file regardless of scroll. The recorded / scripting / LLM form. Touches no view state.
- **Viewport-relative** (deferred, sigil-prefixed) — "the cell I can see," easy-motion
  style. This is the **only** mode that reads view state (scroll) and, for an `x` measured
  in display columns, the **only** place width re-enters addressing. It resolves against the
  current viewport and **bakes an absolute coordinate** before dispatch (see §4).

The notation does not change between modes — the absolute/viewport split is the *sigil*, not
letters-vs-numbers. (Settling Q1: "support both, sigil-distinguished.")

**4. Resolution schedule — bake before recording.** `copy` is never recorded or replayed
([ADR-0015](0015-clipboard-subsystem.md)), so it may resolve coordinates → a span **inside
its runner**, against the live document. The mutating siblings `cut`/`replace` **must**
resolve the coordinate → an absolute grapheme span **in the transport** (minibuffer loop /
MCP protocol) and **bake that span onto the recorded command before `Dispatch.run`** —
exactly as the keymap bakes `{line, col}`. A recorded command must never carry a raw
coordinate: replay would re-resolve it against a different intermediate document and land on
the wrong text. (Document-space addressing is *necessary* for replay-safety but not
*sufficient* — the coordinate is impure of *document* state, not just view state.)

**5. Layer placement — at/before dispatch, no new hook.**

- **Cast** — `Geex.Command.Type` gains a `:coord` / `:coord_range` clause parsing the numeric
  surface into a pure, view-free, 1-based `%Geex.Coord{x, y}` / `%Geex.Coord.Range{from, to,
  kind}`; one `Geex.MCP.Schema.json_type/1` row maps it to a JSON string with the grammar in
  its description.
- **Resolve** — a pure `Geex.Coord.to_span(range, doc)` (a function of coordinate + document,
  no `Session`/`View` read) returning an absolute grapheme span. Backed by a read-only
  `Geex.Buffer.Doc.slice/2` (the read sibling of `replace/3`, same grapheme walk).
- **Apply** — `copy` calls `to_span` in its runner; `cut`/`replace` bake the span in the
  transport (§4).

**6. The line-number gutter prints the 1-based *logical* line number** (`line + 1`, the same
source the status line already renders), **not** viewport row ordinals — so the number you
read in the gutter **is** `y`, with zero arithmetic. This is the one constraint this ADR
places on the gutter slice being built next.

**7. Range grammar (surface to pin before parser code, per the notes):** `-` = linear range,
`:` = rectangular block (deferred), `,` = multiple selections (deferred). Ends are
**inclusive** (`x5 y7 - x12 y9` includes the `x12` grapheme). A **reversed** range errors at
cast; an **empty** range is rejected at cast (following the `:edits`/`[]` precedent). `x`
past line end **clamps** to the line end (the "to end of line" intent) — implemented in the
resolver, since `Doc.replace/3` errors rather than clamps; `y` past EOF is a **hard error**.

## Consequences

- **One mental model, universal and unbounded.** `x,y` is Cartesian, everyone reads it, no
  column-26 cliff, no base-26 scheme to design, and an LLM emits `x5 y7` trivially — the
  grid stays first-class on the one shared path for *every* driver (human, LLM, peer).
- **Width bugs can't corrupt edits** — they can only mis-draw. The `Geex.Width` work stays a
  render concern; addressing is immune to it.
- **The gutter is locked to logical line numbers** (§6) — `y` == the gutter number. This is
  the actionable constraint now; everything else defers.
- **Deferred (lands with the command language / its named consumer):** the `Geex.Coord` /
  `Coord.Range` types + cast + `to_span` + `Doc.slice/2` (build when the first `:coord`
  command lands); the **viewport-relative** mode + **easy-motion overlay** + optional letter
  **jump labels** (needs a `Width.col_at_display/2` dual of `cursor_xy`, and the transport
  bake); **block/rectangular** ranges (gate block-*copy* behind a defined block-*paste*, so
  the ring never holds an entry paste can't restore); **multi-selection** (`,` lists);
  **pane targeting** (`:N/` prefix, notes.md:833 — settle its sigil against the viewport
  sigil so they don't collide); the cross-module `Geex.Position` consolidation (a separate
  refactor, not bundled).
- **Known inherited gap:** on a CRLF file `Doc` splits only on `\n`, so a trailing `\r` is an
  addressable grapheme and `x` counts it — the same gap the cursor/status `col` already has;
  not fixed here.
- **Minor:** the candidate editor-name "a1" (notes.md:845) loses its literal basis (it was
  the `a1` coordinate); the grid is still the differentiator it nodded to.

## Amendment (2026-06-08): the display ruler & the human picking surface

Building the gutter (the `y`-ruler) surfaced the dual question §2 left implicit: **what
coordinate does the *human* point in when picking a grid cell off the screen?** A grid
command is unusable if the user can't see which column is `x5`, so an x-axis **ruler** (a
top row of column ticks, locked to `hscroll` like a spreadsheet header — the x-twin of the
gutter) is required to make grid picking real. That ruler forces the decision:

**(b) — confirmed. Each surface names positions in the coordinate it can actually observe.**

- A single top ruler is **shared by every row**, so it can only honestly count **display
  columns** — grapheme index isn't uniform across rows once a wide `中` appears, so a
  grapheme ruler would disagree with the eye on exactly the lines that matter. The ruler is
  *unavoidably* display-column.
- Therefore the ruler **is the visual form of viewport-relative mode** (§3): **ruler
  visible ⟺ display-column interpretation.** The affordance and the interpretation are
  locked together, so there is **no footgun** — you never read a display ruler while an
  unprefixed `x5` is silently interpreted as grapheme-5. This promotes viewport-relative
  from a fringe deferred mode to **the human's primary picking surface**; buffer-absolute
  grapheme (§2) remains the **recorded / scripted / agent** form, reached without the ruler.
- The split is principled, not a compromise. **Screen-watchers** — the eye, the ruler,
  tmux, an external harness — can *only ever* observe display columns (it's the terminal's
  native unit). **Text-readers** — the agent over MCP — *only ever* observe graphemes (they
  read buffer text, never a cell grid). Forcing the agent into display columns (option a)
  would make it reason in a space it cannot see, re-coupling it to the width table §2
  exists to decouple. So: **canonical/recorded = grapheme (§2 unchanged); ruler + human
  pick = display, cast to a grapheme span at parse (the §4 bake).** (b) is the only
  non-lying option.

**Verification — `cursor_x` as the oracle for the display↔grapheme cast.** The one fragile
seam in (b) is the `Width.col_at_display/2` cast (the deferred dual of `cursor_xy`). It is
verified empirically against the real terminal: in the tmux dogfood harness, place the
logical cursor at grapheme `g` on a wide-glyph line, render, and assert
`tmux cursor_x == Width.upto(line, g) + x0`. Unit tests with a mocked width table cannot
prove this; only a real terminal can. The same check **guards `Geex.Width` against the
terminal's own width opinion** — any drift between geex's table and the terminal's
(`utf8proc`/wcwidth) shows up as a `cursor_x` mismatch, the canonical TUI emoji-width bug
made observable.

**tmux is the harness, never shipped** — geex owns the screen model and never reads cursor
position back at runtime (the terminal is a sink; "geex owns the world"). The runtime
*cousin* of `cursor_x` is the terminal's own cursor-position report — print a glyph, emit
`\e[6n` (DSR), read `\e[row;colR`. Every terminal answers it, so geex could learn a
specific terminal's width opinion with no tmux at all, slotting into ADR-0026's probe
discipline (`\e[?u\e[c`, read-until-known-reply). **Deferred** — empirical per-terminal
width detection is the escape hatch for the wcwidth-version mess, pinned here, not built now.

**Render (refines §"Render" of the sketch / Consequences):** the ruler + the easy-motion
overlay + an optional **grid-line paint** (faint column rules so the eye follows a column
down to a row) are **contextual** — shown only while a viewport-relative grid command is
being composed, not permanent chrome (ties the screen cost to the moment it earns its keep,
same instinct as showing the scroll bars only on overflow). This lands with the deferred
viewport-relative mode + `Width.col_at_display/2`.

## See

[doc/notes.md](../notes.md) (the original grid sketch + open questions this settles),
[ADR-0003](0003-one-shared-path.md) / [ADR-0014](0014-editor-state-and-dispatch-ownership.md)
(record-and-replay + bake-before-dispatch), [ADR-0015](0015-clipboard-subsystem.md) (copy/cut/
paste), [ADR-0024](0024-tui-core-extractable.md) (display width / render grid),
`lib/geex/width.ex`, `lib/geex/buffer/doc.ex`, `lib/geex/loop.ex` (`cursor_xy/3`, the gutter),
`lib/geex/command/type.ex` (where the cast lands).
