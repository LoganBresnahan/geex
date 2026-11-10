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
  def resolve({:key, :enter}, {line, col}, _text),
    do: {:edit, insert(line, col, "\n"), {line + 1, 0}}

  # Tab → the default tab size's spaces; the loop passes the setting and the file's indent
  # style to `indent/3`. Shift+Tab → a real tab, always (roadmap item 18.7).
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
  # cluster around WASD that needs no arrow keys (ADR-0026), case-insensitive here, though the
  # loop takes Alt+Shift+W/A/S/D for resizing first (`resize_dir/1`, roadmap item 18.8):
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

  defp delete(line, col) do
    {:ok, cmd} = Delete.parse(%{line: line, col: col, count: 1})
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
  defp line_len(text, line), do: text |> lines() |> Enum.at(line, "") |> String.length()
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc """
  The way a resizing key moves the focused pane's edge (roadmap item 18.8): Alt with an arrow,
  or `Alt+Shift+W/A/S/D` (case-sensitive, as `Alt+Shift+Z` is). `nil` for any other key.

      iex> Enum.map([{:alt, :left}, {:alt, ?W}, {:alt, ?w}, {:key, :up}], &Geex.Loop.Keymap.resize_dir/1)
      [:left, :up, nil, nil]
  """
  @spec resize_dir(tuple()) :: :up | :down | :left | :right | nil
  def resize_dir({:alt, dir}) when dir in [:up, :down, :left, :right], do: dir
  def resize_dir({:alt, ?W}), do: :up
  def resize_dir({:alt, ?A}), do: :left
  def resize_dir({:alt, ?S}), do: :down
  def resize_dir({:alt, ?D}), do: :right
  def resize_dir(_event), do: nil

  @doc """
  What Tab does at `cursor` (roadmap item 18.7): a real tab in a file that indents with tabs
  (`:tabs`), else `tab_size` spaces. Shift+Tab is `:tabs` whatever the file does.

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
