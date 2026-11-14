# ADR-0049: The default keys move to IJKL

- **Status:** Accepted 2026-11-11 (the maintainer's layout; built on the branch `ijkl-keys`,
  accepted at the maintainer's word the same day). **Amended 2026-11-12 by [ADR-0051](0051-panes-on-alt-angle-brackets-digits-free.md):** `Alt+1` `indent other`, the other digits free, the panes on `Alt+<`/`Alt+>`, the preview on `Alt+P`, `Alt+Shift+R` `revert-call`
- **Date:** 2026-11-11
- **Amends:** [ADR-0026](0026-terminal-input-model.md) (the motion cluster; `Alt+;` read),
  [ADR-0028](0028-editor-shell-and-minibuffer.md) (`Alt+N` no longer closes the command line),
  [ADR-0029](0029-selection-primitive.md) (the selection keys),
  [ADR-0037](0037-pane-and-file-keys.md) (the pane and file keys),
  [ADR-0047](0047-every-key-runs-a-named-command.md) (the defaults in `Geex.Loop.Bindings`)
- **Relates to:** [ADR-0048](0048-the-palette-ranks-names-keys-then-loose.md) (the palette, now
  `Alt+B`)

## Context

geex's motion keys were a left-hand WASD cluster under `Alt`: `Alt+W/A/S/D` to move, `Alt+Q/E` a
word, `Alt+R/F` the line's ends. The maintainer picked WASD because "its classic for gamers but
i'm not even a gamer", and couldn't settle which finger takes `A`. ADR-0047 made the keys one
table so the defaults could change once they had a better idea; this is it. The maintainer,
2026-11-11: "ijkl to replace wasd, h replace r and ; replace f, o replace e and u replace q",
then for the keys that leaves without a home, "alt+a can be highlight all and then alt+b (like
book idk) could be for all commands".

## Decision

**1. The right hand moves.** With `Alt` held by the left hand, the right hand's home row and the
row above it make one cluster, each key's place its direction:

```
          U    I    O               word back · up · word forward
     H    J    K    L    ;          line start · left · down · right · line end
```

| Command | Was | Now |
|---|---|---|
| `up`, `left`, `down`, `right` | `Alt+W` `Alt+A` `Alt+S` `Alt+D` | `Alt+I` `Alt+J` `Alt+K` `Alt+L` |
| `word back`, `word forward` | `Alt+Q` `Alt+E` | `Alt+U` `Alt+O` |
| `line start`, `line end` | `Alt+R` `Alt+F` | `Alt+H` `Alt+;` |

The arrows, Home, End, Page Up and Page Down keep their commands. As ADR-0047 §4 has it, a
command means what it means where it runs, so `Alt+I`/`Alt+K` move the highlight in the tree,
the pickers, the edits and output panes and the settings view too, and `Alt+J`/`Alt+L` move the
tree and the settings view's tabs.

**2. The left hand's commands.** Seven commands had keys in the new cluster. They move to the
left hand, by their letter where one fits:

| Command | Was | Now | |
|---|---|---|---|
| `select all` | `Alt+B` | `Alt+A` | **a**ll |
| `palette` | `Alt+I` | `Alt+B` | the **b**ook of all commands |
| `open` (the finder) | `Alt+O` | `Alt+F` | **f**ind |
| `close` | `Alt+K` | `Alt+W` | a browser's `Ctrl+W` |
| `highlight` (start a selection) | `Alt+H` | `Alt+S` | **s**elect |
| `revert` | `Alt+U` | `Alt+R` | **r**evert |
| `fast-forward` | `Alt+J` | `Alt+D` | **d**isk |
| `edits` | `Alt+L` | `Alt+E` | **e**dits |

Nothing else moves: `Alt+M`, `Alt+G`, `Alt+Y`, `Alt+T`, `Alt+P`, `Alt+C`/`X`/`V`,
`Alt+Z`/`Alt+Shift+Z`, `Alt+Shift+P`, the pane and tab keys (`Alt+-` `Alt+=` `Alt+,` `Alt+.`
`Alt+1..9`), `Alt` with an arrow, `Ctrl-O`, `Ctrl-G`, `Ctrl-X`.

**2a. `Alt+Q` and `Alt+N` are kept for find.** The maintainer, the same day: "alt+q can be search
buffer and alt+shift+q can be global search". Stepping through the matches takes `Alt+N` (the
next) and `Alt+Shift+N` (the previous), N as in vim and less, so all of find sits on the left
hand. None of it exists yet (find is parked on the roadmap), so the four stay unbound until find
is built, under its own decision; that decision binds them. Bound themselves, `Alt+Shift+Q` and
`Alt+Shift+N` keep their meaning even with Caps Lock on, as `Alt+Shift+Z` and `Alt+Shift+P` do
(ADR-0047 §5).

**3. `Alt+;` is read.** The input parser takes `ESC ;` as `Alt+;`, beside the digits and `- = ,
.` (ADR-0038). No terminal sequence begins `ESC ;`, so nothing is mistaken for it. It has no
Shift twin: Caps Lock doesn't change `;`.

An SS3 (`ESC O` …) now needs its final byte (`0x40–0x7E`, after any parameter bytes); otherwise
`ESC O` is `Alt+Shift+O` and what follows is read again. Word forward sits on `Alt+O`, a key held
down, and with Caps Lock two presses in one read (`ESC O ESC O`) used to type an "O" (review,
2026-11-11).

**4. `Alt+N` stops clearing.** Esc clears a selection reliably since the 40 ms flush, and closes
the command line and answers no to a question, so `Alt+N`'s binding to `no` goes (§2a keeps the
key). The typed `no` still clears a selection; the help shows Esc beside it.

**5. Notices name the new keys.** The handful of messages that name a key in their text ("behind
disk (Alt+J)", "Alt+O opens one", "close it with Alt+K", "Alt+H starts one", "Alt+T, Alt+L")
name the new ones. Reading them from the bindings, so a remapped key reads right too, stays with
remapping (roadmap 20.3).

## Consequences

- Every key the help, the palette, the Commands tab and the settings footer show follows by
  itself: they read the bindings (ADR-0047 §7).
- `Alt+N` does nothing until find binds it: where it cleared a selection, closed the command line
  or answered a question, Esc does each.
- Muscle memory breaks once, for the maintainer and anyone running 0.5.0's keys. The arrows,
  Home, End and the typed names (`up`, `line end`, `open`, `close` …) don't change, so each
  command can still be reached while the new keys settle in.
- `Alt+;` needs Shift on some keyboard layouts (German, Spanish, Italian and the Nordic ones put
  `;` on Shift+`,`); `End` is the same command. Remapping (20.3) is the fix for a layout the defaults don't suit.
- The tests that pressed a key by its old chord press the new one; the ones that check a
  command's meaning don't change.


## Amendment (2026-11-12): the digits, the panes, the preview, `revert-call` ([ADR-0051](0051-panes-on-alt-angle-brackets-digits-free.md))

`Alt+1` is `indent other`; `Alt+2` … `Alt+0` run nothing, left for the user. `Alt+>` and `Alt+<`
are the next pane and the one before, `Alt+P` the preview, and `Alt+Shift+R` is `revert-call`.
## Amendment (2026-11-13): Home and End are the top and the bottom; the cluster in the minibuffer

The maintainer, 2026-11-13: "home/end are not needed for what they do now" (`Alt+H`/`Alt+;` are
the line's ends), "home/end should work on ! output as well and i guess we could do it for files
as well", and "yes to ijkluoh; and the delete key working in the minibuffer".

- **Home and End run their own commands, `top` and `bottom`** (catalog names, typed in `Alt+M`).
  In a file: the first line's start and the last line's end (a CRLF last line's `\r` is its end,
  as `Alt+;` already treats one); not a vertical move, so the goal column follows the landing,
  and a live selection extends. In a list: the output pane, the tree, the edits pane (past the
  `earlier` divider either way) and `Alt+Y`'s rows go to the first row and the last; a preview to
  its top and bottom. `Alt+H` and `Alt+;` stay `line-start` and `line-end` (in the output pane
  and a preview still the top and the bottom, as before).
- **The minibuffer takes the whole motion cluster.** `Alt+J`/`Alt+L` already moved its cursor and
  `Alt+I`/`Alt+K` brought back history or moved a picker's highlight; now `Alt+U`/`Alt+O` move a
  word back and forward (by the editor's own word rule, `Keymap.resolve/3` on the one line),
  `Alt+H`/`Alt+;` and Home/End go to the input's start and end, and **Delete** removes the grapheme
  after the cursor (`Minibuffer.delete/1`; a no-op at the end). They act on the input only, never
  the buffer. Delete leaves a pre-fill to edit, as Backspace does (ADR-0053's 2026-11-13 answers),
  and resets a picker's highlight to the top, as any edit of the filter does.
- Page Up and Page Down are unchanged: they scroll a preview and do nothing elsewhere
  (ADR-0043). The maintainer's keyboard has them on a volume rocker, so they were checked here
  instead (testing.md, 2026-11-13).

## See

- `lib/geex/loop/bindings.ex` (the defaults), `lib/geex/input/parser.ex` (`Alt+;`)
- `test/geex/loop/bindings_test.exs` (the defaults pinned)
