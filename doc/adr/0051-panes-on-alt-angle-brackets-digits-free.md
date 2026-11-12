# ADR-0051: The panes on Alt+< and Alt+>, the preview on Alt+P, the digits free

- **Status:** Accepted 2026-11-12 (the maintainer's choices; built on the branch `indent-keys`
  with ADR-0050)
- **Date:** 2026-11-12
- **Amends:** [ADR-0026](0026-terminal-input-model.md) (`Alt+<` and `Alt+>` read),
  [ADR-0037](0037-pane-and-file-keys.md) (`Alt+P` was the next pane),
  [ADR-0038](0038-split-panes-and-tabs.md) (`Alt+1` … `Alt+9` showed tab N),
  [ADR-0043](0043-markdown-preview.md) §1 (the preview was `Alt+Shift+P`),
  [ADR-0049](0049-ijkl-default-keys.md) (the defaults), [ADR-0050](0050-tab-indents-a-selection-shift-tab-unindents.md)
  §5 (`indent other` was `` Alt+` ``), [ADR-0033](0033-durable-ledger.md) (`revert-call` had no
  key)
- **Relates to:** [ADR-0047](0047-every-key-runs-a-named-command.md) (every key runs a named
  command),
  roadmap item 20.3 (remapping)

## Context

ADR-0050 put `indent other` on `` Alt+` ``. GNOME and KDE take `` Alt+` `` by default to switch
between one application's windows, and `Alt+~` (`` Alt+Shift+` ``) to go back, so neither reaches
the terminal there. The maintainer, 2026-11-12, after hearing it: "alt+1 will be the opposite tab
so we can keep it in that region of the keyboard".

`Alt+P` went to the next pane, with no key for the pane before. The maintainer asked about
`Alt+[` and `Alt+]`; those arrive as `ESC [` (how a CSI starts: the arrows, the mouse) and `ESC ]`
(how an OSC starts), so the parser could read them only after a pause, a key pressed within it
would join the sequence, and on German, French and the Nordic layouts `[` and `]` need AltGr.
`Alt+<` and `Alt+>` (Alt+Shift+, and Alt+Shift+.) have none of that, and pair with `Alt+,` and
`Alt+.`, the tabs. The maintainer: "i agree with alt+shift+<,>"; "alt+p could become the markdown
preview instead of alt+shift+p".

`Alt+1` … `Alt+9` showed tab N. The maintainer: "unbind 1-9 now is fine i'm the only user", so
the digits are left for the user to bind once remapping (20.3) lands. `revert-call`, taking back
a whole tool call, had no key; `Alt+Shift+R` pairs it with `Alt+R`, one hunk ("i agree with your
plan on indent-keys").

## Decision

1. **`Alt+>` is `pane next`, `Alt+<` the new `pane prev`.** `pane prev` steps the same cycle
   (the tree, each file pane in reading order, the edits pane or the output) the other way,
   wrapping. Both work from the tree, the edits pane, the output and a preview, as `pane next`
   did. The parser reads `ESC <` and `ESC >` as `Alt+<` and `Alt+>`: no sequence a terminal
   sends starts with either.
2. **`Alt+P` is `preview`.** It shows or hides a markdown file's preview, as `Alt+Shift+P` did.
   `Alt+Shift+P`, bound to nothing, falls back to `Alt+P` like any Alt+Shift letter
   (ADR-0047), so the old key still works.
3. **`Alt+1` is `indent other`** (ADR-0050 §5), beside the key above Tab. `` Alt+` `` is still
   read but runs nothing.
4. **`Alt+2` … `Alt+0` run nothing.** `tab 1` … `tab 9` keep their names, typed in `Alt+M` or
   picked in the palette; `Alt+,` and `Alt+.` step through the tabs. The help shows no row for a
   command with no key, so "tab 1 to 9" leaves the Keys tab until a key is bound to them.
5. **`Alt+Shift+R` is `revert-call`.** `Alt+R` takes back one hunk; with Shift, the whole tool
   call that changed the line.

## Consequences

- Panes go both ways, and the tab and pane keys sit together: `,` `.` the tabs, `<` `>` (the same
  keys with Shift) the panes.
- On layouts where `<` and `>` aren't Shift+`,` and Shift+`.` (German has its own `<` key), the
  pane keys are elsewhere on the keyboard; the typed `pane next` and `pane prev` don't move.
- Tabs past the neighbours take more keys until remapping binds the digits: `Alt+,`/`Alt+.`, or
  `Alt+M tab 5`. The tab bar keeps its numbers, which `tab N` uses.
- `Alt+P` no longer moves between panes; muscle memory breaks once.
- `` Alt+` `` and the digits are left for the user; `Alt+Shift+P` is free to bind.
- With Caps Lock on, `Alt+R` arrives as `Alt+Shift+R` and takes back the whole tool call, not one
  hunk, as `Alt+Z` becomes redo. One `Alt+Z` after a `revert-call` of several hunks gives back one
  of them, since each hunk is its own recorded command (ADR-0031 §3); undoing a revert as one step
  is roadmap work, not this ADR's.

## See

- `lib/geex/loop/bindings.ex` (the defaults), `lib/geex/input/parser.ex` (`Alt+<`, `Alt+>`),
  `lib/geex/loop.ex` (`next_pane/2`), `lib/geex/command/catalog.ex` (`pane prev`),
  `lib/geex/loop/key_help.ex`
- `test/geex/loop/bindings_test.exs`, `test/geex/loop/panes_test.exs`, `test/geex/input/parser_test.exs`
