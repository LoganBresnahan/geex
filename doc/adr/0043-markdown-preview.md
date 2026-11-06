# ADR-0043: A read-only markdown preview, re-rendered on save

- **Status:** Accepted 2026-11-06. The maintainer decided the preview is read-only, re-rendered
  whole on save, and toggled by `Alt+Shift+P`. The rest (the trigger being the file on disk,
  opening beside the file, the parser, keeping the reader's place) was proposed in the same
  conversation and drafted here at the maintainer's request after a spike (§8), then revised the
  same day after an adversarial review against the code (§9), with three more of the maintainer's
  choices: save and take-in work from a preview, Page Up/Down join the parser, and `$…$` is math
  only by GitHub's rule. The maintainer accepted it the same day. Not built yet; the build plan is
  roadmap item 16.
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
  addresses), [ADR-0017](0017-reconcile-file-watch.md) (deletions on disk aren't reconciled),
  the invariant "world, not brain"
- **Amends, when built:** [ADR-0026](0026-terminal-input-model.md) (the parser reads Page
  Up/Down); [ADR-0031](0031-undo-redo-history-operations.md) (`Alt+Shift+Z` is no longer the one
  case-sensitive Alt chord); [ADR-0037](0037-pane-and-file-keys.md) (P is no longer
  case-insensitive, and `Alt+Shift+P` stays the editor's); [ADR-0038](0038-split-panes-and-tabs.md)
  §2 and §4 (a preview isn't one of its buffer's views, and what reaches the active buffer while
  a preview is current); [ADR-0039](0039-mouse.md) §3 and §7 (the mouse in a preview);
  [ADR-0040](0040-bare-geex-and-the-catalog.md) (a companion grammar, and the render queries in
  the catalog's load check)

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
docs (§8), and a review checked the whole design against the code before any of it was built
(§9).

## Decision

### 1. A preview tab, read-only

- **Opening it.** `Alt+Shift+P` on a markdown file's source tab opens its preview, and the source
  keeps focus:
  - with one pane, the editor splits side by side and the preview is the new pane's only tab;
  - where that split is refused for room (a half under 12 columns), the preview opens in the
    source's own pane, after the source tab, and is shown there;
  - with two or more panes, it opens in the next pane after the source's in reading order
    (`Panes.ids/1`, wrapping), after the tab that pane shows, so closing it shows that tab again
    (ADR-0038 §4).

  This goes through a new `Panes` call that adds a tab to a given pane without changing the
  current pane, the selection or the goal column; `Panes.split/2` and `switch/2` move focus and
  clear them. The preview records the pane it was opened from.
- **Closing it.** From a source tab, `Alt+Shift+P` closes every preview of its file. From a
  preview, it closes that preview and focuses the pane it was opened from. A split from a preview
  copies it, as a split copies any tab. The glyph and the typed verb `preview` do the same as the
  key, and the palette lists `preview`, its description naming `Alt+Shift+P`.
- **The key.** Every `Alt+letter` is taken (`lib/geex/loop/key_help.ex`). `Alt+Shift+P` is today a
  second `Alt+P` (`Keymap.resolve/3` matches `[?p, ?P]` for the next pane); it becomes the second
  case-sensitive Alt chord after `Alt+Shift+Z` ([ADR-0031](0031-undo-redo-history-operations.md)).
  As there, Caps Lock with `Alt+P` gives the shifted chord. The input parser reads `ESC P` as
  `{:alt, ?P}`, not as the start of a DCS string, and geex sends no query a terminal answers with
  one, so no reply can be mistaken for the key. From the tree, the edits pane and the output pane
  the chord does nothing: it acts on a file, so it stays the editor's, as `Alt+K` and `Alt+J` do
  ([ADR-0037](0037-pane-and-file-keys.md)). With Caps Lock on, `Alt+P` therefore no longer leaves
  a panel; Esc still does. `preview` typed or picked from a panel acts on the current file pane's
  shown tab, as `close` does. Key help (the settings view's Keys tab) gains a Panes row for the
  chord and a Mouse row for the glyph; the keymap's comment stops calling `Alt+Shift+Z` the one
  case-sensitive chord, and `keymap_test`'s case loop drops `?P`.
- **The glyph** sits between a tab's name and its ×, so the × keeps the label's last two columns.
  `TabBar.layout` learns which tabs carry it, and `TabBar.hit/2` answers `{:toggle_preview, i}` on
  its column. A click on it focuses that pane, shows the tab, then toggles, as a tab's × shows its
  tab before closing it. On a preview tab it is drawn lit, so a preview never reads as its source.
  It is one column in any font, checked as the split handles' braille was
  ([ADR-0038](0038-split-panes-and-tabs.md) §6): not East Asian Ambiguous, and present in common
  terminal fonts. `¶` (U+00B6) is Ambiguous and fails that check, so it marks the glyph's place in
  this text only.
- **A preview isn't one of its buffer's views.** A preview tab is
  `%{buffer, view: :preview, scroll, from}`: `scroll` counts rendered rows and `from` is the pane it
  was opened from. It has no `cursor`, `hscroll` or `hold`. A source tab is today's tab with
  `view: :source`. Only source tabs count as a buffer's views: `Panes.show/3`, `elsewhere?/2`,
  `in_other_pane?/3` and `close_pane/2`'s own-buffers set look at source tabs only.
  `Panes.buffers/1` and `drop_buffer/2` still include previews, so the loop keeps watching the
  buffer and a buffer that ends takes its previews with it.
  - Closing a buffer's last source tab (`Alt+K`, its ×, or its pane's ×) closes the buffer and its
    previews in every pane, and is refused while the buffer has unsaved edits (ADR-0038 §4).
  - Closing a preview (`Alt+K`, its ×, `Alt+Shift+P`) closes only that tab, never the buffer, and
    is never refused.
- **Opening the file lands on text.** The loop's own opens (`Alt+O`, the tree, `open`, the buffers
  picker, the edits pane's entries, the output pane's `path:line`) show the file's source tab
  through a source-only `Panes.show/3`, not through `adopt_active/2`, whose early return fires
  exactly when the file's preview is current. In a pane where the file has only a preview, a
  source tab is added and shown, so a jump lands on text. `adopt_active/2` keeps its early return
  for Session's echo of `{:geex_active_buffer, pid}`, which a preview becoming current sends.
- **The active buffer while a preview is current.** Its buffer is Session's active buffer
  (ADR-0038 §2), so the loop gates what reaches it. One predicate, "the current tab is a
  preview", is checked where actions come in: in `apply_editor_key/2` before `Keymap.resolve/3`
  (a preview's keys go to a handler of their own, as the output pane's do); in
  `submit_minibuffer/1`'s `line N` branch; in `apply_verb/2` after its `:quit` clause (the typed
  verbs and the palette); in `run_pipe/2` and `replace_selection/3`; and in the mouse press.
  - Allowed: the scroll keys (below); Esc and `Alt+N`; `Alt+M`, `Alt+I`; `Alt+P`/`O`/`K`/`T`/`L`/`Y`;
    `Alt+1`–`9`, `Alt+,`/`.`/`-`/`=`; `Alt+Shift+P`; `Ctrl-O` and `Alt+J`; `Ctrl-X`/`Q`/`C`; and the
    verbs open, find, buffers, close, preview, tab, split, vsplit, tree, edits, theme, mouse, new,
    mkdir, rename, delete, save, fast-forward, `!`, `!!`, no, quit and exit.
  - Save and take-in work from a preview, the maintainer's choice: neither needs a cursor, a save
    writes the buffer being edited and re-renders the preview, and a take-in merges the disk the
    preview already shows.
  - Everything else shows the hint: typing and every edit key, paste, cut, copy, selection, undo,
    redo, revert, revert-call, highlight, `Alt+G` and its verbs, `line N`, and `|`.

  `enter/1` makes a preview's buffer active and leaves Session's cursor as it is, and `leave/1`
  copies nothing into a preview, so Session never keeps a preview's position as the file's
  cursor. Every loop path that reads or writes a tab's `cursor`, `hscroll` or `hold` handles a
  preview first: `pane_view/5`, `draw_pane/6`, `enter/1`, `leave/1`, `adopt_active/2`,
  `apply_editor_key/2`, `press/4`, `select_to/5`, `wheel/4`, `scrolled/4`, `hold_scroll/5`, the
  scroll bar and drag paths, and `Panes.split/2`'s copy of a tab.
- **Scrolling.** Up/Down and `Alt+W`/`Alt+S` scroll a row (ADR-0026 §6's cluster for keyboards
  without arrows), Page Up/Down a page (the pane's text rows less one), Home/End to the top and
  bottom. The parser reads `ESC [ 5 ~` and `ESC [ 6 ~` as `{:key, :page_up}` and
  `{:key, :page_down}` instead of dropping them; its moduledoc and `parser_test`'s two dropped-key
  tests change, and modified forms such as `ESC [ 5 ; 5 ~` stay dropped. Everywhere but a preview
  the two keys resolve to `:ignore`, as today.
- **The mouse.** In a preview a press focuses the pane and follows a relative link under it,
  opening the target in the pane the preview came from (or the current file pane once that one
  is gone). It does nothing else: no caret, no selection, no double-click word, no Shift/Alt
  extend, no drag. The wheel and the vertical scroll bar move the row scroll, capped by the rows
  the loop holds for that tab's width; the bar is laid out from the rows, not the source. There's
  no horizontal scroll (every row fits, §5) and no hold, and a frame never derives a preview's
  scroll from a cursor.
- **Drawing.** `repaint/1` draws a preview from its rows: no gutter, highlight overlay, agent
  marks, selection or grid ruler (grid mode doesn't apply: there's no text to address), and the
  hardware cursor is hidden while it has focus. With a preview current, the status line shows the
  file, `[+]` or behind, and "preview", without a line:col or an author.
- **Which files.** A file whose installed grammar is Markdown (`.md`, `.markdown`), with
  `markdown_inline` installed too (§7). Without them the glyph isn't drawn, and the verb says what
  to install and opens Alt+Y on the missing row, as ADR-0040's hint does.

### 2. What it shows, and when it re-renders

- **The file, not the buffer.** The preview reads the file, so it shows what is saved: what git,
  an agent and GitHub see. It re-renders all of it, never a part.
- **Triggers.** The preview reads the file again when it opens, when the buffer's synced text
  moves, and when reconcile sees the disk change. The buffer gains one message,
  `{:geex_buffer_synced, buffer, sha256}`, sent wherever its synced baseline moves: a save, every
  fast-forward (`Alt+J`, or the one a save runs first, conflicted or not) and `mark_synced/1`.
  "On save" alone would miss a fast-forward that takes in an agent's write before the watcher
  reports it, or one that ends without a save (conflicts, a refused write): the watcher's later
  report then repeats the synced text, and `set_behind/2` sends nothing. The disk moving ahead is
  `{:geex_buffer_behind, buffer, behind}`, already sent for each new content. A read whose hash
  the preview last rendered is skipped.
- **Agents' writes.** An agent edits the file natively ([ADR-0032](0032-listener-first-agent-integration.md));
  reconcile marks the buffer behind and the buffer tells its subscribers, so the preview shows the
  agent's version before `Alt+J` takes it in. A save already refuses while the buffer is behind
  (`not_behind/1`), so no save silently replaces the version the preview is showing.
- **A read caught mid-write.** `Buffer.save` writes in place, so a read can land in the middle of
  a write. The preview draws a read only when its sha256 is the hash the buffer last gave for the
  disk: behind's while behind, otherwise the synced message's (`Buffer.status/1` gains it, for
  when the preview opens). On a mismatch it reads again after reconcile's 50 ms settle; after
  three tries it draws what it read and the header says the file is changing. Renders that pass
  are drawn as they finish, so an agent writing faster than one render can't freeze the view.
- **The file isn't there.** When the read fails the preview draws no rows, and its header says
  why: "not on disk" for `:enoent` (a buffer not saved yet, or a file removed), otherwise the
  reason. The next synced or behind message reads again. A removal on disk isn't seen, since
  reconcile skips an `:enoent` read (ADR-0017's deferred deletion handling), so the preview keeps
  its last render until the file comes back or the buffer saves, as the editor does today.
- **Renames.** The preview asks the buffer for its path (`Buffer.status/1`, which also gives the
  dirty and behind flags the header needs) at each render and keeps none, since `Buffer.rename/2`
  tells subscribers nothing. The loop re-renders a buffer's previews when its own rename
  finishes. A preview stays open across a rename, whatever the new name.
- **Line endings.** Each `\r\n` becomes `\n` before parsing, so a CRLF file renders like its LF
  twin; rows still map to the same source lines.
- **The header** names the file and says when the preview isn't the buffer: `[+]` (the tab's own
  marker) while the buffer has unsaved edits, "behind" while the disk is ahead of it, and "not on
  disk", "changing" or "stopped" when a read or the process fails.
- **Width.** The loop sends the preview process each preview tab's text width when the tab opens
  and whenever its pane's width changes (a terminal resize, each motion of a split or tree drag).
  The process keeps the last parse and lays out once per distinct width in its worker, never in
  the loop (laying out `testing.md` takes about 100 ms). It sends rows tagged
  `{buffer, width, render number}`; the loop draws a tab's rows only when the tag matches the
  tab's current width, and keeps the old rows, clipped or padded, until then (ADR-0035: one
  answer counts).
- **Theme.** A theme change only redraws: rows carry roles and capture names, never colours (§5).
- **Not live.** Refreshing as the buffer changes would change only the trigger; it can be a
  setting if it's ever wanted.

### 3. Off the key loop

- **Ownership.** The preview process is a `:temporary` child of `Geex.Markdown.PreviewSupervisor`,
  a DynamicSupervisor beside `ReactorSupervisor` that starts before the loop. It is registered as
  `{:markdown_preview, buffer}` in `Geex.Registry` and started idempotently: on
  `{:already_started, pid}` the loop subscribes to it, and if that call exits it starts one
  again. The loop subscribes when a preview tab for the buffer opens (in `put_panes`, where
  buffers are watched) and unsubscribes when the last one closes.
- **Lifetime.** It monitors its buffer and its subscribers. When the buffer or its last subscriber
  goes, it unregisters first (as `Reactor.stop/1` does), then stops, so a restarted loop leaves no
  orphan re-rendering for nobody, and a quick reopen can't subscribe to a process that is
  stopping.
- **Work.** Its init reads nothing. Reading, parsing, highlighting and layout run in a spawned,
  monitored worker, like the highlight reactor's pass ([ADR-0022](0022-capability-reactor.md);
  ADR-0035: monitored, not linked). It ignores the buffer messages it doesn't use, every
  keystroke's `{:geex_buffer_change, …}` among them.
- **Merging work.** Pending work merges into one request: a re-read once any open, synced or
  behind trigger has arrived (a re-read lays out again too), the newest width for each preview
  tab, and the latest save anchor (§6). Each part stays pending until a render started after it
  arrived has run. The reactor's rule, keeping only the latest request, would let a resize replace
  a pending re-read.
- **Failure.** The loop monitors each preview process ([ADR-0035](0035-the-loop-never-waits.md)).
  When one dies its tabs keep their rows and their header says the preview stopped; a failed
  render keeps the last rows and the header names the failure. Rendering has no correctness
  contract, so a crash costs a frame, never an edit.

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
- **The render handles** are cached as `Grammars.handle/1` caches its own: under their own keys,
  tagged with each install's sha256 so a replaced package is never used, and dropped when
  `Grammars.forget/1` runs (it gains those keys). They load only when both manifests' ABIs are in
  `Grammars.abi()`. If one isn't, or a render query doesn't compile against the installed
  package, the preview isn't offered and the verb says "Markdown preview needs an update
  (Alt+Y)", as ADR-0040 §5 does for highlighting; the engine's own message is never shown.
- **Reference links.** Tree-sitter can't see a document's link definitions, so it parses any `[x]`
  as a link. The layout links one only when the document defines its label; otherwise `[x]` is
  text, brackets and all.
- **Code blocks** are highlighted once per read by the installed grammar for their language, and
  the spans are kept with the parse as capture names, not styles (§5). An info string reaches a
  grammar through one alias table in `Geex.Markdown` (sh → bash, js → javascript, ex → elixir …),
  which `mix geex.render` uses too. Installing a grammar that a code block names re-renders the
  preview (ADR-0040 §4: an install takes effect without a restart).
- **The grammars' gaps the layout corrects.** A table cell's column comes from counting the
  unescaped pipes before it in the row's source (GFM's rule, a pipe inside a code span counting
  too), less one when the row starts with a pipe, because the block grammar gives an empty `||`
  no cell. A `$…$` span is math, drawn as code, only where GitHub reads it so: the opening `$` not
  followed by whitespace, and the closing `$` neither preceded by whitespace nor followed by a
  letter or digit. Otherwise its text is plain (the maintainer's choice), so prices and shell
  variables in prose stay text. One gap stays: a code span opened by two backticks and holding a
  run of three closes early (§8).
- **Not chosen:** pulldown-cmark (CommonMark-compliant, with byte ranges from `into_offset_iter`,
  but a new native dependency); MDEx (comrak, with positions in `MDEx.Sourcepos`, but a second
  precompiled NIF in every release target); Earmark (HTML-shaped tuples with no source positions,
  so the preview couldn't keep its place); a generic wasm renderer plugin (a plugin host with one
  user). If tree-sitter's leniency starts to matter, pulldown-cmark can produce the same tree.

### 5. Layout and drawing

- **Pure.** `Geex.Markdown.Layout.rows(tree, text, width, opts)` returns rows, each
  `%{runs: [{text, roles}], src: byte}`. Roles say what a run is (`:heading`, `:strong`, `:link`,
  `:code`, a table `:border` …). A code run carries the highlight captures covering it, narrowest
  first and, at equal width, the most dotted first (`{:captures, [name]}`). `Geex.Markdown.Style`
  turns roles into colours against the theme when drawing, taking the first capture the theme
  styles, which matches `Highlight.Paint.styles/2`. So neither the layout nor the preview process
  sees a theme, and the layout is tested by its values.
- **Widths are `Geex.Width` display widths**, a rendering concern only: the preview addresses
  nothing.
- **Spacing.** Blocks are a blank row apart; a tight list's items aren't (CommonMark's loose and
  tight lists, read from the blank lines in the source).
- **Theme fallbacks.** Themes style tree-sitter captures and few style markdown's, so each role
  tries the captures a theme might style for it (`markup.heading`, `text.title` …) and falls back
  to the palette: headings and links to `accent`, code's tint to `active_line_bg`, borders and
  rules to `line_number`. When the palette has no tint (`active_line_bg` is `:default`: the
  terminal theme with no OSC 11 answer, ADR-0040's default), every row of a code block starts with
  a `▏` bar in `line_number`, unlike the quote's `▌`, so a block with no language still reads as
  code.

| Markdown | In the preview |
|---|---|
| heading | bold in the theme's heading colour, else `accent`; its markers hidden, a closing run of `#` included; a full-width rule under H1 (`━`) and H2 (`─`) |
| emphasis, strong, strikethrough | italic, bold, struck through (`Geex.Cell` gains `:strike`, SGR 9) |
| inline code | the theme's literal colour on the code tint |
| fenced code | a tinted block headed by its language, highlighted; long lines cut with `…` |
| link | its text, underlined in the link colour; the URL hidden |
| list | `•` `◦` `▪` by depth, or numbers counting up from the first item's (CommonMark's start), aligned right, each item's delimiter kept; a hanging indent; task items `☐` `☑` |
| quote | a `▌` bar on every row, italic |
| table | box-drawing borders, a bold header, GFM alignment, cells placed by their pipes (§4); when too wide, each column starts at its 90th-percentile cell or its longest word, the widest gives way, and cells wrap |
| math (`$…$`) | as code where GitHub reads math (§4), otherwise as text |
| rule | `─` across the pane |
| image | `▣` and its alt text; pixels are the one thing out of reach |
| raw HTML, front matter | as written, in the comment colour |

### 6. Keeping the reader's place

- **Rows name their lines.** A row's `src` is the byte of the source line it draws, where it draws
  one: each table row, header and body (a border takes the row beside it), each line of fenced or
  indented code (the label row takes the fence line), and each line of raw HTML or front matter.
  A paragraph's or heading's wrapped rows keep the block's start; list and quote rows keep the
  starts of the blocks inside them. Block granularity isn't enough: §8's ADR index is one table,
  242 of its 266 rows at 100 columns.
- **Across a re-render** the loop, which owns every preview tab's scroll, notes the top row's
  source line and that row's offset among the consecutive rows sharing the line. Afterwards it
  scrolls to the first row of that line (or of the nearest earlier line that has rows) plus the
  offset, clamped to that run.
- **After the user's save** the rows scroll to the saved cursor's line instead, so the part just
  edited is in view. The anchor comes from the loop, not from the buffer's message: when its own
  save (`Ctrl-O`, `save`) succeeds from a source tab, the loop sends the buffer's preview process
  that tab's cursor line. The process attaches it to the first render it starts afterwards, and
  the loop scrolls those rows, in every preview of the buffer, to that line as above. A save from
  a preview, a fast-forward, or a change from outside keeps the reader's place. While a preview
  can be open, the loop's own save is the only one: MCP's `save_file` runs only under
  `mix geex.serve`, where there's no terminal.

### 7. Packaging

- **`markdown_inline` joins the catalog as Markdown's companion.** Its recipe uses markdown's
  repository, tag and commit, with the path `tree-sitter-markdown-inline`, no file endings or file
  names, and its own `tree-sitter-markdown-inline/queries/highlights.scm`. A new recipe key,
  carried into the manifest, marks it: `for: "markdown"`. The catalog test's rule that every
  grammar names a file ending exempts a grammar with `for`, and checks that `for` names a catalog
  grammar. Surfaces that list grammars as languages show it as Markdown's companion, not a
  language: Alt+Y's Languages tab and `geex install --list` label it, say, "Markdown inline
  (preview)" beside Markdown, and its install notice says the Markdown preview is available
  rather than "… highlighting installed". Recorded as an amendment to
  [ADR-0040](0040-bare-geex-and-the-catalog.md) and shipped in a catalog release.
- **The render queries ship with geex, not in the packages**, so `mix geex.catalog`'s load check
  also compiles them against the markdown and markdown_inline it builds, and the test fixtures are
  rebuilt from the recipe's commit whenever it's bumped. A grammar change that breaks the queries
  stops the catalog build instead of reaching users.
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
  never closes; and the index's ADR-0041 row wrote bare `|` inside a code span, which GFM splits
  the table cell on, so its status read "rollback" (escaped since). One is the grammar's: a code
  span opened by two backticks and holding a run of three (the Context's "typing … turns the
  rest of the file into code") closes on the first two backticks of that run, where CommonMark
  closes only on a run of the same length, so the span shows one backtick instead of three. Hard
  breaks, entities, escapes, images, autolinks, reference links with and without definitions,
  and code fenced inside a list item rendered right. Widths of 40, 20, 8 and 3 columns rendered
  every doc without an error.
- **What the search couldn't see.** The review (§9) probed constructs none of these docs contains
  and found five more differences from GitHub: an empty `||` table cell gets no node, `$5 and
  $10` parses as math, a heading's closing `#`s show, a `1. 1. 1.` list draws as written, and a
  CRLF file gains stray rows. §2, §4 and §5 now correct all five.
- **Time** for a whole render on the maintainer's machine (block parse, inline calls, code
  highlighting, layout):

| Doc | Size | Time |
|---|---|---|
| `README.md` (7 code blocks) | 4 KB | ~30 ms |
| ADR-0042 | 8 KB | ~15 ms |
| `doc/roadmap.md` | 46 KB | ~90 ms |
| `doc/testing.md` | 300 KB | 0.45–0.7 s, of which 1,918 inline calls 185–235 ms |

The README's figure is mostly the first highlight compiling its grammars; warm, its seven code
blocks highlight in under a millisecond.
- **Rough edges, none blocking:** two long columns share the width evenly (the ADR index, whose
  status column holds amendment notes); the H1 and H2 rules may be heavy in ADR-style docs; an
  inline `<br>` shows as raw HTML instead of a line break.

### 9. The review (2026-11-06)

Before anything was built, an adversarial review checked this ADR against the code: four
reviewers (focus and the cursor model; buffer messages and the process; keys, the tab bar and the
mouse; packaging and the renderer), each followed by a skeptic who opened every cited line and
tried to refute each finding. 36 findings survived and none were refuted; about 28 remain once
the ones two reviewers found independently are merged. All are folded into §1–7, and the findings
themselves, with their evidence, are kept in
[research/adr-0043-review.md](../research/adr-0043-review.md). The ones that changed the design:

- **A preview counted as one of its buffer's tabs.** Under ADR-0038 §4, closing the file's last
  source tab then skipped the unsaved-edits refusal ("still open in another pane") and left the
  buffer behind a read-only tab, and opening the file again from that pane showed the preview,
  since `Panes.show/3` finds a tab by its buffer alone (§1).
- **A focused preview's buffer was the active one with nothing gating it.** The typed verbs, the
  palette, `line N`, `|`, grid mode and the mouse reach the buffer without the keymap (§1).
- **"On save" missed fast-forwards.** One that takes in an agent's write and ends without a save
  is announced nowhere the preview hears (§2).
- **Keeping place by block lost the reader in tall blocks** (§6).

The maintainer then chose three of the open points: save and take-in work from a preview, Page
Up/Down join the parser, and `$…$` is math only by GitHub's rule.

## Consequences

- The editing path doesn't change. The preview never edits, and one predicate at the loop's entry
  points keeps it that way; the shared path, provenance, undo, replay and the cassette are
  untouched. It draws through `Screen` like every pane, and it addresses nothing, so width only
  ever renders.
- What an agent writes is readable, rendered, as soon as it's on disk, before it's taken in.
- The preview lags the buffer by design: unsaved edits aren't in it until a save, and the header
  says so.
- Side by side needs the width of two panes; where there's no room to split, the preview opens as
  a tab in the source's pane.
- The largest doc in the repo takes about half a second per change, off the key loop. Included
  ranges in the NIF are the first remedy.
- Tree-sitter's markdown is lenient, so an edge case can render differently from GitHub: a
  mis-render, never a mis-address. The layout corrects the gaps it can (§4); §8's code span is
  one it can't.
- Markdown needs a companion grammar installed. The buffer sends one new message and
  `Buffer.status/1` reports the synced hash; the parser reads two more keys; and five ADRs take
  amendments when this is built (see the header).
- **Deferred:** included ranges in the NIF, and with them injections for source highlighting;
  marking the blocks the last write changed, coloured by who wrote them (reconcile and the
  attestations know); OSC 8 links the terminal can open; refreshing as you type, as a setting;
  clickable task boxes (the preview is read-only); following links other than to relative
  markdown files; seeing a file removed on disk (ADR-0017's deferred item); images, never.
- **To settle when built:** the glyph (Neutral width, in common terminal fonts), and whether the
  header shows the save time.

## See

The spike: `lib/geex/markdown/parse.ex`, `lib/geex/markdown/layout.ex`,
`lib/geex/markdown/style.ex`, `lib/mix/tasks/geex.render.ex`, `test/geex/markdown/parse_test.exs`.
tree-sitter-markdown's README (its correctness note, and included ranges for the inline grammar);
[notes.md](../notes.md) (the 2026-06 frontend trade-off this narrows); [roadmap.md](../roadmap.md)
(injections); [testing.md](../testing.md) 2026-11-06 (the spike and the review);
[research/adr-0043-review.md](../research/adr-0043-review.md) (the review's findings and
evidence).
