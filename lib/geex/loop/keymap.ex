defmodule Geex.Loop.Keymap do
  @moduledoc """
  The **editor's keymap**: a command or one of the editor's own keys + the current cursor + the
  buffer text → an action. Pure, so it is unit-tested without a terminal. Which key runs which
  command is `Geex.Loop.Bindings`' (data, ADR-0047); the loop translates a bound key before it
  gets here, so this module never sees a chord, only `{:cmd, command}` and the keys that are
  the editor's own (characters, Enter, Tab, Shift+Tab, Backspace, Delete, Esc).

  Edits map to `%Command{}`s dispatched on the **one shared path**
  ([ADR-0003](../../../doc/adr/0003-one-shared-path.md)), so a human keystroke and
  an LLM edit travel the identical route. `resolve/3` returns:

    * `{:edit, command, new_cursor}` — dispatch the (unstamped) command, then move
      the cursor to `new_cursor`.
    * `{:move, new_cursor}` — a view-local cursor move, no edit.
    * an action the loop runs (`:undo`, `:minibuffer`, `{:tab, 2}` …).
    * `:ignore` — nothing to do.

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
          | :prev_pane
          | :toggle_preview
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

  # The commands that move the cursor (ADR-0026's arrows and Alt cluster, ADR-0047's names).
  @motions [
    :up,
    :down,
    :left,
    :right,
    :word_back,
    :word_forward,
    :line_start,
    :line_end,
    :matching_bracket
  ]

  # The commands that are the loop's actions as they are (`Geex.Loop`'s `apply_action/4`, and
  # the openers its `resolve_key/4` handles).
  @actions [
    :minibuffer,
    :grid,
    :palette,
    :select_start,
    :select_all,
    :select_clear,
    :copy,
    :cut,
    :paste,
    :undo,
    :redo,
    :revert_hunk,
    :revert_call,
    :fast_forward,
    :next_pane,
    :prev_pane,
    :toggle_preview,
    :find_file,
    :search,
    :next_match,
    :search_project,
    :search_all,
    :close,
    :toggle_tree,
    :toggle_edits,
    :split_rows,
    :split_cols,
    :tab_prev,
    :tab_next,
    :save,
    :quit,
    # The editing keys (ADR-0052): the loop works them out against the selection.
    :duplicate,
    :select_char,
    :select_word,
    :select_line,
    :comment,
    :move_up,
    :move_down,
    :move_left,
    :move_right,
    :move_word_back,
    :move_word_forward,
    :move_line_start,
    :move_line_end
  ]

  @doc """
  Resolve a command (`{:cmd, command}`, ADR-0047) or one of the editor's own keys against the
  cursor and buffer text.
  """
  @spec resolve(tuple(), cursor(), String.t()) :: action()
  def resolve(event, cursor, text)

  # Printable grapheme → insert it, advance one column.
  def resolve({:char, g}, {line, col}, _text),
    do: {:edit, insert(line, col, g), {line, col + 1}}

  # Enter → newline; cursor to the start of the new line.
  def resolve({:key, :enter}, {line, col}, text),
    do: {:edit, insert(line, col, eol(text)), {line + 1, 0}}

  # Tab → the default tab size's spaces; the loop passes the setting and the file's indent
  # style to `indent/3`, and indents a selection's lines (ADR-0050). Shift+Tab → un-indent the
  # cursor's line (`shift_lines/3`). `indent-other` (`Alt+1`) → the other kind, which the loop
  # works out the same way (`other_indent/1`); without the loop's context, a tab.
  def resolve({:key, :tab}, cursor, _text), do: indent(cursor, 2, :spaces)

  def resolve({:key, :shift_tab}, {line, _col} = cursor, text) do
    case shift_lines(text, {line, line}, {:unindent, 2}) do
      nil -> :ignore
      {cmd, shifts} -> {:edit, cmd, shift_caret(cursor, shifts)}
    end
  end

  def resolve({:cmd, :indent_other}, cursor, _text), do: indent(cursor, 2, :tabs)

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

  # Esc clears the selection, as the `no` command does.
  def resolve({:key, :esc}, _cursor, _text), do: :select_clear

  # A command (ADR-0047): the loop turned a bound key into one (`Geex.Loop.Bindings`), or it
  # was typed. Motion moves the cursor; the rest are the loop's actions, run as they are. A
  # command named for one of the editor's own keys (`line-break` …) never gets here: the loop
  # turns it into its key first, so the tab size, "Indent with" and the assists apply.
  def resolve({:cmd, command}, cursor, text) when command in @motions,
    do: {:move, motion(command, cursor, text)}

  def resolve({:cmd, {:tab, i}}, _cursor, _text), do: {:tab, i}
  def resolve({:cmd, command}, _cursor, _text) when command in @actions, do: command

  # A chord bound to nothing, and any other event: nothing.
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
    do:
      text
      |> lines()
      |> Enum.at(line, "")
      |> String.replace_suffix("\r", "")
      |> Geex.Text.length()

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc """
  What Tab does at `cursor` (roadmap item 18.7): a real tab in a file that indents with tabs
  (`:tabs`), else `tab_size` spaces. `indent-other` (`Alt+1`) is the other kind (`other_indent/1`).

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

  @doc """
  The lines a Tab or Shift+Tab over a selection's `range` acts on (ADR-0050 §1): its first through
  its last, less a last line it only reaches at column 0.

      iex> Geex.Loop.Keymap.selected_lines({{1, 4}, {3, 2}})
      {1, 3}
      iex> Geex.Loop.Keymap.selected_lines({{1, 0}, {3, 0}})
      {1, 2}
      iex> Geex.Loop.Keymap.selected_lines({{1, 2}, {1, 5}})
      {1, 1}
  """
  @spec selected_lines({cursor(), cursor()}) :: {non_neg_integer(), non_neg_integer()}
  def selected_lines({{l1, _}, {l2, 0}}) when l2 > l1, do: {l1, l2 - 1}
  def selected_lines({{l1, _}, {l2, _}}), do: {l1, l2}

  @doc """
  Indent (`{:indent, unit}`, `unit` a tab or spaces) or un-indent (`{:unindent, tab_size}`) lines
  `first..last` of `text` (ADR-0050): one replace from the first changed line's start to the
  last's end, and how many graphemes each changed line gained (or lost, negative), for
  `shift_caret/2`. `nil` when no line changes.

  Indenting leaves a blank line (empty, or only whitespace) alone. Un-indenting takes a leading tab, or leading spaces back
  to the previous tab stop, as Backspace does in leading spaces (`dedent/3`).

      iex> {cmd, shifts} = Geex.Loop.Keymap.shift_lines("a\\n\\nb\\n", {0, 2}, {:indent, "  "})
      iex> {cmd.text, shifts}
      {"  a\\n\\n  b", %{0 => 2, 2 => 2}}
      iex> {cmd, shifts} = Geex.Loop.Keymap.shift_lines("\\tx\\n   y\\nz", {0, 2}, {:unindent, 2})
      iex> {cmd.text, shifts}
      {"x\\n  y", %{0 => -1, 1 => -1}}
      iex> Geex.Loop.Keymap.shift_lines("x\\ny", {0, 1}, {:unindent, 4})
      nil
  """
  @spec shift_lines(
          String.t(),
          {non_neg_integer(), non_neg_integer()},
          {:indent, String.t()} | {:unindent, pos_integer()}
        ) ::
          {struct(), %{non_neg_integer() => integer()}} | nil
  def shift_lines(text, {first, last}, how) when first <= last do
    changes =
      text
      |> String.split("\n", parts: last + 2)
      |> Enum.slice(first..last//1)
      |> Enum.with_index(first)
      |> Enum.map(fn {l, i} -> {i, l, line_shift(l, how)} end)

    case for({i, _l, n} <- changes, n != 0, do: i) do
      [] ->
        nil

      changed ->
        {a, b} = {hd(changed), List.last(changed)}
        span = for {i, _l, _n} = c <- changes, i in a..b//1, do: c
        {_b, old_last, _n} = List.last(span)
        new_text = Enum.map_join(span, "\n", fn {_i, l, n} -> shifted(l, n, how) end)

        {:ok, cmd} =
          Replace.parse(%{
            start_line: a,
            start_col: 0,
            end_line: b,
            end_col: Geex.Text.length(old_last),
            text: new_text
          })

        {cmd, Map.new(for {i, _l, n} <- changes, n != 0, do: {i, n})}
    end
  end

  # How many graphemes a line gains (indent) or loses (un-indent, negative). A blank line (only
  # spaces and tabs, and a CRLF's \r) neither gains nor loses, so Tab then Shift+Tab gives every
  # line back (ADR-0050 §1).
  defp line_shift(l, how) do
    if blank_line?(l), do: 0, else: shift_of(l, how)
  end

  defp blank_line?(l), do: String.match?(l, ~r/\A[ \t]*\r?\z/)

  defp shift_of(_l, {:indent, unit}), do: Geex.Text.length(unit)
  defp shift_of("\t" <> _, {:unindent, _tab_size}), do: -1

  defp shift_of(l, {:unindent, tab_size}) do
    spaces = byte_size(l) - byte_size(String.trim_leading(l, " "))
    back = if rem(spaces, tab_size) == 0, do: tab_size, else: rem(spaces, tab_size)
    -min(back, spaces)
  end

  defp shifted(l, 0, _how), do: l
  defp shifted(l, _n, {:indent, unit}), do: unit <> l
  defp shifted(l, n, {:unindent, _}), do: binary_part(l, -n, byte_size(l) + n)

  @doc """
  Where a caret lands after `shift_lines/3` (ADR-0050 §4): moved with its text on a changed line,
  never past the line's start; at column 0 it stays, so whole lines stay whole.

      iex> shifts = %{1 => 2, 2 => -2}
      iex> Enum.map([{0, 3}, {1, 0}, {1, 3}, {2, 1}, {2, 5}], &Geex.Loop.Keymap.shift_caret(&1, shifts))
      [{0, 3}, {1, 0}, {1, 5}, {2, 0}, {2, 3}]
  """
  @spec shift_caret(cursor(), %{non_neg_integer() => integer()}) :: cursor()
  def shift_caret({line, col}, shifts) do
    case Map.get(shifts, line) do
      nil -> {line, col}
      _n when col == 0 -> {line, 0}
      n -> {line, max(col + n, 0)}
    end
  end

  # Files that need tabs: a Makefile's recipe lines must start with one (roadmap item 19).
  @tabs_required ~w(Makefile makefile GNUmakefile BSDmakefile)
  @tabs_required_ext ~w(.mk .mak .make)
  # Files whose kind indents with tabs by convention: Go (gofmt), tab-separated data, git's
  # config files.
  @tabs_by_kind ~w(go.mod go.work .gitconfig .gitmodules)
  @tabs_by_kind_ext ~w(.go .tsv)
  # Files whose trailing whitespace is content, kept whatever the trim-on-save setting says
  # (ADR-0054 §3): Markdown's two trailing spaces are a line break; a diff's are part of a line.
  @keeps_trailing_ext ~w(.md .markdown .mdx .diff .patch)

  @doc """
  Whether a save trims the file at `path`'s trailing whitespace when the setting is on
  (ADR-0054 §3): every file but Markdown, diffs and patches. A buffer with no path, never.

      iex> alias Geex.Loop.Keymap
      iex> {Keymap.trims_on_save?("/p/a.ex"), Keymap.trims_on_save?("/p/README.md")}
      {true, false}
      iex> {Keymap.trims_on_save?("/p/fix.PATCH"), Keymap.trims_on_save?(nil)}
      {false, false}
  """
  @spec trims_on_save?(String.t() | nil) :: boolean()
  def trims_on_save?(nil), do: false

  def trims_on_save?(path),
    do: String.downcase(Path.extname(path)) not in @keeps_trailing_ext

  @doc """
  What `indent-other` (`Alt+1`, ADR-0050) inserts where Tab inserts `style`: the other
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

  ## Editing keys (ADR-0052): duplicate lines, move them, comment them; select a character, a
  ## word or a line; the matching bracket; move selected text along its line. Each is pure: the
  ## loop dispatches what it gives as one recorded edit and moves the cursor and selection.

  # Line comments by extension (ADR-0052 §5). HTML, CSS, XML and Markdown have only block
  # comments and JSON none, so they aren't here. GNU as (`.s`) takes `#` on x86; NASM (`.asm`) `;`.
  @comment_exts [
    {"#",
     ~w(.ex .exs .py .pyi .rb .sh .bash .zsh .fish .yaml .yml .toml .pl .pm .r .R .conf .cfg .nix
        .cmake .ps1 .tf .jl .cr .coffee .nim .env .mk .awk .tcl .bzl .s .S)},
    {"//",
     ~w(.js .mjs .cjs .jsx .ts .mts .cts .tsx .rs .go .c .h .cc .cpp .cxx .hpp .hh .java .kt .kts
        .scala .swift .cs .dart .zig .php .groovy .gleam .proto .scss .less .sol .jsonc .glsl
        .wgsl .odin .v)},
    {"--", ~w(.sql .lua .hs .elm .ada .adb .ads .purs)},
    {";", ~w(.lisp .el .clj .cljs .cljc .edn .scm .rkt .asm .ini)},
    {"%", ~w(.erl .hrl .tex .sty .cls)},
    {"\"", ~w(.vim)}
  ]

  # Files known by name whose comments start with `#` (Makefiles are `makefile?/1`'s).
  @hash_names ~w(Dockerfile Containerfile Gemfile Rakefile Vagrantfile CMakeLists.txt .bashrc
                 .zshrc .profile .bash_profile .gitignore .gitattributes .dockerignore .env)

  # How far the matching bracket is looked for, in lines each way, so a press costs the same in
  # any size of file (ADR-0035).
  @bracket_lines 10_000
  # And at most this many graphemes, so one long line (minified code, a log line) costs no more
  # than many short ones (mod-verify's review of ADR-0052: a 2 MB line took over a second).
  @bracket_graphemes 200_000

  @bracket_open %{"(" => ")", "[" => "]", "{" => "}"}
  @bracket_close Map.new(@bracket_open, fn {o, c} -> {c, o} end)

  @doc """
  Copy lines `first..last` of `text` below themselves (ADR-0052 §1): an insert at the last line's
  end (before a CRLF line's `\\r`) of the file's line break and the lines, and how many lines the
  copy is below them, for `follow_lines/3`.

      iex> {cmd, n} = Geex.Loop.Keymap.duplicate_lines("a\\nb\\nc", {0, 1})
      iex> {cmd.line, cmd.col, cmd.text, n}
      {1, 1, "\\na\\nb", 2}
      iex> {cmd, 1} = Geex.Loop.Keymap.duplicate_lines("a\\r\\nb\\r\\n", {1, 1})
      iex> {cmd.line, cmd.col, cmd.text}
      {1, 1, "\\r\\nb"}
  """
  @spec duplicate_lines(String.t(), {non_neg_integer(), non_neg_integer()}) ::
          {struct(), pos_integer()}
  def duplicate_lines(text, {first, last}) when first <= last do
    bodies =
      text
      |> lines()
      |> Enum.slice(first..last//1)
      |> Enum.map(&String.replace_suffix(&1, "\r", ""))

    eol = eol(text)
    {insert(last, line_len(text, last), eol <> Enum.join(bodies, eol)), last - first + 1}
  end

  @doc """
  Swap lines `first..last` of `text` with the line above (`:up`) or below (`:down`) (ADR-0052
  §6): one replace over the lines and their neighbour, each line's ending staying where it was,
  and how far the lines moved (`-1` or `1`), for `follow_lines/3`. `nil` at the top or the bottom;
  the empty line after a final line break isn't one to swap with.

      iex> {cmd, d} = Geex.Loop.Keymap.move_lines("a\\nb\\nc\\n", {1, 1}, :up)
      iex> {cmd.start_line, cmd.end_line, cmd.text, d}
      {0, 1, "b\\na", -1}
      iex> {cmd, 1} = Geex.Loop.Keymap.move_lines("a\\r\\nb\\r\\nc", {0, 1}, :down)
      iex> cmd.text
      "c\\r\\na\\r\\nb"
      iex> Geex.Loop.Keymap.move_lines("a\\nb\\n", {1, 1}, :down)
      nil
  """
  @spec move_lines(String.t(), {non_neg_integer(), non_neg_integer()}, :up | :down) ::
          {struct(), -1 | 1} | nil
  def move_lines(text, {first, last}, dir) when first <= last do
    all = lines(text)
    top = if String.ends_with?(text, "\n"), do: length(all) - 2, else: length(all) - 1
    {a, b, d} = if dir == :up, do: {first - 1, last, -1}, else: {first, last + 1, 1}

    if a < 0 or b > top do
      nil
    else
      span = Enum.slice(all, a..b//1)
      bodies = Enum.map(span, &String.replace_suffix(&1, "\r", ""))
      ends = Enum.map(span, &if(String.ends_with?(&1, "\r"), do: "\r", else: ""))

      rotated =
        if dir == :up,
          do: tl(bodies) ++ [hd(bodies)],
          else: [List.last(bodies) | Enum.drop(bodies, -1)]

      new_text = rotated |> Enum.zip_with(ends, &(&1 <> &2)) |> Enum.join("\n")
      {replace({a, 0}, {b, Geex.Text.length(List.last(span))}, new_text), d}
    end
  end

  @doc """
  Where a caret lands after lines `first..last` moved `d` lines (`duplicate_lines/2`,
  `move_lines/3`): on one of them, it moves with it; at the start of the line after them (where a
  selection of whole lines ends), it moves too; elsewhere it stays.

      iex> Enum.map([{0, 2}, {1, 1}, {2, 3}, {3, 0}, {3, 1}], &Geex.Loop.Keymap.follow_lines(&1, {1, 2}, 2))
      [{0, 2}, {3, 1}, {4, 3}, {5, 0}, {3, 1}]
  """
  @spec follow_lines(cursor(), {non_neg_integer(), non_neg_integer()}, integer()) :: cursor()
  def follow_lines({line, col}, {first, last}, d) do
    if (line >= first and line <= last) or (line == last + 1 and col == 0),
      do: {line + d, col},
      else: {line, col}
  end

  @doc """
  The line comment for the file at `path` (ADR-0052 §5), by its name or extension, or `nil` for
  a file with only block comments (HTML, CSS), none (JSON) or one geex doesn't know.

      iex> Enum.map(["/p/a.ex", "/p/b.ts", "/p/Makefile", "/p/q.sql", "/p/c.css", nil], &Geex.Loop.Keymap.comment_marker/1)
      ["#", "//", "#", "--", nil, nil]
  """
  @spec comment_marker(String.t() | nil) :: String.t() | nil
  def comment_marker(nil), do: nil

  def comment_marker(path) do
    name = Path.basename(path)
    ext = Path.extname(name)

    cond do
      makefile?(name) or name in @hash_names -> "#"
      true -> Enum.find_value(@comment_exts, fn {marker, exts} -> ext in exts && marker end)
    end
  end

  @doc """
  Comment out lines `first..last` of `text` with `marker` (ADR-0052 §5), or take it off when
  every non-blank one has it: one replace from the first non-blank line to the last, and where
  each changed line changed (`{column, graphemes gained or lost}`), for `comment_caret/2`. Adding
  puts `marker ` after the indent the lines share (the smallest, when they indent alike); taking off removes the marker and a
  space after it. Blank lines are left alone; `nil` when every line is blank.

      iex> {cmd, at} = Geex.Loop.Keymap.comment_lines("  a\\n\\n    b\\n", {0, 2}, "#")
      iex> {cmd.text, at}
      {"  # a\\n\\n  #   b", %{0 => {2, 2}, 2 => {2, 2}}}
      iex> {cmd, at} = Geex.Loop.Keymap.comment_lines("  # a\\n  #b\\n", {0, 1}, "#")
      iex> {cmd.text, at}
      {"  a\\n  b", %{0 => {2, -2}, 1 => {2, -1}}}
  """
  @spec comment_lines(String.t(), {non_neg_integer(), non_neg_integer()}, String.t()) ::
          {struct(), %{non_neg_integer() => {non_neg_integer(), integer()}}} | nil
  def comment_lines(text, {first, last}, marker) when first <= last do
    rows = text |> lines() |> Enum.slice(first..last//1) |> Enum.with_index(first)

    case for({l, i} <- rows, not blank_line?(l), do: {i, l, indent_len(l)}) do
      [] ->
        nil

      filled ->
        commented? =
          Enum.all?(filled, fn {_i, l, n} ->
            l |> Geex.Text.slice(n..-1//1) |> String.starts_with?(marker)
          end)

        # The indent the lines share, character for character: with mixed tabs and spaces the
        # marker goes where they part, so no marker lands inside another line's indent.
        at = filled |> Enum.map(fn {_i, l, n} -> Geex.Text.slice(l, 0, n) end) |> shared_prefix()
        mlen = Geex.Text.length(marker)

        changes =
          Map.new(filled, fn {i, l, n} ->
            if commented? do
              # By bytes: the marker and one space are ASCII, but the space can share a grapheme
              # with a combining mark after it (commenting `\u0301x` gives `# \u0301x`, the
              # space and the mark one grapheme), and taking that grapheme would take the mark.
              indent = Geex.Text.slice(l, 0, n)
              skip = byte_size(indent) + byte_size(marker)
              rest = binary_part(l, skip, byte_size(l) - skip)
              new = indent <> with(" " <> r <- rest, do: r)
              {i, {n, Geex.Text.length(new) - Geex.Text.length(l), new}}
            else
              {i,
               {at, mlen + 1,
                Geex.Text.slice(l, 0, at) <> marker <> " " <> Geex.Text.slice(l, at..-1//1)}}
            end
          end)

        {a, _, _} = hd(filled)
        {b, old_last, _} = List.last(filled)

        new_text =
          rows
          |> Enum.filter(fn {_l, i} -> i >= a and i <= b end)
          |> Enum.map_join("\n", fn {l, i} ->
            case changes[i] do
              nil -> l
              {_at, _n, new} -> new
            end
          end)

        {replace({a, 0}, {b, Geex.Text.length(old_last)}, new_text),
         Map.new(changes, fn {i, {col, n, _new}} -> {i, {col, n}} end)}
    end
  end

  # How many leading graphemes every string in `strings` has in common.
  defp shared_prefix([first | rest]) do
    first
    |> Geex.Text.graphemes()
    |> Enum.with_index()
    |> Enum.find_value(Geex.Text.length(first), fn {g, k} ->
      if Enum.any?(rest, &(Geex.Text.at(&1, k) != g)), do: k
    end)
  end

  @doc """
  Where a caret lands after `comment_lines/3`: before the change it stays, after it it moves with
  its text, inside a removed marker it goes to where the marker was; at column 0 it stays, so
  whole lines stay whole.

      iex> at = %{0 => {2, 2}, 1 => {2, -2}}
      iex> Enum.map([{0, 1}, {0, 2}, {0, 4}, {1, 3}, {1, 5}, {2, 3}], &Geex.Loop.Keymap.comment_caret(&1, at))
      [{0, 1}, {0, 4}, {0, 6}, {1, 2}, {1, 3}, {2, 3}]
  """
  @spec comment_caret(cursor(), %{non_neg_integer() => {non_neg_integer(), integer()}}) ::
          cursor()
  def comment_caret({line, col}, changes) do
    case Map.get(changes, line) do
      nil -> {line, col}
      _ when col == 0 -> {line, 0}
      {at, n} when n > 0 -> if col < at, do: {line, col}, else: {line, col + n}
      {at, n} -> {line, if(col <= at, do: col, else: max(col + n, at))}
    end
  end

  defp indent_len(l),
    do: Geex.Text.length(l) - Geex.Text.length(String.replace(l, ~r/^[ \t]+/, ""))

  @doc """
  A bigger selection (ADR-0052 §2, §3): the `kind` (`:char`, `:word`, `:line`) at `cursor` with no
  selection (`range` nil), or the selection `range` taking in the next one. `{anchor, active}`, or
  `nil` when there is nothing more to take. A word runs from space to space, as `Alt+U`/`Alt+O`
  jump (the maintainer's call, 2026-11-12); with no selection, the one the cursor is on, else the
  next on its line, else the one before it.

      iex> alias Geex.Loop.Keymap
      iex> Keymap.select_more(:char, "ab\\n", {0, 1}, nil)
      {{0, 1}, {0, 2}}
      iex> Keymap.select_more(:word, "foo(bar, baz)", {0, 5}, nil)
      {{0, 0}, {0, 8}}
      iex> Keymap.select_more(:word, "foo(bar, baz)", {0, 8}, {{0, 0}, {0, 8}})
      {{0, 0}, {0, 13}}
      iex> Keymap.select_more(:line, "a\\nbc\\nd", {1, 1}, nil)
      {{1, 0}, {2, 0}}
      iex> Keymap.select_more(:line, "a\\nbc\\nd", {2, 0}, {{1, 0}, {2, 0}})
      {{1, 0}, {2, 1}}
  """
  @spec select_more(:char | :word | :line, String.t(), cursor(), {cursor(), cursor()} | nil) ::
          {cursor(), cursor()} | nil
  def select_more(kind, text, cursor, range) do
    {anchor, active} =
      case {kind, range} do
        {:char, nil} -> {cursor, right(cursor, text)}
        {:char, {from, to}} -> {from, right(to, text)}
        {:word, nil} -> word_at(text, cursor) || {cursor, cursor}
        {:word, {from, to}} -> {from, next_word_end(text, to) || to}
        {:line, nil} -> {line_start(cursor), line_after(cursor, text)}
        {:line, {from, to}} -> {line_start(from), line_after(to, text)}
      end

    if anchor == active or (range != nil and {anchor, active} == range),
      do: nil,
      else: {anchor, active}
  end

  defp line_after({line, _col}, text) do
    if line < last_line(text), do: {line + 1, 0}, else: {line, line_len(text, line)}
  end

  # The word the cursor is on, else the next on its line, else the one before it.
  defp word_at(text, {line, col}) do
    with_window(text, line, col, col, fn {gs, lo, at_start?, at_end?} = w ->
      n = tuple_size(gs)
      c = clamp(col - lo, 0, n)

      fwd =
        if c < n and non_space?(elem(gs, c)),
          do: c,
          else: Enum.find(c..(n - 1)//1, &non_space?(elem(gs, &1)))

      start =
        cond do
          fwd -> fwd
          not at_end? -> :edge
          i = Enum.find((c - 1)..0//-1, &non_space?(elem(gs, &1))) -> i
          not at_start? -> :edge
          true -> nil
        end

      case start do
        :edge ->
          :edge

        nil ->
          {:ok, nil}

        start ->
          {a, b} = {skip_bwd(start, gs, &non_space?/1), skip_fwd(start, gs, n, &non_space?/1)}

          if edge?(w, a) or edge?(w, b),
            do: :edge,
            else: {:ok, {{line, a + lo}, {line, b + lo}}}
      end
    end)
  end

  # The end of the next word from `{line, col}`, on this line or a later one.
  defp next_word_end(text, {line, col}) do
    text
    |> lines()
    |> Enum.drop(line)
    |> Enum.with_index(line)
    |> Enum.find_value(fn {l, i} ->
      c = if i == line, do: col, else: 0

      on_window(String.replace_suffix(l, "\r", ""), c, c, fn {gs, lo, _s, at_end?} = w ->
        n = tuple_size(gs)
        start = skip_fwd(clamp(c - lo, 0, n), gs, n, &(not non_space?(&1)))

        cond do
          start < n ->
            e = skip_fwd(start, gs, n, &non_space?/1)
            if edge?(w, e), do: :edge, else: {:ok, {i, e + lo}}

          at_end? ->
            {:ok, nil}

          true ->
            :edge
        end
      end)
    end)
  end

  @doc """
  The bracket paired with the one at `cursor`, or just before it; elsewhere, the opening bracket
  of the nearest pair around it (ADR-0052 §4). Counted in the plain text, one kind at a time, up
  to #{@bracket_lines} lines or #{@bracket_graphemes} characters away. `nil` when there is none.

      iex> alias Geex.Loop.Keymap
      iex> Keymap.matching_bracket({0, 3}, "foo(a, [b])")
      {0, 10}
      iex> Keymap.matching_bracket({0, 11}, "foo(a, [b])")
      {0, 3}
      iex> Keymap.matching_bracket({1, 2}, "f {\\n  x\\n}")
      {0, 2}
      iex> Keymap.matching_bracket({0, 1}, "ab")
      nil
  """
  @spec matching_bracket(cursor(), String.t()) :: cursor() | nil
  def matching_bracket({line, col}, text) do
    lt = text |> lines() |> List.to_tuple()
    here = if line < tuple_size(lt), do: String.replace_suffix(elem(lt, line), "\r", ""), else: ""
    at = fn c -> grapheme_at(here, c) end

    cond do
      bracket?(at.(col)) -> pair_of({line, col}, at.(col), lt)
      bracket?(at.(col - 1)) -> pair_of({line, col - 1}, at.(col - 1), lt)
      true -> enclosing({line, col}, lt)
    end
    |> resolve_col(lt)
  end

  # The grapheme at column `c` of `l`: on an ASCII line (up to past `c`) the byte there, without
  # walking the line (BUG-12).
  defp grapheme_at(_l, c) when c < 0, do: nil

  defp grapheme_at(l, c) do
    if ascii_prefix?(l, c + 2),
      do: if(c < byte_size(l), do: binary_part(l, c, 1)),
      else: Geex.Text.at(l, c)
  end

  # A pair found in the tail of a long line read backward carries its column counted from the
  # line's end (`graphemes_bwd/2`); counted once, here, from the line's length.
  defp resolve_col({l, {:end, k}}, lt), do: {l, Geex.Text.length(elem(lt, l)) - 1 - k}
  defp resolve_col(found, _lt), do: found

  defp bracket?(g), do: Map.has_key?(@bracket_open, g) or Map.has_key?(@bracket_close, g)

  defp pair_of({line, col}, g, lt) do
    case @bracket_open do
      %{^g => close} -> find_pair(graphemes_fwd(lt, {line, col + 1}), g, close)
      _ -> find_pair(graphemes_bwd(lt, {line, col}), g, @bracket_close[g])
    end
  end

  # The bracket that brings the count of `same` back to zero.
  defp find_pair(stream, same, other) do
    Enum.reduce_while(stream, 1, fn
      {^same, _l, _c}, depth -> {:cont, depth + 1}
      {^other, l, c}, 1 -> {:halt, {l, c}}
      {^other, _l, _c}, depth -> {:cont, depth - 1}
      _, depth -> {:cont, depth}
    end)
    |> then(&if(is_tuple(&1), do: &1))
  end

  defp enclosing(cursor, lt) do
    Enum.reduce_while(graphemes_bwd(lt, cursor), 0, fn {g, l, c}, open ->
      cond do
        Map.has_key?(@bracket_close, g) -> {:cont, open + 1}
        Map.has_key?(@bracket_open, g) and open == 0 -> {:halt, {l, c}}
        Map.has_key?(@bracket_open, g) -> {:cont, open - 1}
        true -> {:cont, open}
      end
    end)
    |> then(&if(is_tuple(&1), do: &1))
  end

  # The graphemes from `{line, col}` on, and before it backwards, as `{g, line, col}`, at most
  # @bracket_graphemes of them, read lazily so a long line costs only what is read of it. Where
  # the cursor's line is ASCII up to it, its column is a byte and the reading starts there
  # without walking the line (BUG-12).
  defp graphemes_fwd(lt, {line, col}) do
    last = min(tuple_size(lt) - 1, line + @bracket_lines)

    line..last//1
    |> Stream.flat_map(fn i -> forward_from(elem(lt, i), i, if(i == line, do: col, else: 0)) end)
    |> Stream.take(@bracket_graphemes)
  end

  defp forward_from(l, i, col) do
    rest =
      cond do
        col == 0 ->
          l

        ascii_prefix?(l, col + 1) ->
          binary_part(l, min(col, byte_size(l)), max(byte_size(l) - col, 0))

        true ->
          l |> Geex.Text.split_at(col) |> elem(1)
      end

    rest
    |> Stream.unfold(&Geex.Text.next_grapheme/1)
    |> Stream.with_index(col)
    |> Stream.map(fn {g, c} -> {g, i, c} end)
  end

  # Backward, an ASCII line (up to the cursor, on its line) is read byte by byte from its end;
  # any other is read whole when it is short enough, else only its last @bracket_graphemes × 4
  # bytes, and the search ends there: what comes before that tail isn't read. A tail's columns
  # are counted from the end (`{:end, k}` off a line whose length isn't known yet, resolved once
  # a pair is found, `resolve_col/2`).
  defp graphemes_bwd(lt, {line, col}) do
    first = max(0, line - @bracket_lines)

    line..first//-1
    |> Stream.transform(:go, fn
      _i, :stop ->
        {:halt, :stop}

      i, :go ->
        {gs, more?} = backward_from(elem(lt, i), i, if(i == line, do: col, else: :end))
        {gs, if(more?, do: :stop, else: :go)}
    end)
    |> Stream.take(@bracket_graphemes)
  end

  @tail_bytes @bracket_graphemes * 4

  defp backward_from(l, i, upto) do
    ascii_to = if upto == :end, do: byte_size(l), else: upto + 1

    cond do
      ascii_prefix?(l, ascii_to) ->
        top = if upto == :end, do: byte_size(l), else: min(upto, byte_size(l))
        {Stream.map((top - 1)..0//-1, &{binary_part(l, &1, 1), i, &1}), false}

      true ->
        prefix = if upto == :end, do: l, else: l |> Geex.Text.split_at(upto) |> elem(0)

        if byte_size(prefix) <= @tail_bytes do
          gs = prefix |> Geex.Text.graphemes() |> Enum.with_index() |> Enum.reverse()
          {for({g, c} <- gs, do: {g, i, c}), false}
        else
          tail = utf8_tail(prefix, @tail_bytes)
          col = fn k -> if upto == :end, do: {:end, k}, else: upto - 1 - k end
          gs = tail |> Geex.Text.graphemes() |> Enum.reverse() |> Enum.with_index()
          {for({g, k} <- gs, do: {g, i, col.(k)}), true}
        end
    end
  end

  # The last `n` bytes of `b` or a few fewer, starting on a character's first byte.
  defp utf8_tail(b, n) do
    start = byte_size(b) - n

    start =
      Enum.find(
        start..(byte_size(b) - 1)//1,
        start,
        &(Bitwise.band(:binary.at(b, &1), 0xC0) != 0x80)
      )

    binary_part(b, start, byte_size(b) - start)
  end

  @doc """
  Move the selected text `range` along its line (ADR-0052 §7): `:left`/`:right` one character,
  `:word_back`/`:word_forward` swapping it with the word (space to space) before or after it (what
  lies between stays), `:line_start` (after the indent)/`:line_end`. One replace on the line and the text's new
  `{from, to}`; `nil` when the range spans lines, is empty, or can't go that way.

      iex> alias Geex.Loop.Keymap
      iex> {cmd, from, to} = Keymap.move_text("foo(bar, baz)", {{0, 9}, {0, 13}}, :word_back)
      iex> {cmd.text, from, to}
      {"baz) foo(bar,", {0, 0}, {0, 4}}
      iex> {cmd, from, to} = Keymap.move_text("one two three", {{0, 8}, {0, 13}}, :word_back)
      iex> {cmd.text, from, to}
      {"three two", {0, 4}, {0, 9}}
      iex> {cmd, from, to} = Keymap.move_text("abcd", {{0, 1}, {0, 2}}, :right)
      iex> {cmd.text, from, to}
      {"cb", {0, 2}, {0, 3}}
      iex> Keymap.move_text("abcd", {{0, 0}, {0, 2}}, :left)
      nil
  """
  @spec move_text(String.t(), {cursor(), cursor()}, atom()) ::
          {struct(), cursor(), cursor()} | nil
  def move_text(text, {{line, a}, {line, b}}, how) when a < b do
    with_window(text, line, a, b, fn {gs, lo, _s, _e} = w ->
      {a, b} = {a - lo, b - lo}

      # A word or line-end move takes the selection's words, not the spaces at its ends: those
      # are gap, staying where they are, so `Alt+S`, `Alt+O` on `bar` (taking `bar `) and then a
      # move keeps `foo bar baz`'s spacing (mod-verify's review). All spaces is nothing to move.
      {a, b} =
        if how in [:word_back, :word_forward, :line_start, :line_end],
          do: {skip_fwd(a, gs, b, &space?/1), skip_bwd(b, gs, &space?/1)},
          else: {a, b}

      if a < b, do: move_in(w, line, a, b, how), else: {:ok, nil}
    end)
  end

  def move_text(_text, _range, _how), do: nil

  # The move in the window `w`, `a`..`b` its local columns: `{:ok, result}`, or `:edge` when the
  # move needs more of the line than the window has.
  defp move_in({gs, lo, at_start?, at_end?} = w, line, a, b, how) do
    n = tuple_size(gs)

    part = fn from, to ->
      gs |> Tuple.to_list() |> Enum.slice(from..(to - 1)//1) |> Enum.join()
    end

    sel = part.(a, b)
    len = b - a

    # {span from, span to, what replaces the span, where the text starts}
    move =
      case how do
        # The window reaches @window past the selection's ends, so a character beside it is in
        # the window whenever the line has one.
        :left when a > 0 ->
          {a - 1, b, sel <> part.(a - 1, a), a - 1}

        :right when b < n ->
          {a, b + 1, part.(b, b + 1) <> sel, a + 1}

        :word_back ->
          we = skip_bwd(a, gs, &(not non_space?(&1)))
          ws = skip_bwd(we, gs, &non_space?/1)

          cond do
            edge?(w, ws) -> :edge
            ws < we -> {ws, b, sel <> part.(we, a) <> part.(ws, we), ws}
            true -> nil
          end

        :word_forward ->
          ws = skip_fwd(b, gs, n, &(not non_space?(&1)))
          we = skip_fwd(ws, gs, n, &non_space?/1)

          cond do
            edge?(w, we) -> :edge
            ws < we -> {a, we, part.(ws, we) <> part.(b, ws) <> sel, a + (we - b)}
            true -> nil
          end

        # To a line end it needs the line up to that end.
        how when how == :line_start and not at_start? ->
          :edge

        how when how == :line_end and not at_end? ->
          :edge

        # To a line end: the text it passes keeps its spacing, the gap going between them, so
        # `  ab cd` with `cd` becomes `  cd ab`; never past the indent.
        :line_start ->
          indent = skip_fwd(0, gs, n, &space?/1)
          gap = skip_bwd(a, gs, &space?/1)

          if a > indent do
            core = if gap > indent, do: part.(indent, gap), else: ""
            {indent, b, sel <> part.(gap, a) <> core, indent}
          end

        # Only spaces after it: it is at the end already (they don't become indent).
        :line_end when b < n ->
          gap = skip_fwd(b, gs, n, &space?/1)
          core = part.(gap, n)
          if gap < n, do: {a, n, core <> part.(b, gap) <> sel, n - len}

        _ ->
          nil
      end

    case move do
      :edge ->
        :edge

      nil ->
        {:ok, nil}

      {from, to, new, start} ->
        {:ok,
         {replace({line, from + lo}, {line, to + lo}, new), {line, start + lo},
          {line, start + lo + len}}}
    end
  end

  defp replace({l1, c1}, {l2, c2}, text) do
    {:ok, cmd} =
      Replace.parse(%{start_line: l1, start_col: c1, end_line: l2, end_col: c2, text: text})

    cmd
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

  def autoclose({:char, g}, {line, col}, text, pairs, opts)
      when g in @closers or g in @quotes or g in @openers do
    # Only the characters either side of the cursor are read (BUG-12: a typed character near the
    # end of a 2 MB line took a second), and the line before it only for a quote.
    l = line_body(text, line)
    {col, prev, next} = around(l, col)

    cond do
      (g in @closers or g in @quotes) and next == g and tracked?(pairs, line, col) ->
        {:move, {line, col + 1}}

      g in @openers and closes_before?(next) ->
        {:edit, insert(line, col, g <> @pairs[g]), {line, col + 1}}

      g in @quotes and closes_before?(next) and opens_string?(g, l, col, prev, opts) ->
        {:edit, insert(line, col, g <> g), {line, col + 1}}

      true ->
        nil
    end
  end

  def autoclose(_event, _cursor, _text, _pairs, _opts), do: nil

  # Whether a quote typed at column `col` of `l` opens a string (and so gets its closer).
  defp opens_string?(g, l, col, prev, opts) do
    (g != "'" or Keyword.get(opts, :single_quote, true)) and
      (g != "`" or Keyword.get(opts, :backtick, true)) and not word?(prev) and
      prev not in [g | @closers] and string_at(before_col(l, col)) == nil
  end

  # The string `before` ends inside, read left to right: nil outside any, else its quote. Inside
  # a string a backslash escapes the next grapheme, and the other quotes are text (the review of
  # item 19: `x = "it's" + '` is outside a string, so its `'` opens one). ASCII is read by its
  # quotes and backslashes alone, each a byte and a grapheme (BUG-12).
  defp string_at(before) do
    if ascii_prefix?(before, byte_size(before)) do
      before
      |> :binary.matches(["\"", "'", "`", "\\"])
      |> Enum.map(fn {at, 1} -> {at, binary_part(before, at, 1)} end)
      |> scan_bytes(nil)
    else
      before |> Geex.Text.graphemes() |> scan_strings(nil)
    end
  end

  defp scan_bytes([], open), do: open

  defp scan_bytes([{at, "\\"} | rest], open) when open != nil,
    do: scan_bytes(Enum.drop_while(rest, fn {next, _} -> next == at + 1 end), open)

  defp scan_bytes([{_at, g} | rest], nil) when g in @quotes, do: scan_bytes(rest, g)
  defp scan_bytes([{_at, open} | rest], open), do: scan_bytes(rest, nil)
  defp scan_bytes([_ | rest], open), do: scan_bytes(rest, open)

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
    with true <- tracked?(pairs, line, col),
         l = line_body(text, line),
         prev = grapheme_at(l, col - 1),
         true <- Map.has_key?(@pairs, prev) and grapheme_at(l, col) == @pairs[prev],
         do: {:edit, delete(line, col - 1, 2), {line, col - 1}},
         else: (_ -> nil)
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
      shifted = shift(pairs, l, c, Geex.Text.length(t))

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
    {col, _prev, _next} = around(l, col)

    if Keyword.get(opts, :indent, true) do
      indent_newline(line, col, l, unit, eol, Keyword.get(opts, :colon, false))
    else
      {:edit, insert(line, col, eol), {line + 1, 0}}
    end
  end

  defp indent_newline(line, col, l, unit, eol, colon?) do
    lead = leading_whitespace(l)
    base = Geex.Text.slice(lead, 0, col)
    {opener, after_first} = blanks_around(l, col)
    # `:` opens a block where it does, but not ending a comment (`# Steps:`).
    colon? = colon? and not String.starts_with?(String.trim_leading(l), "#")
    openers = if colon?, do: ["{", "[", "(", ":"], else: ["{", "[", "("]

    cond do
      l != "" and lead == l and col == Geex.Text.length(l) ->
        {:edit, replace_head(line, col, eol <> l), {line + 1, col}}

      opener in @openers and after_first == @pairs[opener] ->
        inner = base <> unit

        {:edit, insert(line, col, eol <> inner <> eol <> base),
         {line + 1, Geex.Text.length(inner)}}

      opener in openers ->
        inner = base <> unit
        {:edit, insert(line, col, eol <> inner), {line + 1, Geex.Text.length(inner)}}

      true ->
        {:edit, insert(line, col, eol <> base), {line + 1, Geex.Text.length(base)}}
    end
  end

  # Around column `col` of `l`: the last character before it past the spaces, then the tabs,
  # before it, and the first after it past the spaces, then the tabs, after it (`nil` at a
  # line's end), as the line trimmed would give them; read near the cursor (BUG-12).
  defp blanks_around(l, col) do
    on_window(l, col, col, fn {gs, lo, _s, _e} = w ->
      n = tuple_size(gs)
      c = clamp(col - lo, 0, n)
      i = skip_bwd(skip_bwd(c, gs, &(&1 == " ")), gs, &(&1 == "\t"))
      j = skip_fwd(skip_fwd(c, gs, n, &(&1 == " ")), gs, n, &(&1 == "\t"))

      if edge?(w, i) or edge?(w, j),
        do: :edge,
        else: {:ok, {if(i > 0, do: elem(gs, i - 1)), if(j < n, do: elem(gs, j))}}
    end)
  end

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
    if leading_bytes(line_text(text, line), [?\s]) >= col do
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
  defp leading_whitespace(l), do: binary_part(l, 0, leading_bytes(l, [?\s, ?\t]))

  # How many of `l`'s first bytes are graphemes in `bytes` (spaces, tabs): the run of them, less
  # its last when a combining mark after it joins it into another character. Read from the
  # line's start only as far as the run goes.
  defp leading_bytes(l, bytes) do
    n = count_leading(l, 0, bytes)

    with true <- n > 0 and n < byte_size(l),
         {g, _rest} <- Geex.Text.next_grapheme(binary_part(l, n - 1, byte_size(l) - n + 1)),
         true <- byte_size(g) > 1 do
      n - 1
    else
      _ -> n
    end
  end

  defp count_leading(l, n, bytes) do
    if n < byte_size(l) and :binary.at(l, n) in bytes,
      do: count_leading(l, n + 1, bytes),
      else: n
  end

  # The characters either side of column `col` of `l` and `col` clamped to the line, as
  # `{col, prev, next}`, read near the cursor (BUG-12).
  defp around(l, col) do
    on_window(l, col, col, fn {gs, lo, _s, _e} ->
      n = tuple_size(gs)
      c = clamp(col - lo, 0, n)
      {:ok, {lo + c, if(c > 0, do: elem(gs, c - 1)), if(c < n, do: elem(gs, c))}}
    end)
  end

  # `l`'s first `col` graphemes: by bytes when ASCII up to past them.
  defp before_col(l, col) do
    if ascii_prefix?(l, col + 1),
      do: binary_part(l, 0, min(col, byte_size(l))),
      else: l |> Geex.Text.split_at(col) |> elem(0)
  end

  defp closes_before?(nil), do: true
  defp closes_before?(g), do: g in @close_before
  defp word?(nil), do: false
  # A letter, digit or `_`, combining marks and all (a decomposed `é`).
  # A byte that isn't UTF-8 is no letter, and a Unicode regex would raise on it (BUG-15).
  defp word?(g), do: String.valid?(g) and String.match?(g, ~r/^[\p{L}\p{N}_]\p{M}*$/u)

  @doc """
  What a key types over a selection (roadmap item 18.1): Backspace and Delete delete it (`""`),
  a printable grapheme or Enter replaces it. `nil` for every other key, which acts as it does
  without a selection, or as its own decision has it (Tab indents the selection's lines,
  ADR-0050).

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

  @doc "Is `event` a vertical motion (up/down, incl. Alt+I/K)? Vertical moves keep the goal."
  @spec vertical?(tuple()) :: boolean()
  def vertical?({:cmd, command}), do: command in [:up, :down]
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

  ## Motion commands.

  defp motion(:up, cursor, text), do: vert(cursor, text, -1)
  defp motion(:down, cursor, text), do: vert(cursor, text, +1)
  defp motion(:left, cursor, text), do: left(cursor, text)
  defp motion(:right, cursor, text), do: right(cursor, text)
  defp motion(:word_back, cursor, text), do: word_back(cursor, text)
  defp motion(:word_forward, cursor, text), do: word_forward(cursor, text)
  defp motion(:line_start, cursor, _text), do: line_start(cursor)
  defp motion(:line_end, cursor, text), do: line_end(cursor, text)
  defp motion(:matching_bracket, cursor, text), do: matching_bracket(cursor, text) || cursor

  defp line_start({line, _col}), do: {line, 0}
  defp line_end({line, _col}, text), do: {line, line_len(text, line)}

  # Word motion within the line, whitespace-delimited. Forward lands on the next word's
  # start (skip the rest of this word, then the spaces); backward lands on the previous
  # word's start. Clamped to the line ends; line-crossing is a later refinement.
  defp word_forward({line, col}, text) do
    with_window(text, line, col, col, fn {gs, lo, _s, _e} = w ->
      n = tuple_size(gs)
      i = skip_fwd(clamp(col - lo, 0, n), gs, n, &non_space?/1)
      r = skip_fwd(i, gs, n, &space?/1)
      if edge?(w, r), do: :edge, else: {:ok, {line, r + lo}}
    end)
  end

  defp word_back({line, col}, text) do
    with_window(text, line, col, col, fn {gs, lo, _s, _e} = w ->
      i = skip_bwd(clamp(col - lo, 0, tuple_size(gs)), gs, &space?/1)
      r = skip_bwd(i, gs, &non_space?/1)
      if edge?(w, r), do: :edge, else: {:ok, {line, r + lo}}
    end)
  end

  defp skip_fwd(i, gs, n, pred),
    do: if(i < n and pred.(elem(gs, i)), do: skip_fwd(i + 1, gs, n, pred), else: i)

  defp skip_bwd(i, gs, pred),
    do: if(i > 0 and pred.(elem(gs, i - 1)), do: skip_bwd(i - 1, gs, pred), else: i)

  ## Reading a long line near the cursor (BUG-12). A short line is read whole, as always; a long
  ## one only around the columns a key needs, so a key costs the same near the end of a 2 MB line
  ## (minified code, a log line) as at its start. `fun` gets a window `{graphemes, lo, at_start?,
  ## at_end?}` (the graphemes from column `lo` on, and whether they reach the line's ends) and
  ## answers `{:ok, result}`, or `:edge` when it ran into a side of the window that isn't the
  ## line's: then it runs again on the whole line, so the answer never depends on the window.

  @window 1024
  @long_line 4096
  # A line is read without a CRLF's \r (`line_body/2`): the cursor stops before it, and no word or
  # move takes it (mod-verify's review of ADR-0052).
  defp with_window(text, line, from, to, fun), do: on_window(line_body(text, line), from, to, fun)

  defp on_window(l, from, to, fun) do
    case fun.(window(l, from, to)) do
      {:ok, result} ->
        result

      :edge ->
        {:ok, result} = fun.(whole(l))
        result
    end
  end

  defp whole(l), do: {l |> Geex.Text.graphemes() |> List.to_tuple(), 0, true, true}

  defp window(l, _from, _to) when byte_size(l) <= @long_line, do: whole(l)

  defp window(l, from, to) do
    size = byte_size(l)
    lo = max(from - @window, 0)
    hi = to + @window

    if ascii_prefix?(l, hi + 1) do
      # ASCII up to past the window: a column is a byte, so the window is a slice. The byte after
      # it is ASCII too, so no combining mark there joins the window's last character.
      {lo, hi} = {min(lo, size), min(hi, size)}
      gs = for <<b <- binary_part(l, lo, hi - lo)>>, do: <<b>>
      {List.to_tuple(gs), lo, lo == 0, hi == size}
    else
      # Otherwise columns are counted from the start (String.split_at walks the line without
      # building a grapheme per character, several times faster than reading it whole).
      {before, rest} = Geex.Text.split_at(l, lo)
      # Past the line's end, the window is its end.
      lo = if rest == "" and lo > 0, do: Geex.Text.length(before), else: lo
      {part, more} = Geex.Text.split_at(rest, hi - lo)
      {part |> Geex.Text.graphemes() |> List.to_tuple(), lo, lo == 0, more == ""}
    end
  end

  # Whether local index `i` is at a side of the window that isn't the line's.
  defp edge?({gs, _lo, at_start?, at_end?}, i),
    do: (i == 0 and not at_start?) or (i == tuple_size(gs) and not at_end?)

  # Whether the first `k` bytes of `l` (all of it, when shorter) are ASCII.
  defp ascii_prefix?(l, k), do: Geex.Ascii.prefix?(l, k)

  defp space?(g), do: g == " " or g == "\t"
  defp non_space?(g), do: not space?(g)
end
