# ADR-0045: Typing assists — pairs closed as you type them, the indent kept on Enter

- **Status:** Accepted 2026-11-09. The maintainer asked for both while using geex (roadmap item
  19); the rules below were proposed in the same conversation and accepted whole ("yes i agree
  with all your suggestions"). Revised the same day after an adversarial review (session
  geex-d3, 13 findings, each run): the step-over and Backspace follow VS Code's "auto" rule, at
  the maintainer's word ("yes do what vscode does"), quotes don't pair where they close a string,
  CRLF lines, `:` only where it opens a block, the multi-line wrap's blame, and the paste fixes.
- **Date:** 2026-11-09
- **Relates to:** [ADR-0003](0003-one-shared-path.md) / [ADR-0014](0014-editor-state-and-dispatch-ownership.md)
  (every edit one command on the shared path), [ADR-0026](0026-terminal-input-model.md) (the
  keymap), [ADR-0029](0029-selection-primitive.md) (typing over a selection),
  [ADR-0031](0031-undo-redo-history-operations.md) (undo), [ADR-0040](0040-bare-geex-and-the-catalog.md)
  §7 (the settings view), [ADR-0035](0035-the-loop-never-waits.md) (bounded work in the key loop)

## Context

Until now a key typed exactly itself: `(` inserted `(`, Enter a bare line break at column 0. The
maintainer asked for the closing character typed with its opener (the cursor between) and for
Enter to keep the indent, and asked how editors make the indent "intelligent" when you don't
always want it. Editors do it at three levels: keep the current line's indent; one level more
after an opener and less before a closer, by per-language patterns (VS Code); or from the syntax
tree, with per-language indent queries (Zed, Helix, Neovim's tree-sitter indent).

## Decision

1. **Pairs close as you type them** (`Keymap.autoclose/5`), for `( [ { ' " `` ` ``, a General
   setting `auto_close`, on by default:
   - an opener or a quote is inserted with its closer and the cursor between, as one `Insert`;
   - it closes only at a line's end (a CRLF line's `\r` is its end) or before a space or
     `) ] } > ; : . , =` (VS Code's `autoCloseBefore`), so `(` in front of a word is just `(`;
   - a quote doesn't pair after a letter, a digit or `_` (combining marks and all), a closer or
     the same quote, nor inside a string: the line before the cursor is read for strings of all
     three quotes, a backslash inside one escaping what follows (`print(f"{x}")`, a tagged
     template and `x = "it's" + ': '` type as they read). `don't` types as it reads, and a
     markdown fence's three backticks come out as three;
   - `'` doesn't pair where it isn't a string's quote: prose (`.md`, `.txt` …), Rust, OCaml, F#,
     SML and Haskell, the Lisps, LaTeX; `` ` `` doesn't in the Lisps, OCaml and LaTeX
     (`Keymap.kind_opts/1`);
   - **VS Code's "auto" rule** for the closers geex inserted: the loop tracks each pair it
     closed (`Keymap.track/4`: `{line, opener, closer}`, view state, not the buffer's), shifted
     by single-line edits, dropped when an edit touches it, when the cursor leaves it, on Enter
     or a paste, when another tab is entered, and when the text changed by anything else (an
     agent, an undo, a cut): the buffer's version is checked as each key arrives, against the one
     the loop's own last edit made, not on the change notifications, which a burst of keys
     arrives ahead of. Actions that change neither the text nor the cursor (a save, Esc, a copy,
     a pane toggle) keep them. The loop also remembers the versions its own edits made, so their
     notifications don't clear what it kept (a wrap's selection). A closer or quote typed in front of a tracked
     closer steps over it; one already in the file, or typed, is typed again (`foo(baz(bar)` and
     `)` is `foo(baz(bar))`). Backspace between a tracked empty pair deletes both, one `Delete`
     (`Keymap.unpair/3`); a pair typed by hand loses only its opener. Neither happens while a
     selection is live (`Alt+H` and a closer types the closer);
   - an opener or a quote typed over a selection wraps it, the selection kept on what it held:
     one `Replace` on one line; across lines two `Insert`s, the closer then the opener (two
     `Alt+Z`), since blame credits whatever one command spans and the lines between must keep
     their writer (ADR-0029's amendment otherwise replaces).
2. **Enter keeps the indent** (`Keymap.newline/4`), a General setting `auto_indent`, on by
   default; levels 1 and 2 of the three:
   - the new line starts with the current line's leading spaces and tabs (as much as is before
     the cursor, counted by grapheme; a form feed isn't indent);
   - after an opener at the cursor (`{ [ (`, and `:` in Python, YAML and Makefiles, not ending a
     `#` comment) it is one
     level more; between a pair (`{|}`, spaces allowed) the closer goes to a line of its own at
     the current indent and the cursor to an indented line between, all one `Insert`;
   - one level is a tab or the tab size's spaces, by §3's rule, the one Tab follows;
   - with the cursor at the end of a line of only spaces and tabs, Enter clears that line and
     keeps the indent on the new one (one `Replace`), so the indent Enter left behind doesn't
     stay as trailing whitespace; whitespace left another way (the cursor moved off the line)
     stays;
   - Backspace in a line's leading spaces takes one level, back to the previous multiple of the
     tab size (`Keymap.dedent/3`; a tab is one grapheme already);
   - the break is the file's own (`Keymap.eol/1`: CRLF when its first one is); data files
     (`.tsv`, `.csv`) get a bare break, their leading tab being a field.
3. **What an indent level is** (`Keymap.indent_with/3`), for Tab and Enter alike: a General
   setting **Indent with**, `indent_with` in `settings.json`: `follow` (the default), `spaces`
   or `tabs`. Following the file, a file whose kind uses tabs gets them: Go (`.go`, `go.mod`,
   `go.work`, gofmt's), tab-separated data (`.tsv`) and git's config files (`.gitconfig`,
   `.gitmodules`); any other file follows its indented lines (`indent_style/1`: the first 1000
   lines' indented ones vote, a tie or none is spaces). `spaces` and `tabs` force one. A Makefile
   (`Makefile`, `makefile`, `GNUmakefile`, `BSDmakefile`, `Makefile.am`/`.in`, `.mk`, `.mk.in`,
   `.mak`, `.make`) gets tabs whatever the setting: a recipe indented with spaces doesn't run.
   Shift+Tab inserts the other kind from Tab's (ADR-0026's 2026-11-10 amendment). An
   `.editorconfig` isn't read.
4. **Pure, and one command each.** Each assist is a pure function of the key, the cursor, the
   text and (for pairs) the tracked closers, returning the keymap's own action shape (or `nil` to
   let the plain keymap resolve the key); the loop asks them only while the setting is on. Every
   assist is one recorded command (the multi-line wrap two), so `Alt+Z` takes it back, and replay
   is unchanged. A key reads the text up to its line (more the further down the file, as other
   keys' work already does), and `indent_style/1` at most 1000 lines.
5. **A paste is not typed** ([ADR-0026](0026-terminal-input-model.md)'s 2026-11-09 amendment):
   with bracketed paste on, a paste is one event, inserted as it is (one edit, the file's line
   break, control characters but tabs and breaks dropped), and no assist touches it.
6. **Deferred:** level 3, the syntax tree's indent queries (Elixir's `do`, Ruby's `end`, dedenting
   a typed closer): the catalog's grammar packages would have to carry `indents.scm`, and levels
   1–2 come first. Enter over a selection stays a bare line break (ADR-0029's amendment). The
   minibuffer doesn't get the assists.

## Consequences

- Three more General rows (`Indent with`, `Close pairs`, `Auto-indent`) and three keys in
  `settings.json`.
- Only the closers geex inserted are stepped over or deleted with their opener, so a closer the
  text needs is never swallowed; the price is a little view state in the loop (`closers`), kept
  pure by `Keymap.track/4` and pinned by a property (every tracked pair sits on a real opener and
  closer, around the cursor). Turning `auto_close` off restores literal typing.
- A paste goes in as it is: geex turns on the terminal's bracketed paste (ADR-0026's 2026-11-09
  amendment), so a paste is one event and no assist touches it. Before that, dogfooding found a
  pasted block typed key by key with its indents doubled and a closer added. A terminal without
  bracketed paste still types a paste key by key, assists and all; turn the settings off there.

Known limits (the re-verify's lower items, accepted): a file with mixed line endings gets the
first break's for each Enter; a combining mark typed alone inside a pair shifts the tracked
closer one column too far (the next step-over then types instead); a paste over 1 MB into the
minibuffer inserts each piece's first line; a mouse click moves the cursor without dropping the
pairs (their closers are still geex's).

## See

- `lib/geex/loop/keymap.ex` (`autoclose/5`, `unpair/3`, `track/4`, `wrap_closer/1`, `eol/1`,
  `newline/4`, `dedent/3`, `kind_opts/1`, `indent_with/3`, `indent_style/1`), `lib/geex/loop.ex`
  (`assist/5`, `live_pairs/1`, `fresh_closers/2`, `wrap/5`), `lib/geex/loop/settings.ex`,
  `lib/geex/input/paste.ex`.
- `test/geex/loop/assist_test.exs`, `test/geex/loop/keymap_test.exs` (the pair round trip and
  the indent law as properties).
