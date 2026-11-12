# ADR-0037: The pane and file keys

- **Status:** Accepted 2026-10-17 (the maintainer's keymap, relayed by the coordinator session and
  built autonomously at the maintainer's word). **Amends** the keys of
  [ADR-0028](0028-editor-shell-and-minibuffer.md) §3 (the palette moves off `Alt+P`) and
  [ADR-0034](0034-panes-tree-edits-hold.md) §7 (`Alt+O` and `Alt+L` change meaning).
  **Amended 2026-10-18:** `Alt+Y` opens the settings view (ADR-0040 §7). **Amended
  2026-10-19:** `a`, `d` and `r` in the tree (ADR-0019's amendment); `open PATH` is from the
  project root, as the finder is. **Amended 2026-11-06 ([ADR-0043](0043-markdown-preview.md)):** P is case-sensitive, `Alt+Shift+P` the markdown preview. **Amended 2026-11-12 by [ADR-0051](0051-panes-on-alt-angle-brackets-digits-free.md):** the panes on `Alt+<` and `Alt+>`.
- **Date:** 2026-10-17
- **Relates to:** [ADR-0026](0026-terminal-input-model.md) (Alt is a secondary, remappable
  namespace; every Alt key has a typed twin), [ADR-0028](0028-editor-shell-and-minibuffer.md)
  (the minibuffer, the palette, typed-verb parity), [ADR-0034](0034-panes-tree-edits-hold.md) (the
  panes, the tree, the edits pane, fast-forward)

## Context

geex grew panes (the file tree, the edits pane) and more than one open buffer, but the keys for
them were whatever was free when each landed: `Alt+O` cycled the panes, `Alt+L` fast-forwarded, and
showing the tree or the edits pane, opening a file or closing one had only typed verbs. Using geex
day to day, the maintainer wanted the file keys on one hand and grouped by what they do, with
`Alt+O` free for "open a file" (the next step makes it a fuzzy finder) and room for split panes
and tabs after that.

## Decision

| Key | Action | Was | Typed twin |
|---|---|---|---|
| `Alt+P` | the next pane (tree · editor · edits) | the palette | — |
| `Alt+I` | the command palette | unbound | — |
| `Alt+O` | open a file: the minibuffer with `open ` typed (a fuzzy finder next) | the next pane | `open PATH` |
| `Alt+K` | close the file, refused with unsaved edits | unbound | `close` |
| `Alt+T` | show or hide the file tree | unbound | `tree` |
| `Alt+L` | show or hide the edits pane | fast-forward | `edits` |
| `Alt+J` | fast-forward: take in the file's change on disk | unbound | `fast-forward` |

- **Every letter is case-insensitive**, as the other Alt keys are. `Alt+Shift+O` still can't
  arrive (`ESC O` is an SS3 prefix); the lowercase chord is the one to press.
- **From the tree and the edits pane** these work too: `Alt+P`, `Alt+I`, `Alt+M`, `Alt+O`,
  `Alt+T`, `Alt+L`, and the quit keys. `Alt+K` and `Alt+J` act on the file you're editing, so they
  stay the editor's.
- **In the tree,** `Alt+A` and `Alt+D` act as Left and Right (close or go up, open), as `Alt+W` and
  `Alt+S` already act as Up and Down: the WASD cluster moves the tree the way it moves the cursor.
- **Opening a file gives the editor the keys,** whichever pane you opened it from (`Alt+O`, or
  `open PATH` typed in the minibuffer), as Enter on a tree row already did.
- **The hints follow:** the edits pane's header says `Alt+P`, the status line's "behind disk"
  says `Alt+J`, and the palette's descriptions name the new keys.

## Consequences

- Muscle memory from 2026-10-15/16 breaks: `Alt+P` no longer opens the palette, and `Alt+L` no
  longer fast-forwards. The palette lists every action, so a forgotten key is a search away.
- The remaining free Alt letters are `Y` and the ones with terminal meaning (`[`, `\`, `]`); the
  next step's keys (`Alt+-`, `Alt+=`, `Alt+,`, `Alt+.`, `Alt+1..9`) are punctuation and digits.
- Nothing here changes the frozen MCP surface (ADR-0032): these are the human's keys.

## Amendment — 2026-10-18: `Alt+Y`, the settings view

[ADR-0040](0040-bare-geex-and-the-catalog.md) §7 takes `Y`, the last free Alt letter (`E`, `F`,
`Q` and `R` are motion), for the settings view: languages to install, themes, the keys, and the
general settings. `Alt+Y` opens it from the editor, the tree or the edits pane, though not from
the minibuffer, where keys are typed. `Alt+Y` or Esc closes it. Inside it, the editor's own
motion keys move: `Alt+A`/`Alt+D` (or ←/→, or Tab) change tabs, and `Alt+W`/`Alt+S` (or ↑/↓)
move the highlight. An Alt chord is never typed into the Keys tab's search. Its typed twins are
the verbs it
stands over (`theme`, `mouse`, `tree`, `edits`) and `geex install` in the terminal.

## Amendment — 2026-10-19: `a`, `d` and `r` in the tree

With the tree focused, three plain letters act on the highlighted entry
([ADR-0019](0019-file-lifecycle-and-operation-tools.md)'s 2026-10-19 amendment): `a` adds a file
(the minibuffer opens with `new DIR/` typed; a trailing `/` makes a directory), `d` deletes after a
y/n (a directory only when empty), and `r` renames, asking for the new path. They are plain
letters, not Alt chords: the tree takes no text, so no letter typed there edits anything, and
`Alt+A`/`Alt+D` already move it. Upper case works too. The tree's title shows `a d r · Enter`
while it has focus. Their typed twins are `new`, `mkdir`, `delete` and `rename` (`mv`), which act
on the current file.

## Amendment — 2026-10-19: every path is from the project root

The maintainer's answer, relayed by the coordinator session: `open PATH` resolves a relative
path from the project root, as the file operations do, no longer from the current file's
directory ([ADR-0034](0034-panes-tree-edits-hold.md)'s step 2). That was the intent from the
start. A relative path that leaves the root (`../x`) is refused, and `/…`, `~` and `~/…` still go
anywhere. `Alt+O`'s finder already was rooted: it lists the root's files as paths from it (the
name, then its directory) and opens the one picked from the root, wherever the current file is.
So the tree, the finder, `open`, `new`, `mkdir` and `rename` all name paths the same way
(`Geex.Loop.FileOps.resolve/2`).


## Amendment — 2026-11-06: P is case-sensitive ([ADR-0043](0043-markdown-preview.md))

`Alt+P` is the next pane; `Alt+Shift+P` toggles a markdown file's preview. The shifted chord acts
on a file, so it stays the editor's, as `Alt+K` and `Alt+J` do: from the tree, the edits pane and
the output pane it does nothing. With Caps Lock on, `Alt+P` therefore no longer leaves a panel; Esc
still does.

## Amendment (2026-11-11): the pane and file keys move to the left hand ([ADR-0049](0049-ijkl-default-keys.md))

With motion on IJKL, the keys here that sat in that cluster move: `Alt+B` the palette (was
`Alt+I`), `Alt+F` open a file (was `Alt+O`), `Alt+W` close (was `Alt+K`), `Alt+E` the edits pane
(was `Alt+L`), `Alt+D` fast-forward (was `Alt+J`), `Alt+R` revert (was `Alt+U`, ADR-0033 §7).
`Alt+P`, `Alt+T`, `Alt+Y` and `Alt+Shift+P` stay. In the tree, `Alt+J`/`Alt+L` act as Left and
Right, and `Alt+I`/`Alt+K` as Up and Down, since they run those commands (ADR-0047 §4).


## Amendment (2026-11-12): the panes on `Alt+<` and `Alt+>` ([ADR-0051](0051-panes-on-alt-angle-brackets-digits-free.md))

`Alt+P` no longer moves to the next pane: `Alt+>` does, and `Alt+<` (the new `pane prev`) moves to
the one before. Both work from the tree and the edits pane, as `Alt+P` did. `Alt+P` is the
markdown preview.

## See

- `lib/geex/loop/keymap.ex` (`resolve/3`), `lib/geex/loop.ex` (`panel_chord/2`,
  `apply_tree_key/2`, `apply_action/4`'s `:find_file`), `lib/geex/command/catalog.ex`.
- `test/geex/loop/keymap_test.exs`, `test/geex/loop/panes_test.exs`.
