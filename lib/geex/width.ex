defmodule Geex.Width do
  @moduledoc """
  Display width — how many terminal **columns** a grapheme occupies.

  This is a third axis, independent of the two geex already tracks:

      "字"  →  3 bytes (UTF-8)  ·  1 grapheme  ·  **2 columns**
      "a"   →  1 byte           ·  1 grapheme  ·  1 column
      "e" + combining accent     ·  1 grapheme  ·  1 column (the mark adds 0)

  Bytes are for storage, graphemes are "how many characters", and *columns* are
  how wide a glyph draws in the terminal grid. The renderer must advance the
  cursor by columns, not graphemes — a single width-2 glyph that is counted as
  one column desyncs every cell after it on the line.

  Terminal cells top out at **2 columns per glyph** (a "wide"/double-width cell);
  there is no triple-width cell, so `cells/1` returns `0 | 1 | 2`:

    * `2` — East-Asian wide (CJK ideographs, wide kana) and wide emoji, including
      emoji-presentation sequences (`base` + `U+FE0F`).
    * `0` — zero-width: combining marks (non-spacing `Mn` / enclosing `Me`),
      control codes, and the explicit zero-width format characters.
    * `1` — everything else.

  Backed by OTP's pure-Erlang `:unicode_util` — the same width oracle `:prim_tty`
  itself falls back to (`npwcwidth/1`) — so this stays **NIF-free** (no libc
  `wcwidth`, no native code), which keeps the terminal core extractable per
  [ADR-0024](../../doc/adr/0024-tui-core-extractable.md).
  """

  # Codepoints that take no column even when grapheme segmentation hands them to
  # us standing alone: ZWSP, ZWNJ, ZWJ, word-joiner, BOM/ZWNBSP, soft hyphen.
  @zero_width [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD]

  @doc """
  The number of terminal columns `grapheme` occupies: `0`, `1`, or `2`.

  A grapheme cluster may be several codepoints (a base plus combining marks, or
  a ZWJ emoji sequence); its width is that of the cluster as drawn, not the sum
  of its parts.
  """
  @spec cells(String.t()) :: 0 | 1 | 2
  def cells(grapheme) when is_binary(grapheme) do
    case String.to_charlist(grapheme) do
      # ASCII printable — the overwhelming common case (source code is mostly
      # this). Skip the Unicode table lookups entirely.
      [cp] when cp >= 0x20 and cp < 0x7F -> 1
      [] -> 0
      cps -> classify(cps)
    end
  end

  @doc """
  The total display width of `string` — the sum of its graphemes' `cells/1`
  widths, the number of terminal **columns** it draws to. Distinct from its byte
  size or grapheme count: a wide glyph counts two, a combining mark zero. Used to
  lay out fixed-width chrome (the status line; later the line-number gutter).
  """
  @spec string(String.t()) :: non_neg_integer()
  def string(string) when is_binary(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + cells(g) end)
  end

  @doc """
  The **1-based grapheme `x`** at display column `display_x` (1-based) of `line` — the cast
  the grid ruler needs (display column → addressing column, [ADR-0027](../../doc/adr/0027-grid-command-addressing.md)
  §"display ruler"). The dual of `Geex.Loop.cursor_xy/3`'s width walk: a wide glyph owns two
  display columns, so **both** map to it; a zero-width grapheme owns none, so it is skipped.
  A `display_x` past the line's drawn width returns the caret **after** the last grapheme
  (`graphemes + 1`), which the resolver clamps to the line end ("to end of line"). Pure — a
  function of the line text only, so it never reaches into view state.
  """
  @spec col_at_display(String.t(), pos_integer()) :: pos_integer()
  def col_at_display(line, display_x) when is_binary(line) and display_x >= 1 do
    walk_to_display(String.graphemes(line), display_x, 1, 1)
  end

  # gx = current grapheme's 1-based index; ds = its 1-based display-column start.
  defp walk_to_display([], _target, gx, _ds), do: gx

  defp walk_to_display([g | rest], target, gx, ds) do
    w = cells(g)
    if w > 0 and target < ds + w, do: gx, else: walk_to_display(rest, target, gx + 1, ds + w)
  end

  # `is_wide/1` is a compiled clause table (cheap) and is checked first: a wide
  # glyph is never zero-width, so this avoids the heavier `lookup/1` for CJK. The
  # zero-width path runs only for narrow non-ASCII graphemes.
  defp classify([base | _] = cps) do
    cond do
      :unicode_util.is_wide(cps) -> 2
      zero_width?(base) -> 0
      true -> 1
    end
  end

  defp zero_width?(cp) do
    cp in @zero_width or
      cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or
      mark?(cp)
  end

  # Non-spacing (Mn) and enclosing (Me) combining marks add no column. Spacing
  # combining marks (Mc) *do* advance the cursor, so they are deliberately not
  # treated as zero-width here.
  defp mark?(cp) do
    case :unicode_util.lookup(cp) do
      %{category: {:mark, :non_spacing}} -> true
      %{category: {:mark, :enclosing}} -> true
      _ -> false
    end
  end
end
