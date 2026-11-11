# ADR-0048: The palette ranks names, then keys, then loose matches

- **Status:** Accepted 2026-11-11 (the maintainer's ask, after the reviews of ADR-0047; built on the
  branch `palette-ranks`, accepted at the maintainer's word the same day)
- **Date:** 2026-11-11
- **Amends:** [ADR-0028](0028-editor-shell-and-minibuffer.md) §3 (the palette "fuzzy-lists" the
  commands: now in three bands), [ADR-0047](0047-every-key-runs-a-named-command.md) (finding a
  command by its key; `newline` is renamed `line break`)
- **Relates to:** [ADR-0040](0040-bare-geex-and-the-catalog.md) §7 (the Commands tab, which ranks
  the same way)

## Context

ADR-0047 took the key names out of the catalog's descriptions and let the palette (`Alt+I`) and
`Alt+Y`'s Commands tab find a command by its key instead: typing `alt+k` lists `close` first. Two
reviews of it, the same day, found the ranking's limits:

- **A key's name beat a command's name.** At first any whole key counted, bare ones too, so
  `delete` + Enter ran `delete forward` (Delete's command) instead of asking to delete the file,
  and `tab` indented instead of showing the next tab. The fix let only a chord (`alt+…`,
  `ctrl+…`) read as a key.
- **A loose match beat everything.** The palette ranks with `Geex.Fuzzy`: the query's letters in
  order, anywhere in the name, scored up for runs and word starts. A name match of any score
  ranks above every description match, but there is no line between a good name match and a
  poor one. With about 25 more commands in the catalog, `enter` + Enter now picks `indent other`
  (e‑n‑t‑e‑r scattered across its two words) and inserts an indent; on main it reached the
  rename prompt, by its description.

The maintainer, asked what `enter` should pick: the command the Enter key runs. Three smaller
things from the reviews ride along:

- The palette's name column is a fixed 14, so `delete forward` (and `theme terminal`, before
  ADR-0047) runs into what follows it: `delete forwardDelete · …`.
- `alt+5` finds the `tab N` entry, and picking it hands off to the command line with `tab `
  typed, though the query already said which tab.
- `new line` makes a file called `line` (`new PATH`), one space from `newline`.

## Decision

**1. Three bands.** The palette and the Commands tab list, for a query:

1. **The commands whose name matches well**: every word of the query starts a word of the name
   or an alias, in order. `delete` → `delete`, `delete back`, `delete forward`; `tab` → `tab
   next`, `tab prev`, `tab`; `line e` → `line end`; `sel al` → `select all`.
2. **The commands bound to the key the query names**, if it names one, chord or not: `enter` →
   `line break`, `backspace` → `delete back`, `home` → `line start`, `alt+k` → `close`,
   `shift+tab` → `indent other`. As in ADR-0047: whole keys only (`alt+s` is `down`, not
   `Alt+Shift+Z`), case and spaces ignored, `ctrl-o` is `ctrl+o`, and `alt+left` is `Alt+←`.
3. **Every other match**, as before: names over descriptions, by the fuzzy score.

Within a band the fuzzy score orders, ties keeping the catalog's order. A command in two bands
shows once, in the higher. The bands only change an order when the query names a key: with no
key, band 2 is empty and bands 1 and 3 are today's name matches then description matches, in
today's order, except that a good name match now outranks a better-scored loose one.

So a word is first a command's name and then a key's: `delete` asks to delete the file and
`tab` shows the next tab, as on main, and `enter`, which names no command, is Enter's. This
replaces ADR-0047's "only a chord reads as a key", which lost the bare keys to keep `delete`
safe.

`Geex.Fuzzy` itself doesn't change: the finder (`Alt+O`) and the buffer list use it as they are.
The bands are the catalog's (`Catalog.search/2`, given what the query's key names).

**2. A key picks its own command.** When a query is found by its key and the entry stands for
several commands (`tab N`, bound to `Alt+1` … `Alt+9`), the palette lists the one that key runs,
`tab 5` beside `Alt+5`, and picking it shows tab 5. Found by its words, `tab` still hands off to
the command line for the number.

**3. The name column fits the names.** The palette's names line up at the longest name listed
plus two, up to half the width, as the buffer and file lists already do. A command's keys and
description start after it.

**4. `newline` is `line break`.** The command Enter runs is named `line break`, beside `line
start` and `line end`. `newline` stays an alias, so typing it still works. `new line`, with the
space, is still `new PATH`: there is no command named `new line` now to be one space from.

## Consequences

- Typing a key's name finds what that key does, bare or a chord, unless a command has that name.
  A key named like a command (Delete, Tab) is reached by the command first; the key's command
  is listed after it (`delete forward` after `delete`; `indent` after the `tab …` commands).
- `enter` + Enter in the palette breaks the line, and `shift+tab` + Enter inserts the other
  indent: what the key does. That is what was asked of the palette; a query that names no key
  and matches nothing well still picks the best loose match, as before.
- A good name match can now outrank a higher fuzzy score: `sa` (an acronym, not word starts)
  ranks as before, but `sel` lists `select all` and `select start` above any loose match of
  `sel`. Acronym queries keep the fuzzy score's word-start bonus.
- The palette is the only place a candidate is narrowed to one of an entry's commands; the
  Commands tab still shows `tab N` with `Alt+1 … Alt+9`, since it lists rather than runs.
- Renaming a command name is a user-visible change: the typed name, the palette and the
  Commands tab say `line break`; the internal command (`:newline`) and its key don't change.

## See

- `lib/geex/command/catalog.ex` (`search/2`, the bands), `lib/geex/loop/bindings.ex`
  (`names_key?/3`, `named_command/3`), `lib/geex/loop.ex` (the palette's candidates and its name
  column), `lib/geex/loop/settings.ex` (the Commands tab)
- `test/geex/command/catalog_test.exs`, `test/geex/loop/named_keys_test.exs`
