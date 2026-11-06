# ADR-0043: A read-only markdown preview, re-rendered on save

- **Status:** Proposed 2026-11-06. The maintainer decided the preview is read-only, re-rendered
  whole on save, and toggled by `Alt+Shift+P`. The rest (the trigger being the file on disk,
  opening beside the file, the parser, keeping the reader's place) was proposed in the same
  conversation, and the maintainer asked for it drafted here after a spike (§8). The preview
  itself isn't built.
- **Date:** 2026-11-06
- **Relates to:** [ADR-0038](0038-split-panes-and-tabs.md) (the preview is a tab in a pane),
  [ADR-0039](0039-mouse.md) (the tab's glyph), [ADR-0040](0040-bare-geex-and-the-catalog.md)
  (geex ships no grammar; the catalog gains `markdown_inline`),
  [ADR-0022](0022-capability-reactor.md) and [ADR-0035](0035-the-loop-never-waits.md)
  (rendering runs in a reactor, off the key loop), [ADR-0032](0032-listener-first-agent-integration.md)
  and [ADR-0034](0034-panes-tree-edits-hold.md) (agents edit natively; reconcile notices the
  file change), [ADR-0037](0037-pane-and-file-keys.md) (`Alt+P`, which stops answering to
  Shift), [ADR-0031](0031-undo-redo-history-operations.md) (`Alt+Shift+Z`, the first
  case-sensitive Alt chord), [ADR-0027](0027-grid-command-addressing.md) (width renders, never
  addresses), the invariant "world, not brain"

## Context

The maintainer wants to read a markdown file rendered while working on it: a button on its tab
that switches to the rendered view. The 2026-06 frontend decision ([notes.md](../notes.md), "Main
tradeoff") counted "embedded markdown render" among what a terminal gives up, with "anything
that wants pixels". Most of markdown wants cells, not pixels: headings, emphasis, code, lists,
quotes, tables and rules all draw in a terminal (glow, rich and render-markdown.nvim do it). What
a terminal can't do is images, heading sizes and proportional type.

Three designs were weighed on 2026-11-06 before this one:

- **Decorate the source in place** (render-markdown.nvim's way): every row stays its source line,
  markers are hidden and glyphs swapped, and the cursor's line shows raw. It reaches into the
  editing path: `Highlight.Paint` grows a decoration pass, clicks on decorated lines need a column
  cast of their own, grid mode needs an exception, and a stale hide (between a keystroke and the
  next parse) hides the wrong characters.
- **Reflow while editing** (Obsidian's way): paragraphs wrap to the pane and the block under the
  cursor expands to source. About twice the work of a read-only view: soft wrap with a cursor in
  it (geex has none), scrolling anchored as blocks change height, a layout cache per block
  composed every frame, and block boundaries that move mid-keystroke (typing `` ``` `` turns the
  rest of the file into code until the parse catches up).
- **A read-only view refreshed as the buffer changes**: this decision with another trigger.

The maintainer chose the read-only view, re-rendered whole on save. The editor stays exactly as
it is, the preview never sees half-typed text, and the rendering can be the nicest of the four
(wrapped paragraphs, bordered tables), because nothing in it is edited.

The open question was the parser. geex already runs tree-sitter grammars as wasm, and the
catalog's Markdown grammar is one, but its README says it is "not recommended … where
correctness is important": it was built for highlighting. A spike measured it on geex's own
docs (§8).

## Decision

### 1. A preview tab beside the file, read-only

- **Opening it.** `Alt+Shift+P` on a markdown file's tab opens its preview as a tab in the other
  pane, splitting the editor side by side when there is one pane; the source keeps focus. Pressed
  again, from the source or the preview, it closes the preview. A glyph on a markdown file's tab
  does the same (`TabBar.hit/2` gains `{:toggle_preview, i}`), and so do a typed verb, `preview`,
  and the palette. The glyph is one column in any font, checked as the split handles' braille
  was ([ADR-0038](0038-split-panes-and-tabs.md) §6); `¶` holds its place until it's drawn.
- **The key.** Every `Alt+letter` is taken (`lib/geex/loop/key_help.ex`). `Alt+Shift+P` is today a
  second `Alt+P` (`Keymap.resolve/3` matches `[?p, ?P]` for the next pane); it becomes the second
  case-sensitive Alt chord after `Alt+Shift+Z` ([ADR-0031](0031-undo-redo-history-operations.md)).
  As there, Caps Lock with `Alt+P` gives the shifted chord. The input parser reads `ESC P` as
  `{:alt, ?P}`, not as the start of a DCS string, and geex sends no query a terminal answers with
  one, so no reply can be mistaken for the key.
- **The tab.** A preview is a `Loop.Panes` tab marked `view: :preview`, on the file's buffer, so
  closing the file closes its previews. It has a scroll over rendered rows, which aren't source
  rows, and no cursor. Keys that would edit show a hint instead; arrows, Page Up/Down and the
  wheel scroll; a click on a relative link opens its target in the source pane. Grid mode
  ([ADR-0027](0027-grid-command-addressing.md)) doesn't apply: there's no text to address.
- **Which files.** A file whose installed grammar is Markdown (`.md`, `.markdown`), with
  `markdown_inline` installed too (§7). Without them the glyph isn't drawn and the verb says what
  to install.

### 2. It shows the file on disk, re-rendered whole when the file changes

- **The file, not the buffer.** The preview reads the file, so it shows what is saved: what git,
  an agent and GitHub see. It re-renders all of it, never a part, when the preview opens, when the
  buffer saves, and when reconcile sees the file change on disk.
- **Saves.** The buffer doesn't announce a save today: `handle_call(:save, …)` writes the file and
  replies. It gains one message to its subscribers, `{:geex_buffer_saved, buffer}`, beside the
  `{:geex_buffer_behind, …}` it already sends.
- **Agents' writes.** An agent edits the file natively ([ADR-0032](0032-listener-first-agent-integration.md));
  reconcile marks the buffer behind and the buffer tells its subscribers, so the preview shows the
  agent's version before `Alt+J` takes it in. A save already refuses while the buffer is behind
  (`not_behind/1`), so no save silently replaces the version the preview is showing.
- **The header** names the file and says when the preview isn't the buffer: `[+]` (the tab's own
  marker) while the buffer has unsaved edits, "behind" while the disk is ahead of it.
- **Width.** A changed width (a resized terminal, a dragged split) lays the last parse out again,
  without reading the file.
- **Not live.** Refreshing as the buffer changes would change only the trigger; it can be a
  setting if it's ever wanted.

### 3. Off the key loop

Each previewed buffer gets a preview process shaped like `Highlight.Reactor`
([ADR-0022](0022-capability-reactor.md)): it subscribes to the buffer, coalesces, keeps only the
latest request, and reads, parses and lays out in a task. `Geex.Loop` draws the rows when they
arrive and keeps the old ones up until then ([ADR-0035](0035-the-loop-never-waits.md)). It starts
with a buffer's first preview and stops with its last. Rendering has no correctness contract, so a
crash costs a frame, never an edit.

### 4. Parsing: the installed tree-sitter grammars, with geex's own queries

- **No new dependency and no new NIF function.** `TreeSitterWasm.highlight/3` returns every
  capture of the query a grammar was loaded with, as `{byte_start, byte_end, name}`. geex loads the
  Markdown grammar a second time with a structural query of its own (headings, paragraphs, lists,
  code, tables … instead of highlight scopes), and the nested captures rebuild the document as a
  tree of byte-ranged nodes (`Geex.Markdown.Parse`).
- **Inline markup** comes from the second grammar, `markdown_inline`, run over each `inline` node
  and each table cell. A container's line prefixes inside those ranges (a quote's `> `, a list's
  indent: `block_continuation` nodes) are turned to spaces first, so offsets don't move. The
  grammar's README parses all the ranges in one pass with `ts_parser_set_included_ranges`; one NIF
  call per range stands in. Included ranges are the first optimisation (§8: the calls are a third
  or more of the largest doc's time), and the same NIF work gives source highlighting the
  injections it lacks ([roadmap](../roadmap.md), "Not covered: injections").
- **Reference links.** Tree-sitter can't see a document's link definitions, so it parses any `[x]`
  as a link. The layout links one only when the document defines its label; otherwise `[x]` is
  text, brackets and all.
- **Code blocks** are highlighted by the installed grammar for their language, through the same
  NIF and theme as the editor.
- **Not chosen:** pulldown-cmark (CommonMark-compliant, with byte ranges from `into_offset_iter`,
  but a new native dependency); MDEx (comrak, with positions in `MDEx.Sourcepos`, but a second
  precompiled NIF in every release target); Earmark (HTML-shaped tuples with no source positions,
  so the preview couldn't keep its place); a generic wasm renderer plugin (a plugin host with one
  user). If tree-sitter's leniency starts to matter, pulldown-cmark can produce the same tree.

### 5. Layout and drawing

- **Pure.** `Geex.Markdown.Layout.rows(tree, text, width, opts)` returns rows, each
  `%{runs: [{text, roles}], src: byte}`. Roles say what a run is (`:heading`, `:strong`, `:link`,
  `:code`, a table `:border` …); `Geex.Markdown.Style` turns them into colours against the theme
  when drawing, so the layout never sees a theme and is tested by its values.
- **Widths are `Geex.Width` display widths**, a rendering concern only: the preview addresses
  nothing.
- **Spacing.** Blocks are a blank row apart; a tight list's items aren't (CommonMark's loose and
  tight lists, read from the blank lines in the source).
- **Theme fallbacks.** Themes style tree-sitter captures and few style markdown's, so each role
  tries the captures a theme might style for it (`markup.heading`, `text.title` …) and falls back
  to the palette: headings and links to `accent`, code's tint to `active_line_bg`, borders and
  rules to `line_number`.

| Markdown | In the preview |
|---|---|
| heading | bold in the theme's heading colour, else `accent`; markers hidden; a full-width rule under H1 (`━`) and H2 (`─`) |
| emphasis, strong, strikethrough | italic, bold, struck through (`Geex.Cell` gains `:strike`, SGR 9) |
| inline code | the theme's literal colour on the code tint |
| fenced code | a tinted block headed by its language, highlighted; long lines cut with `…` |
| link | its text, underlined in the link colour; the URL hidden |
| list | `•` `◦` `▪` by depth or numbers aligned right, with a hanging indent; task items `☐` `☑` |
| quote | a `▌` bar on every row, italic |
| table | box-drawing borders, a bold header, GFM alignment; when too wide, each column starts at its 90th-percentile cell or its longest word, the widest gives way, and cells wrap |
| rule | `─` across the pane |
| image | `▣` and its alt text; pixels are the one thing out of reach |
| raw HTML, front matter | as written, in the comment colour |

### 6. Keeping the reader's place

Every row carries `src`, the byte its block starts at. Before a re-render the preview notes the
source line of the block at its top; afterwards it scrolls to the row of the block holding that
line. When the user saved from a tab of the same file, the preview scrolls instead to the block
holding that tab's cursor, so the part just edited is in view. Block granularity is enough: the
preview has no cursor to place.

### 7. Packaging

- **`markdown_inline` joins the catalog**: a recipe from the same repository and tag as `markdown`
  (its `tree-sitter-markdown-inline` directory), with no file endings, since it is reached from
  markdown and never by a file's name. A separate package keeps ADR-0040's one grammar per
  package; the preview names both when one is missing. Recorded as an amendment to
  [ADR-0040](0040-bare-geex-and-the-catalog.md) and shipped in a catalog release.
- **Test fixtures** gain both grammars (about 420 KB of wasm each, MIT, listed in `NOTICE` like
  the elixir and json fixtures), so `mix test` exercises the parser, not only the tree builder.

### 8. Evidence: the spike (2026-11-06)

`mix geex.render FILE` prints a file as the preview would draw it (`--width`, `--theme`, `--map`
for a gutter of each block's source line, `--stats`, `--plain`). It stays as the development tool,
as `mix geex.highlight` does for highlighting, reading `markdown_inline` from the install once it
is packaged (until then from `_build/markdown_inline/parser.wasm`, built from the catalog's clone).

- **Correctness.** Seven of geex's docs (the README, `vision.md`, `roadmap.md`, `testing.md`, the
  ADR index, ADR-0042 and this ADR), about 6,100 rendered rows, were searched for markup that
  survived rendering. Two hits are the docs' own, and GitHub renders them the same way: in
  `doc/testing.md` line 2999 starts with `+ `, which CommonMark reads as a list item, so its `**`
  never closes; and the index's ADR-0041 row writes `|` inside a code span, which GFM splits the
  table cell on, so its status reads "rollback". One is the grammar's: a code span opened by two
  backticks and holding a run of three (the Context's "typing … turns the rest of the file into
  code") closes on the first two backticks of that run, where CommonMark closes only on a run of
  the same length, so the span shows one backtick instead of three. Hard breaks, entities,
  escapes, images, autolinks, reference links with and without definitions, and code fenced
  inside a list item rendered right. Widths of 40, 20, 8 and 3 columns rendered every doc
  without an error.
- **Time** for a whole render on the maintainer's machine (block parse, inline calls, code
  highlighting, layout):

| Doc | Size | Time |
|---|---|---|
| `README.md` (7 code blocks) | 4 KB | ~30 ms |
| ADR-0042 | 8 KB | ~15 ms |
| `doc/roadmap.md` | 46 KB | ~90 ms |
| `doc/testing.md` | 300 KB | 0.45–0.7 s, of which 1,918 inline calls 185–235 ms |

- **Rough edges, none blocking:** two long columns share the width evenly (the ADR index, whose
  status column holds amendment notes); the H1 and H2 rules may be heavy in ADR-style docs; an
  inline `<br>` shows as raw HTML instead of a line break.

## Consequences

- The editing path doesn't change. The preview never edits, so the shared path, provenance, undo,
  replay and the cassette are untouched; it draws through `Screen` like every pane; and it
  addresses nothing, so width only ever renders.
- What an agent writes is readable, rendered, as soon as it's on disk, before it's taken in.
- The preview lags the buffer by design: unsaved edits aren't in it until a save, and the header
  says so.
- Side by side needs the width of two panes; on a narrow terminal the preview takes the other half
  like any split.
- The largest doc in the repo takes about half a second per save, off the key loop. Included
  ranges in the NIF are the first remedy.
- Tree-sitter's markdown is lenient, so an edge case can render differently from GitHub (§8's
  code span is one): a mis-render, never a mis-address.
- Markdown needs a second grammar installed, and the buffer sends one new message.
- **Deferred:** included ranges in the NIF, and with them injections for source highlighting;
  marking the blocks the last write changed, coloured by who wrote them (reconcile and the
  attestations know); OSC 8 links the terminal can open; refreshing as you type, as a setting;
  clickable task boxes (the preview is read-only); following links other than to relative
  markdown files; images, never.
- **To settle when built:** the glyph, whether the header shows the save time, and whether the
  preview follows the cursor on save by default.

## See

The spike: `lib/geex/markdown/parse.ex`, `lib/geex/markdown/layout.ex`,
`lib/geex/markdown/style.ex`, `lib/mix/tasks/geex.render.ex`, `test/geex/markdown/parse_test.exs`.
tree-sitter-markdown's README (its correctness note, and included ranges for the inline grammar);
[notes.md](../notes.md) (the 2026-06 frontend trade-off this narrows); [roadmap.md](../roadmap.md)
(injections).
