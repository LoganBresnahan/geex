# ADR-0037: The pane and file keys

- **Status:** Accepted 2026-10-17 (the maintainer's keymap, relayed by the coordinator session and
  built autonomously at the maintainer's word). **Amends** the keys of
  [ADR-0028](0028-editor-shell-and-minibuffer.md) §3 (the palette moves off `Alt+P`) and
  [ADR-0034](0034-panes-tree-edits-hold.md) §7 (`Alt+O` and `Alt+L` change meaning).
  **Amended 2026-10-18:** `Alt+Y` opens the settings view (ADR-0040 §7). **Amended
  2026-10-19:** `a`, `d` and `r` in the tree (ADR-0019's amendment).
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

## See

- `lib/geex/loop/keymap.ex` (`resolve/3`), `lib/geex/loop.ex` (`panel_chord/2`,
  `apply_tree_key/2`, `apply_action/4`'s `:find_file`), `lib/geex/command/catalog.ex`.
- `test/geex/loop/keymap_test.exs`, `test/geex/loop/panes_test.exs`.
