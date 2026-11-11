# ADR-0047: Every key runs a named command; the bindings are data

- **Status:** Accepted 2026-11-11 (the maintainer's ask; built on the branch `named-keys`, accepted
  at the maintainer's word the same day)
- **Date:** 2026-11-11
- **Amends:** [ADR-0028](0028-editor-shell-and-minibuffer.md) §2 (parity at the capability
  level, not one named command per key: now one per key), [ADR-0026](0026-terminal-input-model.md)
  §6 (the Alt keys "stay remappable via config": this is the base that makes them so)
- **Relates to:** [ADR-0040](0040-bare-geex-and-the-catalog.md) §7 (the settings view, where the
  Keys and Commands tabs show the bindings), [ADR-0037](0037-pane-and-file-keys.md),
  [ADR-0038](0038-split-panes-and-tabs.md), [ADR-0043](0043-markdown-preview.md) §1 (the keys
  each view takes)

## Context

The maintainer, 2026-11-11, while thinking about which keys feel right: geex's keys should be
remappable, and "for unification all keybindings get a named command that is also typable in the
minibuffer". The defaults themselves will change once remapping is easy (the WASD cluster, a
left- or right-handed layout, the macOS terminals that take `Option+←/→`), so this comes first.

What geex had:

- **Commands named for some keys only.** The catalog (`Geex.Command.Catalog`, the palette and
  the Commands tab) had 35 commands. Motion, resizing, opening the command line, the palette,
  grid mode and the settings view, the next pane and stopping a shell command had keys and no
  name. ADR-0028 §2 chose that on purpose: motion's typed form is addressing (`line N`, grid),
  since "you don't type 'move left one'".
- **Keys matched as bytes, everywhere.** `Keymap.resolve/3` held the editor's chords, and seven
  other places matched raw key events themselves: the tree, the edits and output panes, the
  preview, the minibuffer, the settings view and the loop's own front (`Alt+Y`, `Ctrl-G`, the
  resize keys). `Alt+W` was written out in six of them. Changing one key meant finding each.
- **The key help written by hand** (`Geex.Loop.KeyHelp`), and key names inside the catalog's
  descriptions ("Close this tab … (Alt+K)"), so a changed key would leave both wrong.

## Decision

**1. Two kinds of keys.**

- **Bound keys**: every chord (`Alt+…`, `Alt+Shift+…`, `Ctrl+…`, `Alt` with an arrow) and the
  navigation keys (the arrows, Home, End, Page Up, Page Down). Each is bound to a **command** in
  one table, `Geex.Loop.Bindings`.
- **The focused view's own keys**: printable characters, a paste, Enter, Esc, Tab, Shift+Tab,
  Backspace, Delete, the mouse, and the plain letters a panel takes (the tree's `a` `d` `r`, the
  output pane's `!` `q`). What these do depends on what has focus (Enter breaks a line, opens a
  row, submits the command line), so they are not bound. They are also the keys you can never
  lose, so no binding can lock you out.

**2. Every command has a name, typed in `Alt+M`.** A command is a term of the loop's existing
action vocabulary (`:undo`, `:toggle_tree`, `{:tab, 2}`), and every one has a catalog entry: its
name, what it does, and its keys, read from the bindings. Descriptions no longer name keys. The
commands that had only a key get names:

| Keys | Command |
|---|---|
| ↑ ↓ ← →, `Alt+W` `Alt+S` `Alt+A` `Alt+D` | `up`, `down`, `left`, `right` |
| `Alt+Q` `Alt+E` | `word back`, `word forward` |
| Home End, `Alt+R` `Alt+F` | `line start`, `line end` |
| Page Up, Page Down | `page up`, `page down` |
| `Alt+↑ ↓ ← →` | `resize up`, `resize down`, `resize left`, `resize right` |
| `Alt+M`, `Alt+I`, `Alt+G`, `Alt+Y` | `command line`, `palette`, `grid`, `settings` |
| `Alt+P` | `pane next` |
| `Ctrl-G` | `stop` (the shell command running) |

The editor's own keys get names too, so each key in the editor has one: Enter `newline`, Tab
`indent`, Shift+Tab `indent other`, Backspace `delete back`, Delete `delete forward`, Esc `no`
(already `Alt+N`'s). These commands can also be bound to a chord; the key itself stays the
view's.

**3. One place turns a key into a command.** The loop translates a bound key into
`{:cmd, command}` as it arrives (`Bindings.translate/2`), before anything reads it. Everything
after (the keymap, the panels, the preview, the minibuffer, the settings view) matches
commands, never chords. A chord bound to nothing arrives as it came and does nothing.
Translating twice is translating once.

**4. A command means what it means where it runs.** `up` moves the cursor in the editor, the
highlight in the tree, the edits and output panes, a picker and the settings view; it scrolls a
preview, and in the command line it brings back an earlier entry. So a key bound to `up` works
in every one of them, and a remapped `up` follows into all of them. Since the Alt cluster and the
named keys now run the same commands everywhere, a few places gain the key they lacked:

- in the command line, `Alt+A`/`Alt+D` move the cursor and `Alt+W`/`Alt+S` bring back earlier
  entries, as ← → ↑ ↓ already did;
- in the output pane and a preview, `Alt+R`/`Alt+F` go to the top and the bottom, as Home and
  End already did.

Nothing else a key does changes.

**5. Caps Lock.** An `Alt+Shift+letter` that isn't bound itself runs `Alt+letter`'s command, so
Caps Lock doesn't turn the keys off (each clause used to list both cases). The two bound
themselves are `Alt+Shift+Z` (`redo`) and `Alt+Shift+P` (`preview`). `Ctrl` likewise.

**6. A typed command acts on the file you were last in.** Typed in `Alt+M` or picked in the
palette, a command closes the command line, then runs as its key would in the editor: on the
current file pane (with two editors, the one you were last in), whatever has focus, and focus
stays where it was. That is how the older typed verbs (`cut`, `undo`, `select all` …) always
worked. Only the commands whose keys work from anywhere run on what has focus: `settings`,
`stop`, and `resize …` (from the tree, `resize left` moves the tree's edge, as `Alt+←` does
there). Typing `up` with the tree focused moves the editor's cursor, not the tree's highlight:
the keys do that. The maintainer's word, 2026-11-11, after the review found the old and new
names disagreeing.

**7. The bindings are a value, not code.** The loop holds them (`state.keys`), the defaults from
`Bindings.defaults/0`; the key help, the Commands tab, the palette and the settings view's
footer read them. A key bound twice in the defaults doesn't compile. This slice changes no
default (`Alt+Shift+W/A/S/D` stopped resizing just before it, ADR-0026's amendment of the same
day) and adds no file: **remapping** (your changes kept in `settings.json`
([ADR-0040](0040-bare-geex-and-the-catalog.md) §7), edited in `Alt+Y`) is the next slice, and
this decision makes it a change to that one value. Its rules, decided now: a view's own keys
can't be bound; the arrows, Home, End, Page Up and Page Down keep their commands; a key bound
twice is refused; your changes are kept apart from the defaults, so a new default still reaches
you.

## Consequences

- One table to change a default. Moving `up` from `Alt+W` to `Alt+I` is one line, and the help,
  the palette and every view follow.
- Every key, in the editor, has a name you can type, find in the palette, and read in the
  Commands tab beside its keys. The palette lists about 25 more commands; it is a fuzzy search,
  so they cost a few more rows when nothing is typed.
- The keymap's tests now say which command a key runs and what that command does, as two
  facts. `Keymap.resolve/3` takes commands; tests give it chords through the default bindings.
- Plain letters in panels stay outside the table. If one should become bindable, it becomes a
  command then.
- A user's keymap file needs a written form for a chord (`alt+shift+z`); this slice only shows
  them (`Alt+Shift+Z`). The parser and its round-trip property come with the remapping slice.
- About twenty notices still name a default key in their text ("behind disk (Alt+J)", "the
  preview is read-only (Alt+Shift+P closes it)", "Alt+Y" after a grammar hint), some made outside
  the loop (`Geex.Reconcile`, `Geex.Markdown`, the file operations, the tree's watcher). They are right until a key is moved; the
  remapping slice makes them read the bindings.
- The palette's longer list matches more by description: typing `vsplit` lists `vsplit`, then
  `up` (its description has the letters in order). A name match still ranks first.
- Descriptions no longer name keys, so the palette and the Commands tab find a command by its
  keys instead: a query that is a whole key (`alt+k`, `Alt+5`, `ctrl+o`) lists the commands bound
  to it first. Whole, so `alt+s` is `down` and not `Alt+Shift+Z` (review, 2026-11-11).
- The keymap never resolves `newline`, `indent` and the editor's other own commands: the loop
  turns each into its key first, so a chord bound to `indent` gets the tab size, "Indent with" and
  the assists, as Tab does (review, 2026-11-11).

## See

- `lib/geex/loop/bindings.ex` (the table, `translate/2`, the labels), `lib/geex/loop/keymap.ex`
  (commands to actions), `lib/geex/command/catalog.ex`, `lib/geex/loop/verbs.ex`,
  `lib/geex/loop/key_help.ex`, `lib/geex/loop/settings.ex`
- `test/geex/loop/bindings_test.exs`
