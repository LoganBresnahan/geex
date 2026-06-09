# ADR-0029: The selection primitive — one region, two surfaces

- **Status:** Proposed
- **Date:** 2026-06-09
- **Relates to:** [ADR-0028](0028-editor-shell-and-minibuffer.md) (a *view* is cursor/scroll/**selection**
  onto a buffer; highlight mode), [ADR-0027](0027-grid-command-addressing.md) (grid coordinates resolve
  to a span), [ADR-0015](0015-clipboard-subsystem.md) (copy/cut/paste consume a region),
  [ADR-0014](0014-editor-state-and-dispatch-ownership.md) (the view-local `{line, col}` cursor),
  [ADR-0003](0003-one-shared-path.md) (one shared path — human and agent reach the same values)
- **Sketch:** [notes.md](../notes.md) "Editing & selection bindings"

## Context

Cut / copy / paste, and the grid `copy x5 y7 - x12 y9`, all operate on a **region** of the buffer. There
are two honest ways to *name* a region, and the design risk is treating them as two features:

- **interactively** — highlight mode (`Alt+H`) anchors at the cursor and extends as the user moves
  (WASD / Q-E / R-F), a moving end against a fixed end (vim visual mode);
- **declaratively** — grid coordinates ([ADR-0027](0027-grid-command-addressing.md)) name the two
  endpoints by number (the typed / agent surface).

These are not competitors. They are the human-interactive and the typed/agent **surfaces for the same
thing** — a span between two carets. So geex needs **one** region value that both surfaces build, the
same way a typed `copy x5 y7` and an agent's MCP call become the same `%Command{}`
([ADR-0003](0003-one-shared-path.md)). [ADR-0028](0028-editor-shell-and-minibuffer.md) already names it:
"a *view* is a cursor/scroll/**selection** onto one buffer." This ADR pins that selection.

The open question this settles: what *are* a selection's coordinates and span semantics, such that it
feeds the edit primitives without conflicting with the grid notation's inclusive ends (ADR-0027 §7)?

## Decision

**1. A selection is `%Geex.Selection{anchor, active}` — two `{line, col}` grapheme carets.** Both ends
live in the **same coordinate space as the view cursor** ([ADR-0014](0014-editor-state-and-dispatch-ownership.md)):
0-based `{line, col}`, `col` in graphemes. `anchor` is the fixed end (set when the selection starts);
`active` is the moving end (tracks the cursor). The selection is **directional** — `active` may sit
before or after `anchor` — but order is recovered on demand (§3). Display width never enters: addressing
is grapheme/logical, a render concern only ([ADR-0027](0027-grid-command-addressing.md) §2).

**2. Caret / position semantics — half-open `[start, end)`, *not* grapheme-inclusive.** `range/1`
returns the two carets in document order as a **half-open span**: the grapheme at `start` is included,
the one at `end` is not. This is deliberate and load-bearing — it **matches `Geex.Buffer.Doc.replace/3`'s
existing range argument** (a `{{r1,c1},{r2,c2}}` position pair; an empty range is a point insert), so a
selection feeds `cut`/`replace`/a future `Doc.slice/2` **directly**, with no conversion. It is *not* the
grid notation's inclusive convention (`x5 - x12` includes `x12`, ADR-0027 §7) — and there is no conflict,
because that inclusivity is a property of the **typed notation**, which `Geex.Coord.to_span/2` converts
into the **same half-open position span**. *The two surfaces converge at the span, each keeping its
natural input convention.*

**3. Order is plain tuple comparison.** `{line, col}` tuples compare lexicographically, which *is*
document order, so `range/1` is `if anchor <= active, do: {anchor, active}, else: {active, anchor}` and
`contains?/2` is `start <= pos and pos < end`. No bespoke comparator.

**4. The primitive is pure and buffer-agnostic.** `Geex.Selection` never reads a `Doc`. Operations:
`new/1` (collapsed at a position), `extend/2` (move `active`), `anchor/1` / `active/1`, `collapsed?/1`,
`range/1`, `contains?/2`. **Select-all** (`Alt+Z`) is *not* a special constructor — it is a caller
building a selection over the whole buffer (`new({0,0}) |> extend(last_caret)`), since only the caller
knows the buffer's bounds. Keeping the primitive free of `Doc` keeps it trivially testable and reusable.

**5. Where it lives, and the cursor relationship (the wiring, deferred).** A live selection belongs to
the **view** ([ADR-0028](0028-editor-shell-and-minibuffer.md): view = cursor/scroll/selection) as an
*optional* field (`nil` when nothing is selected). While a selection is live, the **cursor is its
`active` end** — moving the cursor in highlight mode is `extend/2`; moving it outside highlight mode
collapses/clears the selection. The selection is **view-local and ephemeral** (like the cursor and
scroll): it is *not* in `EditorState`, never recorded, never replayed. The interactive wiring (the View
field, `Alt+H` mode in the keymap, the render highlight via `contains?/2`, the clipboard ops consuming
`range/1`) is the next build — this ADR fixes only the primitive so those can land against a stable shape.

## Consequences

- **One region, two surfaces.** Highlight mode and grid ranges build the *same* `%Selection{}` /
  produce the same span; clipboard and grid ops consume one notion of "the region" — the one-shared-path
  pattern applied to selection, not two parallel features.
- **Feeds the edit primitives with no impedance.** Half-open carets *are* `Doc.replace/3`'s range, so
  `cut`/`replace` need no selection→span adapter; `copy` + a future read-only `Doc.slice/2` take the same.
- **No conflict with the grid notation.** Inclusive `x5 - x12` is a notation property resolved by
  `Coord.to_span/2` into the same half-open span; the selection and the grid converge, they don't clash.
- **Deferred (the wiring, gated on the catalog/clipboard build):** the optional `selection` field on the
  view + cursor-is-active-end rule; `Alt+H` highlight mode + the typed `highlight`/`select` twin
  ([ADR-0028](0028-editor-shell-and-minibuffer.md) amendment); the render highlight (paint
  `contains?/2` cells with a selection bg — a new palette key); the clipboard registers consuming
  `range/1` ([ADR-0015](0015-clipboard-subsystem.md)); `Geex.Coord.to_span/2` producing the matching
  span ([ADR-0027](0027-grid-command-addressing.md)); multi-selection (a list of selections, ADR-0027
  `,` lists) — the primitive is single-span, a list is a later wrapper.
- **Status is Proposed** — the primitive is built and tested, but the half-open-vs-inclusive call and
  the cursor-is-active-end rule are open for review before this is Accepted and wired.

## See

[ADR-0028](0028-editor-shell-and-minibuffer.md) (the view/selection model + highlight mode),
[ADR-0027](0027-grid-command-addressing.md) (the grid surface that resolves to the same span),
[ADR-0015](0015-clipboard-subsystem.md) (the clipboard that consumes a region),
[notes.md](../notes.md) "Editing & selection bindings", `lib/geex/selection.ex`,
`lib/geex/buffer/doc.ex` (`replace/3`'s range arg this aligns with).
