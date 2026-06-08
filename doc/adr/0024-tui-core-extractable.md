# ADR-0024: The TUI core is extractable — but stays in geex for now

- **Status:** Accepted
- **Date:** 2026-06-08
- **Relates to:** [ADR-0021](0021-capability-connections.md) (build-extractable philosophy),
  [ADR-0022](0022-capability-reactor.md) (the reactor/overlay the loop renders)

## Context

geex grew a coherent, **NIF-free** terminal UI core: `Geex.TerminalIO` (wraps
`:prim_tty` — raw mode, alt-screen, SIGWINCH, input parsing, event pub/sub) +
`Geex.Input.Parser` + `Geex.Screen`/`Cell`/`Rect` + `Geex.Renderer` (cell diff →
bytes) + `Geex.Sgr` (truecolor SGR). That is a complete cell-grid TUI runtime,
and it is differentiated: the existing BEAM options (`ratatouille` → `ex_termbox`)
wrap a **C termbox NIF**, whereas geex's renders on OTP's own `:prim_tty` with no
native code. The question (raised in design discussion): extract it as a
standalone Hex package so other Elixir projects can use it — the same "build
extractable" move made for the `tree_sitter_wasm` highlighter NIF
([ADR-0021](0021-capability-connections.md))?

## Decision

**Build it extractable; keep it in geex until it is mature *and* a second consumer
appears.** Same discipline as [ADR-0021](0021-capability-connections.md) — geex is
the only consumer today, and two things make extraction premature now:

1. **It is young.** No `wcwidth`/CJK double-width handling (a `字` desyncs the
   column math today), no mouse, and truecolor only just landed. A *published*
   TUI toolkit needs those; right now it would be half a toolkit.
2. **`:prim_tty` is OTP-internal and undocumented** (its own moduledoc says so),
   and it has changed across OTP releases. A package built on it makes *other
   people* inherit that fragility — unlike `tree_sitter_wasm`, which rents stable
   published crates. Mitigable (pin OTP, abstract the backend behind
   `Geex.TerminalIO`), but a real cost an editor shouldn't take on speculatively.

The seam is already mostly clean — `Sgr`/`Screen`/`Cell` are pure data/iodata and
`TerminalIO` isolates `:prim_tty` — so a later extraction is closer to
lift-and-shift than a rewrite. Keep drawing that boundary; **revisit when the core
has grown the missing pieces and something other than geex wants it.**

**Corollary — the live dogfood waits on the TUI loop.** Highlighting now fires off
the command stream and projects onto the `Screen`
([ADR-0022](0022-capability-reactor.md)), but **nothing yet drives `to_screen`
per frame against an open buffer** — there is no interactive editor loop. So the
*visual* dogfood (watch geex recolour its own source as you type) is gated on that
loop, not on more highlighting work. The wiring underneath it is built and tested;
the loop is the next visible milestone, and it is what makes the dogfood real.

## Consequences

- No premature package: geex avoids maintaining a general TUI library (CI matrix,
  versioning, `:prim_tty`-stability support burden) while it is still the sole user.
- The work continues **in geex** with extraction in mind — grow `wcwidth`/mouse
  behind the existing module boundaries; do not let editor-specific concerns
  (cursor model, `Geex.View`) leak into the would-be-shared core (`Screen`/`Cell`/
  `Renderer`/`Sgr`/`TerminalIO`).
- The **interactive TUI loop** is the next visible milestone: it renders the
  reactor's overlay each frame and unlocks the live highlighting dogfood.

## See

[ADR-0021](0021-capability-connections.md) (the same build-extractable / extract-at-
second-consumer rule for `tree_sitter_wasm`), [ADR-0022](0022-capability-reactor.md)
(the overlay the loop will render), `lib/geex/terminal_io.ex` / `renderer.ex` /
`sgr.ex` (the core in question).
