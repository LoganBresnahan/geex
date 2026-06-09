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
  @type action :: {:edit, struct(), cursor()} | {:move, cursor()} | :minibuffer | :quit | :ignore

  @doc "Resolve a `Geex.Input.Parser` event against the cursor and buffer text."
  @spec resolve(tuple(), cursor(), String.t()) :: action()
  def resolve(event, cursor, text)

  # Printable grapheme → insert it, advance one column.
  def resolve({:char, g}, {line, col}, _text),
    do: {:edit, insert(line, col, g), {line, col + 1}}

  # Enter → newline; cursor to the start of the new line.
  def resolve({:key, :enter}, {line, col}, _text),
    do: {:edit, insert(line, col, "\n"), {line + 1, 0}}

  # Tab → two spaces (minimal; width/expansion is configurable later).
  def resolve({:key, :tab}, {line, col}, _text),
    do: {:edit, insert(line, col, "  "), {line, col + 2}}

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

  # Arrows → move the cursor, clamped to the text, wrapping at line ends.
  def resolve({:key, :left}, cursor, text), do: {:move, left(cursor, text)}
  def resolve({:key, :right}, cursor, text), do: {:move, right(cursor, text)}
  def resolve({:key, :up}, cursor, text), do: {:move, vert(cursor, text, -1)}
  def resolve({:key, :down}, cursor, text), do: {:move, vert(cursor, text, +1)}

  # Alt+M opens the minibuffer (ADR-0028); every other Alt+letter is motion — a left-hand
  # cluster around WASD that needs no arrow keys (ADR-0026), case-insensitive:
  #   W A S D — up / left / down / right
  #   Q   E   — word back / forward
  #   R   F   — line start / end
  def resolve({:alt, c}, _cursor, _text) when c in [?m, ?M], do: :minibuffer
  def resolve({:alt, c}, cursor, text), do: alt_motion(lower(c), cursor, text)

  # Quit. Ctrl-X is the reliable key — Ctrl-Q is XON (software flow control) and
  # Ctrl-C is SIGINT, both of which can be swallowed by the tty before they ever
  # reach a raw-mode app, so accept all three.
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
      Replace.parse(%{start_line: line - 1, start_col: prev, end_line: line, end_col: 0, text: ""})

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
