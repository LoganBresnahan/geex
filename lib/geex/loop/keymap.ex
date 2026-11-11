defmodule Geex.Loop.Keymap do
  @moduledoc """
  The **minimal hardcoded keymap**: a key event + the current cursor + the buffer
  text → an action. Pure, so it is unit-tested without a terminal. The
  *configurable* keymap (from the user-config TOML,
  [ADR-0025](../../../doc/adr/0025-user-config-layer.md)) supersedes this later.

  Edits map to `%Command{}`s dispatched on the **one shared path**
  ([ADR-0003](../../../doc/adr/0003-one-shared-path.md)), so a human keystroke and
  an LLM edit travel the identical route. `resolve/3` returns:

    * `{:edit, command, new_cursor}` — dispatch the (unstamped) command, then move
      the cursor to `new_cursor`.
    * `{:move, new_cursor}` — a view-local cursor move, no edit.
    * `:minibuffer` — open the minibuffer (the command surface, ADR-0028).
    * `:quit` — exit the editor.
    * `:ignore` — an unhandled key.

  Cursor coordinates are `{line, col}`, 0-based, `col` in **graphemes** (Doc
  semantics); motion is clamped to the text and wraps at line ends.
  """

  alias Geex.Commands.{Delete, Insert, Replace}

  @type cursor :: {non_neg_integer(), non_neg_integer()}
  @type action ::
          {:edit, struct(), cursor()}
          | {:move, cursor()}
          | :minibuffer
          | :grid
          | :palette
          | :select_start
          | :select_all
          | :select_clear
          | :copy
          | :cut
          | :paste
          | :undo
          | :redo
          | :revert_hunk
          | :revert_call
          | :fast_forward
          | :next_pane
          | :find_file
          | :close
          | :toggle_tree
          | :toggle_edits
          | :split_rows
          | :split_cols
          | :tab_prev
          | :tab_next
          | {:tab, non_neg_integer()}
          | :save
          | :quit
          | :ignore

  # The lines `indent_style/1` reads (roadmap item 18.7).
  @indent_lines 1000

  @doc "Resolve a `Geex.Input.Parser` event against the cursor and buffer text."
  @spec resolve(tuple(), cursor(), String.t()) :: action()
  def resolve(event, cursor, text)

  # Printable grapheme → insert it, advance one column.
  def resolve({:char, g}, {line, col}, _text),
    do: {:edit, insert(line, col, g), {line, col + 1}}

  # Enter → newline; cursor to the start of the new line.
  def resolve({:key, :enter}, {line, col}, text),
    do: {:edit, insert(line, col, eol(text)), {line + 1, 0}}

  # Tab → the default tab size's spaces; the loop passes the setting and the file's indent
  # style to `indent/3`. Shift+Tab → the other kind, which the loop works out the same way
  # (`other_indent/1`); without the loop's context, a tab.
  def resolve({:key, :tab}, cursor, _text), do: indent(cursor, 2, :spaces)
  def resolve({:key, :shift_tab}, cursor, _text), do: indent(cursor, 2, :tabs)

  # Backspace within a line → delete the grapheme before the cursor.
  def resolve({:key, :backspace}, {line, col}, _text) when col > 0,
    do: {:edit, delete(line, col - 1), {line, col - 1}}

  # Backspace at column 0 → join onto the previous line (delete the newline). Delete
  # is single-line, so the join is a Replace across the line boundary.
  def resolve({:key, :backspace}, {line, 0}, text) when line > 0 do
    prev = line_len(text, line - 1)
    {:edit, join(line, prev), {line - 1, prev}}
  end

  def resolve({:key, :backspace}, {0, 0}, _text), do: :ignore

  # Delete → the grapheme under the cursor; at a line's end it joins the next line (the
  # mirror of Backspace at column 0). The cursor stays put.
  def resolve({:key, :delete}, {line, col} = cursor, text) do
    cond do
      col < line_len(text, line) -> {:edit, delete(line, col), cursor}
      line < last_line(text) -> {:edit, join(line + 1, col), cursor}
      true -> :ignore
    end
  end

  # Home / End → the start or end of the line (the same as Alt+R / Alt+F).
  def resolve({:key, :home}, cursor, _text), do: {:move, line_start(cursor)}
  def resolve({:key, :end}, cursor, text), do: {:move, line_end(cursor, text)}

  # Arrows → move the cursor, clamped to the text, wrapping at line ends.
  def resolve({:key, :left}, cursor, text), do: {:move, left(cursor, text)}
  def resolve({:key, :right}, cursor, text), do: {:move, right(cursor, text)}
  def resolve({:key, :up}, cursor, text), do: {:move, vert(cursor, text, -1)}
  def resolve({:key, :down}, cursor, text), do: {:move, vert(cursor, text, +1)}

  # Alt+M opens the minibuffer (ADR-0028); every other Alt+letter is motion — a left-hand
  # cluster around WASD that needs no arrow keys (ADR-0026), case-insensitive (Caps Lock):
  #   W A S D — up / left / down / right
  #   Q   E   — word back / forward
  #   R   F   — line start / end
  def resolve({:alt, c}, _cursor, _text) when c in [?m, ?M], do: :minibuffer
  # Grid mode (ADR-0027): Alt+G opens the minibuffer in `:grid` mode and shows the
  # display-column ruler + grid-line overlay for picking coordinates.
  def resolve({:alt, c}, _cursor, _text) when c in [?g, ?G], do: :grid
  # Command palette (ADR-0028 §3; on Alt+I since ADR-0037): opens the minibuffer in `:palette`
  # mode — a fuzzy browser over `Geex.Command.Catalog`. Inside it, Alt+W/Alt+S (the editor's
  # own up/down) move the highlight; the loop owns that, not the keymap.
  def resolve({:alt, c}, _cursor, _text) when c in [?i, ?I], do: :palette
  # Undo / redo (ADR-0031): Alt+Z undoes, Alt+Shift+Z redoes — these are case-*sensitive*
  # (the terminal sends `M-z` vs `M-Z`), as Alt+P and Alt+Shift+P are (ADR-0043): the two Alt
  # chords where shift means something other than the same action. History operations, not edits; the loop runs them on the buffer.
  def resolve({:alt, ?z}, _cursor, _text), do: :undo
  def resolve({:alt, ?Z}, _cursor, _text), do: :redo

  # Revert the agent's (or outside) change under the cursor, one hunk, keeping later edits
  # (ADR-0033 §7). `revert-call` (the whole tool call) is typed or picked from the palette.
  def resolve({:alt, c}, _cursor, _text) when c in [?u, ?U], do: :revert_hunk
  # The panes and files (ADR-0037):
  #   Alt+P — the next pane (tree · editor · edits); Alt+Shift+P — a markdown file's preview
  #           (ADR-0043), case-sensitive like Alt+Shift+Z, so Caps Lock with Alt+P gives it too
  #   Alt+O — open a file (Alt+Shift+O can't arrive: it sends `ESC O`, an SS3 prefix)
  #   Alt+K — close the file (refused with unsaved edits)
  #   Alt+T — show or hide the file tree;  Alt+L — show or hide the edits pane
  #   Alt+J — fast-forward: take in the file's change on disk, which an open buffer holds until
  #           you ask (ADR-0034 §1), merging your unsaved edits
  def resolve({:alt, ?p}, _cursor, _text), do: :next_pane
  def resolve({:alt, ?P}, _cursor, _text), do: :toggle_preview
  def resolve({:alt, c}, _cursor, _text) when c in [?o, ?O], do: :find_file
  def resolve({:alt, c}, _cursor, _text) when c in [?k, ?K], do: :close
  def resolve({:alt, c}, _cursor, _text) when c in [?t, ?T], do: :toggle_tree
  def resolve({:alt, c}, _cursor, _text) when c in [?l, ?L], do: :toggle_edits
  def resolve({:alt, c}, _cursor, _text) when c in [?j, ?J], do: :fast_forward
  # Split panes and tabs (ADR-0038):
  #   Alt+-  split the pane top and bottom;  Alt+=  split it side by side
  #   Alt+,  the previous tab;  Alt+.  the next tab;  Alt+1..9  tab 1 to 9
  def resolve({:alt, ?-}, _cursor, _text), do: :split_rows
  def resolve({:alt, ?=}, _cursor, _text), do: :split_cols
  def resolve({:alt, ?,}, _cursor, _text), do: :tab_prev
  def resolve({:alt, ?.}, _cursor, _text), do: :tab_next
  def resolve({:alt, d}, _cursor, _text) when d in ?1..?9, do: {:tab, d - ?1}
  # Selection (ADR-0029): Alt+H starts a selection at the cursor (motion then extends it),
  # Alt+B selects the whole buffer ("highlight all"), Alt+N / Esc clear. The loop owns the
  # live selection.
  def resolve({:alt, c}, _cursor, _text) when c in [?h, ?H], do: :select_start
  def resolve({:alt, c}, _cursor, _text) when c in [?b, ?B], do: :select_all
  # Clear the selection: Alt+N (the reliable, atomic "no/cancel" — a bare Esc lingers in
  # the parser's leftover, so it only lands when the next key arrives) and Esc.
  def resolve({:alt, c}, _cursor, _text) when c in [?n, ?N], do: :select_clear
  def resolve({:key, :esc}, _cursor, _text), do: :select_clear
  # Clipboard (ADR-0015): copy/cut act on the selection (or do nothing), paste inserts at
  # the cursor — or replaces the selection. Alt+X is distinct from Ctrl-X (quit).
  def resolve({:alt, c}, _cursor, _text) when c in [?c, ?C], do: :copy
  def resolve({:alt, c}, _cursor, _text) when c in [?x, ?X], do: :cut
  def resolve({:alt, c}, _cursor, _text) when c in [?v, ?V], do: :paste
  def resolve({:alt, c}, cursor, text), do: alt_motion(lower(c), cursor, text)

  # Save (ADR-0026 reserved Ctrl-O for it — the CUA Ctrl-S is XOFF/flow-control, which froze
  # the tty until `Geex.TerminalIO` turned flow control off). An operation, not an edit.
  def resolve({:ctrl, c}, _cursor, _text) when c in [?o, ?O], do: :save

  # Quit. Ctrl-Q (XON) and Ctrl-C (SIGINT) reach geex because `Geex.TerminalIO` turns the
  # tty's flow control and signal keys off; where it can't, Ctrl-X still works.
  def resolve({:ctrl, c}, _cursor, _text) when c in [?x, ?q, ?c], do: :quit

  def resolve(_event, _cursor, _text), do: :ignore

  ## Command builders — Insert/Delete/Replace.parse are pure (validate → struct).

  defp insert(line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    cmd
  end

  defp delete(line, col, count \\ 1) do
    {:ok, cmd} = Delete.parse(%{line: line, col: col, count: count})
    cmd
  end

  # Replace line `line`'s first `len` graphemes with `text`.
  defp replace_head(line, len, text) do
    {:ok, cmd} =
      Replace.parse(%{start_line: line, start_col: 0, end_line: line, end_col: len, text: text})

    cmd
  end

  defp join(line, prev) do
    {:ok, cmd} =
      Replace.parse(%{
        start_line: line - 1,
        start_col: prev,
        end_line: line,
        end_col: 0,
        text: ""
      })

    cmd
  end

  ## Cursor motion, clamped to the text.

  defp left({line, col}, _text) when col > 0, do: {line, col - 1}
  defp left({line, 0}, text) when line > 0, do: {line - 1, line_len(text, line - 1)}
  defp left({0, 0}, _text), do: {0, 0}

  defp right({line, col}, text) do
    cond do
      col < line_len(text, line) -> {line, col + 1}
      line < last_line(text) -> {line + 1, 0}
      true -> {line, col}
    end
  end

  defp vert({line, col}, text, dir) do
    new_line = clamp(line + dir, 0, last_line(text))
    {new_line, min(col, line_len(text, new_line))}
  end

  defp lines(text), do: String.split(text, "\n")
  defp last_line(text), do: length(lines(text)) - 1
  # A line's length for the cursor: a CRLF line's trailing `\r` is its end, not a place the
  # cursor stops after (the review of roadmap item 19: End then typing wrote past the `\r`, and
  # Backspace or Delete at a line's end left a stray one).
  defp line_len(text, line),
    do: text |> lines() |> Enum.at(line, "") |> String.replace_suffix("\r", "") |> String.length()

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc """
  The way a resizing key moves the focused pane's edge (roadmap item 18.8): Alt with an arrow.
  `nil` for any other key (`Alt+Shift+W/A/S/D` resized until 2026-11-11).

      iex> Enum.map([{:alt, :left}, {:alt, ?W}, {:alt, ?w}, {:key, :up}], &Geex.Loop.Keymap.resize_dir/1)
      [:left, nil, nil, nil]
  """
  @spec resize_dir(tuple()) :: :up | :down | :left | :right | nil
  def resize_dir({:alt, dir}) when dir in [:up, :down, :left, :right], do: dir
  def resize_dir(_event), do: nil

  @doc """
  What Tab does at `cursor` (roadmap item 18.7): a real tab in a file that indents with tabs
  (`:tabs`), else `tab_size` spaces. Shift+Tab is the other kind (`other_indent/1`).

      iex> Geex.Loop.Keymap.indent({3, 1}, 4, :spaces) |> elem(2)
      {3, 5}
      iex> {:edit, %{text: "\\t"}, cursor} = Geex.Loop.Keymap.indent({3, 1}, 4, :tabs)
      iex> cursor
      {3, 2}
  """
  @spec indent(cursor(), pos_integer(), :tabs | :spaces) :: action()
  def indent({line, col}, _tab_size, :tabs), do: {:edit, insert(line, col, "\t"), {line, col + 1}}

  def indent({line, col}, tab_size, :spaces),
    do: {:edit, insert(line, col, String.duplicate(" ", tab_size)), {line, col + tab_size}}

  # Files that need tabs: a Makefile's recipe lines must start with one (roadmap item 19).
  @tabs_required ~w(Makefile makefile GNUmakefile BSDmakefile)
  @tabs_required_ext ~w(.mk .mak .make)
  # Files whose kind indents with tabs by convention: Go (gofmt), tab-separated data, git's
  # config files.
  @tabs_by_kind ~w(go.mod go.work .gitconfig .gitmodules)
  @tabs_by_kind_ext ~w(.go .tsv)

  @doc """
  What Shift+Tab inserts where Tab inserts `style` (ADR-0026's 2026-11-10 amendment): the other
  kind, so a tab can be typed where Tab gives spaces, and spaces where it gives a tab (in Go, a
  Makefile, a tab-indented file).

      iex> {Geex.Loop.Keymap.other_indent(:spaces), Geex.Loop.Keymap.other_indent(:tabs)}
      {:tabs, :spaces}
  """
  @spec other_indent(:tabs | :spaces) :: :tabs | :spaces
  def other_indent(:spaces), do: :tabs
  def other_indent(:tabs), do: :spaces

  @doc """
  What one indent level is in the file at `path` holding `text` (roadmap item 19), by the
  "Indent with" setting: `:follow` (the default) gives tabs to a file whose kind uses them (Go,
  tab-separated data, git's config files) and otherwise follows its indented lines
  (`indent_style/1`); `:spaces` and `:tabs` force one. A Makefile gets tabs whatever the
  setting, since a recipe indented with spaces doesn't run.

      iex> Geex.Loop.Keymap.indent_with("", "/p/main.go", :follow)
      :tabs
      iex> Geex.Loop.Keymap.indent_with("x:\\n  y\\n", "/p/Makefile", :spaces)
      :tabs
      iex> Geex.Loop.Keymap.indent_with("\\tx\\n", "/p/a.py", :spaces)
      :spaces
      iex> Geex.Loop.Keymap.indent_with("\\tx\\n", "/p/a.py", :follow)
      :tabs
      iex> Geex.Loop.Keymap.indent_with("", nil, :follow)
      :spaces
  """
  @spec indent_with(String.t(), String.t() | nil, :follow | :spaces | :tabs) :: :tabs | :spaces
  def indent_with(text, path, setting) do
    name = if path, do: Path.basename(path), else: ""
    ext = Path.extname(name)

    cond do
      makefile?(name) -> :tabs
      setting in [:spaces, :tabs] -> setting
      name in @tabs_by_kind or ext in @tabs_by_kind_ext -> :tabs
      true -> indent_style(text)
    end
  end

  # A Makefile: its usual names, an automake or configure template of one (`Makefile.am`,
  # `Makefile.in`, `rules.mk.in`), or a `.mk` (not cargo-make's `Makefile.toml`).
  defp makefile?(name) do
    name in @tabs_required or Path.extname(name) in @tabs_required_ext or
      (String.starts_with?(name, ["Makefile.", "makefile.", "GNUmakefile."]) and
         Path.extname(name) in [".am", ".in", ".inc"]) or
      String.ends_with?(name, [".mk.in", ".mk.am"])
  end

  @doc """
  What `text` indents with (roadmap item 18.7, the maintainer's "follows the file"): `:tabs`
  when more of its indented lines start with a tab than with a space, else `:spaces` (so a file
  with no indented line gets spaces). A line of only whitespace doesn't count. Only the first
  #{@indent_lines} lines are read, so the cost doesn't grow with the file (ADR-0035).

      iex> Geex.Loop.Keymap.indent_style("func f() {\\n\\tx := 1\\n\\ty := 2\\n  // aside\\n}")
      :tabs
      iex> Geex.Loop.Keymap.indent_style("def f\\n  x\\n\\ty\\n  z\\nend")
      :spaces
      iex> Geex.Loop.Keymap.indent_style("no indent at all\\n")
      :spaces
  """
  @spec indent_style(String.t()) :: :tabs | :spaces
  def indent_style(text) when is_binary(text) do
    {tabs, spaces} =
      text
      |> String.split("\n", parts: @indent_lines + 1)
      |> Enum.take(@indent_lines)
      |> Enum.reduce({0, 0}, fn line, {t, s} ->
        cond do
          String.trim(line) == "" -> {t, s}
          String.starts_with?(line, "\t") -> {t + 1, s}
          String.starts_with?(line, " ") -> {t, s + 1}
          true -> {t, s}
        end
      end)

    if tabs > spaces, do: :tabs, else: :spaces
  end

  ## Typing assists (roadmap item 19, ADR-0045): pairs closed as you type them, and the indent
  ## kept on Enter. Each returns an action, or `nil` when the key should act as it does without
  ## them; the loop asks only while the setting is on. Every edit is one command, so one Alt+Z
  ## takes it back. Pure: the closers geex inserted (`track/4`) are the loop's view state, passed
  ## in.

  @pairs %{"(" => ")", "[" => "]", "{" => "}", "'" => "'", "\"" => "\"", "`" => "`"}
  @openers ["(", "[", "{"]
  @closers [")", "]", "}"]
  @quotes ["'", "\"", "`"]
  # A pair closes only before these, or a line's end (as VS Code's `autoCloseBefore`): typing
  # `(` in front of a word gives just `(`.
  @close_before [" ", "\t", ")", "]", "}", ">", ";", ":", ".", ",", "="]

  # The kinds of file the assists treat differently (`kind_opts/1`).
  @prose_ext ~w(.md .markdown .txt .rst .adoc .org)
  @lisp_ext ~w(.el .lisp .cl .clj .cljs .cljc .edn .scm .rkt)
  @tex_ext ~w(.tex .sty .cls)
  # Where `'` isn't a string's quote: an apostrophe, a lifetime or type variable, a character
  # literal or a name's prime, a Lisp's quote, LaTeX's closing quotes.
  @no_single_quote_ext @prose_ext ++
                         @lisp_ext ++
                         @tex_ext ++ ~w(.rs .ml .mli .fs .fsi .fsx .sml .sig .hs .lhs)
  # Where `` ` `` isn't a string's quote: a Lisp's quasiquote, an OCaml variant, LaTeX's opening
  # quotes.
  @no_backtick_ext @lisp_ext ++ @tex_ext ++ ~w(.ml .mli)
  # Where a line ending in `:` opens a block.
  @colon_ext ~w(.py .pyi .pyw .yaml .yml)
  # Data, where a line's leading tab or space is a field, not an indent.
  @no_indent_ext ~w(.tsv .csv)

  @typedoc "A pair geex closed as it was typed: its line, its opener's column, its closer's."
  @type pair :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  How the assists treat the file at `path` (roadmap item 19): `single_quote: false` where `'`
  isn't a string's quote (prose; Rust, OCaml, F#, SML, Haskell; the Lisps; LaTeX),
  `backtick: false` where `` ` `` isn't (the Lisps, OCaml, LaTeX), `colon: true` where a line
  ending in `:` opens a block (Python, YAML, Makefiles), `indent: false` for data (`.tsv`,
  `.csv`).

      iex> Geex.Loop.Keymap.kind_opts("/p/notes.md")
      [single_quote: false, backtick: true, colon: false, indent: true]
      iex> Geex.Loop.Keymap.kind_opts("/p/Makefile")
      [single_quote: true, backtick: true, colon: true, indent: true]
  """
  @spec kind_opts(String.t() | nil) :: keyword()
  def kind_opts(path) do
    name = if path, do: Path.basename(path), else: ""
    ext = Path.extname(name)

    [
      single_quote: ext not in @no_single_quote_ext,
      backtick: ext not in @no_backtick_ext,
      colon: ext in @colon_ext or makefile?(name),
      indent: ext not in @no_indent_ext
    ]
  end

  @doc """
  What a typed grapheme does with pairs closed as you type (roadmap item 19, ADR-0045):
  - an opener comes with its closer and the cursor between, only at a line's end or before a
    space or punctuation;
  - a quote does too, unless it comes after a letter, a digit, `_`, a closer or the same quote,
    or the cursor is inside a string (the line before it read for strings of all three quotes,
    a backslash in one escaping what follows), or it is a `'` or `` ` `` where that isn't a
    string's quote (`opts[:single_quote]`, `opts[:backtick]`);
  - a closer or quote typed in front of a closer geex inserted (`pairs`, VS Code's "auto" rule)
    steps over it; one already in the file, or typed, is typed again.
  A line's trailing `\r` (a CRLF file) is its end. `nil` when none applies.

      iex> {:edit, %{text: "()"}, {0, 2}} = Geex.Loop.Keymap.autoclose({:char, "("}, {0, 1}, "f", [])
      iex> Geex.Loop.Keymap.autoclose({:char, ")"}, {0, 2}, "f()", [{0, 1, 2}])
      {:move, {0, 3}}
      iex> Geex.Loop.Keymap.autoclose({:char, ")"}, {0, 2}, "f()", [])
      nil
      iex> Geex.Loop.Keymap.autoclose({:char, "\\""}, {0, 6}, "f\\"{x}", [])
      nil
      iex> Geex.Loop.Keymap.autoclose({:char, "'"}, {0, 3}, "don", [])
      nil
  """
  @spec autoclose(tuple(), cursor(), String.t(), [pair()], keyword()) :: action() | nil
  def autoclose(event, cursor, text, pairs, opts \\ [])

  def autoclose({:char, g}, {line, col}, text, pairs, opts) do
    l = line_body(text, line)
    col = min(col, String.length(l))
    before = String.slice(l, 0, col)
    next = String.at(l, col)
    prev = String.last(before)

    cond do
      (g in @closers or g in @quotes) and next == g and tracked?(pairs, line, col) ->
        {:move, {line, col + 1}}

      g in @openers and closes_before?(next) ->
        {:edit, insert(line, col, g <> @pairs[g]), {line, col + 1}}

      g in @quotes and closes_before?(next) and opens_string?(g, before, prev, opts) ->
        {:edit, insert(line, col, g <> g), {line, col + 1}}

      true ->
        nil
    end
  end

  def autoclose(_event, _cursor, _text, _pairs, _opts), do: nil

  # Whether a quote typed after `before` opens a string (and so gets its closer).
  defp opens_string?(g, before, prev, opts) do
    (g != "'" or Keyword.get(opts, :single_quote, true)) and
      (g != "`" or Keyword.get(opts, :backtick, true)) and not word?(prev) and
      prev not in [g | @closers] and string_at(before) == nil
  end

  # The string `before` ends inside, read left to right: nil outside any, else its quote. Inside
  # a string a backslash escapes the next grapheme, and the other quotes are text (the review of
  # item 19: `x = "it's" + '` is outside a string, so its `'` opens one).
  defp string_at(before), do: before |> String.graphemes() |> scan_strings(nil)

  defp scan_strings([], open), do: open
  defp scan_strings(["\\", _ | rest], open) when open != nil, do: scan_strings(rest, open)
  defp scan_strings([g | rest], nil) when g in @quotes, do: scan_strings(rest, g)
  defp scan_strings([open | rest], open), do: scan_strings(rest, nil)
  defp scan_strings([_ | rest], open), do: scan_strings(rest, open)

  defp tracked?(pairs, line, col), do: Enum.any?(pairs, &match?({^line, _, ^col}, &1))

  @doc """
  Backspace between an empty pair geex closed (`(|)`, `"|"`) deletes both, as one edit (VS
  Code's "auto" rule: a pair typed by hand loses only its opener); `nil` otherwise.

      iex> {:edit, %{col: 1, count: 2}, {0, 1}} = Geex.Loop.Keymap.unpair({0, 2}, "f()", [{0, 1, 2}])
      iex> Geex.Loop.Keymap.unpair({0, 2}, "f()", [])
      nil
  """
  @spec unpair(cursor(), String.t(), [pair()]) :: action() | nil
  def unpair({line, col}, text, pairs) when col > 0 do
    l = line_body(text, line)
    prev = String.at(l, col - 1)

    if Map.has_key?(@pairs, prev) and String.at(l, col) == @pairs[prev] and
         tracked?(pairs, line, col),
       do: {:edit, delete(line, col - 1, 2), {line, col - 1}}
  end

  def unpair(_cursor, _text, _pairs), do: nil

  @doc """
  The pairs geex closed, after `action` (the result of `event` at `cursor`): a new pair is
  tracked, a single-line insert or delete shifts them (a delete that touches one drops it), a
  step-over drops the closer stepped over, a move keeps only the pairs the cursor is still
  inside, and anything else (Enter, a paste, an undo …) drops them all. Pure.

      iex> alias Geex.Loop.Keymap
      iex> pair = Keymap.autoclose({:char, "("}, {0, 1}, "f", [])
      iex> pairs = Keymap.track([], {:char, "("}, pair, {0, 1})
      [{0, 1, 2}]
      iex> Keymap.track(pairs, {:char, "x"}, Keymap.resolve({:char, "x"}, {0, 2}, "f()"), {0, 2})
      [{0, 1, 3}]
      iex> Keymap.track(pairs, {:key, :up}, {:move, {1, 0}}, {0, 2})
      []
  """
  @spec track([pair()], tuple(), action() | nil, cursor()) :: [pair()]
  def track(pairs, event, action, cursor)

  def track(pairs, event, {:edit, %Insert{line: l, col: c, text: t}, _to}, _cursor) do
    if String.contains?(t, "\n") do
      []
    else
      shifted = shift(pairs, l, c, String.length(t))

      case event do
        {:char, g} when is_map_key(@pairs, g) and t == g <> :erlang.map_get(g, @pairs) ->
          [{l, c, c + 1} | shifted]

        _ ->
          shifted
      end
    end
  end

  def track(pairs, _event, {:edit, %Delete{line: l, col: c, count: k}, _to}, _cursor) do
    pairs
    |> Enum.reject(fn {pl, o, cl} ->
      pl == l and (o in c..(c + k - 1) or cl in c..(c + k - 1))
    end)
    |> shift(l, c + k, -k)
  end

  def track(pairs, {:char, _}, {:move, {l, c2}}, {l, c}) when c2 == c + 1,
    do: Enum.reject(pairs, &match?({^l, _, ^c}, &1)) |> inside(l, c2)

  def track(pairs, _event, {:move, {l, c}}, _cursor), do: inside(pairs, l, c)
  def track(_pairs, _event, _action, _cursor), do: []

  # The pairs on line `l` with the cursor at column `c` between their opener and closer.
  defp inside(pairs, l, c),
    do: Enum.filter(pairs, fn {pl, o, cl} -> pl == l and o < c and c <= cl end)

  # Shift by `n` the columns on line `l` at or after `from`.
  defp shift(pairs, l, from, n) do
    Enum.map(pairs, fn
      {^l, o, cl} -> {l, if(o >= from, do: o + n, else: o), if(cl >= from, do: cl + n, else: cl)}
      pair -> pair
    end)
  end

  @doc """
  The closer a typed grapheme wraps a selection with (an opener or a quote), or `nil`.

      iex> {Geex.Loop.Keymap.wrap_closer("["), Geex.Loop.Keymap.wrap_closer("x")}
      {"]", nil}
  """
  @spec wrap_closer(String.t()) :: String.t() | nil
  def wrap_closer(g) when g in @closers, do: nil
  def wrap_closer(g), do: Map.get(@pairs, g)

  @doc """
  The line break `text` uses: CRLF when its first one is, else LF.

      iex> {Geex.Loop.Keymap.eol("a\\r\\nb"), Geex.Loop.Keymap.eol("a\\nb"), Geex.Loop.Keymap.eol("a")}
      {"\\r\\n", "\\n", "\\n"}
  """
  @spec eol(String.t()) :: String.t()
  def eol(text) do
    case :binary.match(text, "\n") do
      {at, 1} when at > 0 -> if binary_part(text, at - 1, 1) == "\r", do: "\r\n", else: "\n"
      _ -> "\n"
    end
  end

  @doc """
  Enter with the indent kept (roadmap item 19): the new line starts with the current line's
  leading spaces and tabs (as much as is before the cursor), one `unit` more after an opener
  (`{ [ (`, and `:` where `opts[:colon]`) at the cursor, and between a pair (`{|}`) the closer goes
  to a line of its own with the cursor indented between. With the cursor at the end of a line of
  only spaces and tabs, that line is cleared and the new one keeps the indent. The break is the
  file's own (`eol/1`), and a CRLF line's `\r` is its end. With `indent: false` (data), a bare
  break.

      iex> {:edit, %{text: "\\n  "}, {1, 2}} = Geex.Loop.Keymap.newline({0, 3}, "  x", "  ")
      iex> {:edit, %{text: "\\n    \\n  "}, {1, 4}} = Geex.Loop.Keymap.newline({0, 4}, "  f{}", "  ")
      iex> {:edit, %{text: "\\n\\t"}, {1, 1}} = Geex.Loop.Keymap.newline({0, 3}, "if:", "\\t", colon: true)
      iex> {:edit, %{text: "\\n"}, {1, 0}} = Geex.Loop.Keymap.newline({0, 3}, "if:", "\\t")
      iex> {:edit, %{text: "\\n  "}, {1, 2}} = Geex.Loop.Keymap.newline({0, 2}, "  ", "  ")
  """
  @spec newline(cursor(), String.t(), String.t(), keyword()) :: action()
  def newline({line, col}, text, unit, opts \\ []) do
    eol = eol(text)
    l = line_body(text, line)
    len = String.length(l)
    col = min(col, len)

    if Keyword.get(opts, :indent, true) do
      indent_newline(line, col, l, len, unit, eol, Keyword.get(opts, :colon, false))
    else
      {:edit, insert(line, col, eol), {line + 1, 0}}
    end
  end

  defp indent_newline(line, col, l, len, unit, eol, colon?) do
    base = l |> leading_whitespace() |> String.slice(0, col)
    before = String.slice(l, 0, col)
    after_cursor = String.slice(l, col, len)
    opener = before |> String.trim_trailing(" ") |> String.trim_trailing("\t") |> String.last()
    # `:` opens a block where it does, but not ending a comment (`# Steps:`).
    colon? = colon? and not String.starts_with?(String.trim_leading(l), "#")
    openers = if colon?, do: ["{", "[", "(", ":"], else: ["{", "[", "("]

    cond do
      l != "" and leading_whitespace(l) == l and col == len ->
        {:edit, replace_head(line, len, eol <> l), {line + 1, len}}

      opener in @openers and first_non_blank(after_cursor) == @pairs[opener] ->
        inner = base <> unit
        {:edit, insert(line, col, eol <> inner <> eol <> base), {line + 1, String.length(inner)}}

      opener in openers ->
        inner = base <> unit
        {:edit, insert(line, col, eol <> inner), {line + 1, String.length(inner)}}

      true ->
        {:edit, insert(line, col, eol <> base), {line + 1, String.length(base)}}
    end
  end

  defp first_non_blank(s),
    do: s |> String.trim_leading(" ") |> String.trim_leading("\t") |> String.first()

  @doc """
  Backspace in a line's leading spaces takes one indent level, back to the previous stop of
  every `tab_size` columns (roadmap item 19); `nil` anywhere else (tabs are one grapheme each
  already).

      iex> {:edit, %{col: 2, count: 2}, {0, 2}} = Geex.Loop.Keymap.dedent({0, 4}, "    x", 2)
      iex> {:edit, %{col: 4, count: 1}, {0, 4}} = Geex.Loop.Keymap.dedent({0, 5}, "     x", 2)
      iex> Geex.Loop.Keymap.dedent({0, 5}, "    x", 2)
      nil
  """
  @spec dedent(cursor(), String.t(), pos_integer()) :: action() | nil
  def dedent({line, col}, text, tab_size) when col > 0 do
    before = String.slice(line_text(text, line), 0, col)

    if String.trim_leading(before, " ") == "" do
      n = if rem(col, tab_size) == 0, do: tab_size, else: rem(col, tab_size)
      {:edit, delete(line, col - n, n), {line, col - n}}
    end
  end

  def dedent(_cursor, _text, _tab_size), do: nil

  # Line `line` of `text`, reading only as far as it (the lines before it, not after).
  defp line_text(text, line), do: text |> String.split("\n", parts: line + 2) |> Enum.at(line, "")

  # Without a CRLF file's trailing `\r`, which is the line's end, not its content.
  defp line_body(text, line), do: text |> line_text(line) |> String.replace_suffix("\r", "")

  # The line's leading spaces and tabs, by grapheme: a space a combining mark joins isn't one,
  # nor is a form feed.
  defp leading_whitespace(l),
    do: l |> String.graphemes() |> Enum.take_while(&(&1 in [" ", "\t"])) |> Enum.join()

  defp closes_before?(nil), do: true
  defp closes_before?(g), do: g in @close_before
  defp word?(nil), do: false
  # A letter, digit or `_`, combining marks and all (a decomposed `é`).
  defp word?(g), do: String.match?(g, ~r/^[\p{L}\p{N}_]\p{M}*$/u)

  @doc """
  What a key types over a selection (roadmap item 18.1): Backspace and Delete delete it (`""`),
  a printable grapheme or Enter replaces it. `nil` for every other key, which acts as it does
  without a selection (Tab among them: indenting a selection is its own decision).

      iex> Enum.map([{:char, "x"}, {:key, :enter}, {:key, :backspace}, {:key, :delete}, {:key, :tab}],
      ...>   &Geex.Loop.Keymap.over_selection/1)
      ["x", "\\n", "", "", nil]
  """
  @spec over_selection(tuple()) :: String.t() | nil
  def over_selection({:char, g}), do: g
  def over_selection({:key, :enter}), do: "\n"
  def over_selection({:key, k}) when k in [:backspace, :delete], do: ""
  def over_selection(_event), do: nil

  ## Goal column — sticky horizontal position across vertical motion.
  #
  # Up/down should keep the column you started a vertical run at (snapping back when a
  # short line clamped you leftward), and if you were at a line *end* they should track
  # the end of each line. The keymap is pure, so the **goal** itself is held by the loop;
  # these helpers are how it decides what to keep and where to land.

  @doc "Is `event` a vertical motion (up/down, incl. Alt+W/S)? Vertical moves keep the goal."
  @spec vertical?(tuple()) :: boolean()
  def vertical?({:key, :up}), do: true
  def vertical?({:key, :down}), do: true
  def vertical?({:alt, c}) when c in [?w, ?W, ?s, ?S], do: true
  def vertical?(_event), do: false

  @doc """
  The goal column for a cursor — `:eol` when it sits at the line end (so a vertical run
  tracks the end of each line, an empty line included), else the grapheme column. The
  loop refreshes the goal with this after every *non-vertical* cursor change.
  """
  @spec goal_column(cursor(), String.t()) :: :eol | non_neg_integer()
  def goal_column({line, col}, text), do: if(col >= line_len(text, line), do: :eol, else: col)

  @doc """
  Resolve the landing column of a vertical move into `{line, _}` from the `goal`: the
  line end for `:eol`, else the goal clamped to the line. Reused across a run of up/down
  so the column is preserved instead of eroding toward the front.
  """
  @spec apply_goal(cursor(), :eol | non_neg_integer(), String.t()) :: cursor()
  def apply_goal({line, _col}, :eol, text), do: {line, line_len(text, line)}

  def apply_goal({line, _col}, goal, text) when is_integer(goal),
    do: {line, min(goal, line_len(text, line))}

  ## Alt-letter motion (the arrow-free clusters).

  defp alt_motion(?w, cursor, text), do: {:move, vert(cursor, text, -1)}
  defp alt_motion(?a, cursor, text), do: {:move, left(cursor, text)}
  defp alt_motion(?s, cursor, text), do: {:move, vert(cursor, text, +1)}
  defp alt_motion(?d, cursor, text), do: {:move, right(cursor, text)}
  defp alt_motion(?q, cursor, text), do: {:move, word_back(cursor, text)}
  defp alt_motion(?e, cursor, text), do: {:move, word_forward(cursor, text)}
  defp alt_motion(?r, cursor, _text), do: {:move, line_start(cursor)}
  defp alt_motion(?f, cursor, text), do: {:move, line_end(cursor, text)}
  defp alt_motion(_c, _cursor, _text), do: :ignore

  defp lower(c) when c in ?A..?Z, do: c + 32
  defp lower(c), do: c

  defp line_start({line, _col}), do: {line, 0}
  defp line_end({line, _col}, text), do: {line, line_len(text, line)}

  # Word motion within the line, whitespace-delimited. Forward lands on the next word's
  # start (skip the rest of this word, then the spaces); backward lands on the previous
  # word's start. Clamped to the line ends; line-crossing is a later refinement.
  defp word_forward({line, col}, text) do
    gs = line_tuple(text, line)
    n = tuple_size(gs)
    i = skip_fwd(min(col, n), gs, n, &non_space?/1)
    {line, skip_fwd(i, gs, n, &space?/1)}
  end

  defp word_back({line, col}, text) do
    gs = line_tuple(text, line)
    i = skip_bwd(min(col, tuple_size(gs)), gs, &space?/1)
    {line, skip_bwd(i, gs, &non_space?/1)}
  end

  defp skip_fwd(i, gs, n, pred),
    do: if(i < n and pred.(elem(gs, i)), do: skip_fwd(i + 1, gs, n, pred), else: i)

  defp skip_bwd(i, gs, pred),
    do: if(i > 0 and pred.(elem(gs, i - 1)), do: skip_bwd(i - 1, gs, pred), else: i)

  defp line_tuple(text, line),
    do: text |> lines() |> Enum.at(line, "") |> String.graphemes() |> List.to_tuple()

  defp space?(g), do: g == " " or g == "\t"
  defp non_space?(g), do: not space?(g)
end
