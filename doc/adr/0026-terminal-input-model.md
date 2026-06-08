# ADR-0026: Terminal input model & keymap (one default, capability-gated extras)

- **Status:** Accepted
- **Date:** 2026-06-08
- **Refines:** [ADR-0025](0025-user-config-layer.md) (the keymap is user-config *data*),
  [ADR-0024](0024-tui-core-extractable.md) (the TUI core / `prim_tty`)
- **Relates to:** [ADR-0015](0015-clipboard-subsystem.md) (internal registers vs the system clipboard),
  [ADR-0028](0028-editor-shell-and-minibuffer.md) (`Alt+M` opens the minibuffer; the `Alt+WASD` defaults)

## Context

geex's interactive loop ([ADR-0024](0024-tui-core-extractable.md)) reads keys through
`:prim_tty`, and the live dogfood ([testing.md](../testing.md), 2026-06-08) pinned the
byte-level reality a TUI keymap must respect:

- **`prim_tty`'s raw mode is only *partial*.** `ISIG` is off (Ctrl-C arrives as a byte),
  but **`IXON` is on** — Ctrl-S froze the display in testing (XOFF), Ctrl-Q resumed it
  (XON). `prim_tty` exposes no knob to disable IXON (`input: raw | cooked | disabled` is
  the whole API), so we cannot fix it from Erlang without a NIF.
- **Some chords are byte-identical to named keys** on a legacy terminal and can never be
  told apart: `Ctrl-M`≡Enter, `Ctrl-I`≡Tab, `Ctrl-H`≡Backspace, `Ctrl-[`≡Esc.
- **The BEAM reserves SIGINT/Ctrl-C** for its break handler (`sigint` isn't in
  `os:set_signal/2`); the TUI launch passes `+Bd` to drop it.
- **Alt** is transmitted as `ESC`-prefixed bytes (no termios meaning, so it dodges flow
  control/signals) but is intercepted unevenly: macOS Option types special chars unless
  "Option as Meta" is set; tiling WMs (i3/sway) use Alt as their mod key; GNOME Terminal
  binds Alt+digit to tabs; the OS always reserves Alt+Tab/F4/Space.
- The **Kitty keyboard protocol** (a.k.a. "CSI u" progressive enhancement, supported by
  kitty/foot/wezterm/ghostty/recent iTerm + Windows Terminal) reports keys as escape
  sequences instead of raw control bytes — which **disambiguates the collisions above and
  sidesteps flow control** (the `0x13`/`0x11` bytes are never sent).

The question this ADR settles: do we ship **two default keymaps** (legacy vs enhanced),
or **one** default plus capability-gated extras?

## Decision

**1. One default keymap, safe on every terminal — not two schemes.** The defaults are
drawn only from universally-deliverable chords, so a user's muscle memory is identical
everywhere (an old SSH session and a kitty-class terminal behave the same). Defaults:
save = **Ctrl-O** (never Ctrl-S — flow control), quit = **Ctrl-X** (Ctrl-Q/Ctrl-C accepted
as courtesy), motion/edit on the named keys + safe Ctrl-letters. A divergent second
default set is rejected: the consistency cost outweighs the marginal familiarity gain.

**2. Detect enhanced keyboard support at startup and enable it when present.** Probe with
the **Kitty query bracketed before a DA1 request** — write `\e[?u\e[c`, read until the
always-answered DA1 reply (`\e[?…c`); a `\e[?…u` reply *before* it means the protocol is
supported (deterministic — no timeout guessing). When supported, push the flags (`\e[>1u`,
"disambiguate escape codes") and **pop on exit** (`\e[<u`) to restore the terminal.

**3. Capability *widens the bindable space*; it does not swap the scheme.** Enabling the
protocol earns its keep even with the one keymap (the same keys report unambiguously and a
stray Ctrl-S can't freeze the screen). Beyond that it only makes *more chords bindable*
(Ctrl-S, disambiguated Ctrl-M/I/H/[, richer modifiers) — available for the **user** to
reach via config ([ADR-0025](0025-user-config-layer.md)) or an optional named profile
(e.g. `keymap = "cua"`), **never an automatic swap** of what geex binds by default.

**4. Validate every binding against detected capability — never silently bind a freeze.**
At keymap load, each chord is resolved against what the terminal can deliver: bind it if
deliverable; if it needs the enhanced protocol and that's absent, **reject with a clear
message or use a declared fallback**. A single declarative map gives best-available-per-
terminal without forking:

```toml
save = { key = "ctrl-s", fallback = "ctrl-o" }   # ctrl-s where deliverable, else ctrl-o
```

**5. A documented reserved/unsafe-chord table** ships with the keymap so neither geex nor
a user binds into the minefield:

| Chord(s) | Why it's reserved | Bindable when… |
|---|---|---|
| Ctrl-M / Ctrl-I / Ctrl-H / Ctrl-[ | byte-identical to Enter/Tab/Backspace/Esc | enhanced protocol on |
| Ctrl-S / Ctrl-Q | XOFF/XON flow control (IXON) | enhanced protocol on |
| Ctrl-C / Ctrl-Z / Ctrl-\\ / Ctrl-D | interrupt / suspend / quit / EOF (convention) | use sparingly; honor convention |
| Alt+digit, Alt+arrows, Alt+Tab/F4/Space | terminal/WM/OS grabs | avoid in defaults |

**6. Alt is a secondary, configurable namespace** — `Alt+letter` only, never load-bearing
for essential commands (those stay on deliverable Ctrl keys). It is gated on parser support
and remappable for the i3/macOS cases. Two concrete defaults live here (added 2026-06-08):
**`Alt+W`/`A`/`S`/`D` = up/left/down/right movement**, an arrow-key alternative for keyboards
without arrows (the arrows remain the primary binding, so movement is never *only* on Alt —
honouring the "not load-bearing" rule); and **`Alt+M` opens the minibuffer**
([ADR-0028](0028-editor-shell-and-minibuffer.md)). On tiling WMs where Alt is the mod key
these may be grabbed, so they stay remappable via config ([ADR-0025](0025-user-config-layer.md)).

**7. System clipboard via OSC 52; bracketed paste on.** geex's internal copy/cut/paste are
its own registers ([ADR-0015](0015-clipboard-subsystem.md)); reaching the *system*
clipboard is a separate channel — emit `OSC 52` (`\e]52;c;<base64>\a`). Enable **bracketed
paste** (`\e[?2004h`) so a paste arrives as one delimited block, not as keystrokes/commands.

**8. Parser scope.** `Geex.Input.Parser` grows to decode: CSI-u (the enhanced reports),
`Alt` (ESC-prefix with a short disambiguation timeout vs. CSI vs. lone Esc), bracketed-paste
delimiters, and to **consume the capability-probe replies** (the `\e[?…u`/`\e[?…c` bytes)
so they never surface as garbage keystrokes.

## Consequences

- **One experience everywhere**, richer where the terminal allows — one keymap to learn,
  document, and test; CUA bindings (Ctrl-S/Ctrl-C) stay *opt-in* until a user asks.
- `prim_tty`'s IXON-on limitation is **worked around, not fixed**: enhanced mode sidesteps
  it; legacy mode avoids the affected keys. No NIF, no fragile `stty` dance.
- The **parser grows** (CSI-u / Alt / bracketed paste / probe replies) — the main new work.
- **Multiplexers can mask capability** (tmux/screen between geex and the real terminal), so
  detection reports "what's reachable from here" — the honest answer.
- `TERM`/`COLORTERM` are treated as weak hints; the query/response is the source of truth
  (same probe pattern reused for the truecolor→256/16 degradation, [ADR-0024](0024-tui-core-extractable.md)).

## See

[ADR-0025](0025-user-config-layer.md) (keymap-as-data + the optional profile), [ADR-0024](0024-tui-core-extractable.md)
(the loop / `prim_tty` core), [ADR-0015](0015-clipboard-subsystem.md) (registers vs system
clipboard), [testing.md](../testing.md) (the 2026-06-08 live dogfood that found ISIG-off /
IXON-on), `lib/geex/input/parser.ex` / `lib/geex/terminal_io.ex` (where this lands).
