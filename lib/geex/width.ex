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

  **A tab** is the one grapheme whose width depends on where it starts: it runs to the next tab
  stop, every `tab` columns (the tab-size setting, roadmap item 18.7). `cells/1` alone can't
  know that, so a line of text is measured with `advance/3`, `line/2` and `col_at_display/3`,
  which take the tab size (2 unless given). Width stays a render concern (ADR-0027): a tab is
  one grapheme to every command, however wide it draws.
  """

  # The tab size when none is given: the tab-size setting's default.
  @tab 2

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
  The columns `grapheme` takes when it starts at display column `at` (0-based): a tab runs to
  the next stop of every `tab` columns; anything else is `cells/1`.

      iex> {Geex.Width.advance("\t", 0, 4), Geex.Width.advance("\t", 3, 4), Geex.Width.advance("字", 3, 4)}
      {4, 1, 2}
  """
  @spec advance(String.t(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  def advance("\t", at, tab), do: tab - rem(at, tab)
  def advance(grapheme, _at, _tab), do: cells(grapheme)

  @doc """
  The display width of a line of text with tab stops every `tab` columns.

      iex> {Geex.Width.line("\tab", 4), Geex.Width.line("a\tb", 4), Geex.Width.line("a\tb", 2)}
      {6, 5, 3}
  """
  @spec line(String.t(), pos_integer()) :: non_neg_integer()
  def line(line, tab \\ @tab) when is_binary(line), do: line |> seek(:end, tab) |> elem(2)

  @doc """
  The **1-based grapheme `x`** at display column `display_x` (1-based) of `line` — the cast
  the grid ruler needs (display column → addressing column, [ADR-0027](../../doc/adr/0027-grid-command-addressing.md)
  §"display ruler"). The dual of `Geex.Loop.cursor_xy/4`'s width walk: a wide glyph owns two
  display columns, so **both** map to it; a zero-width grapheme owns none, so it is skipped.
  A `display_x` past the line's drawn width returns the caret **after** the last grapheme
  (`graphemes + 1`), which the resolver clamps to the line end ("to end of line"). Pure — a
  function of the line text and the tab size, so it never reaches into view state. A tab owns
  every column to its stop.

      iex> Geex.Width.col_at_display("\tx", 4, 4)
      1
      iex> Geex.Width.col_at_display("\tx", 5, 4)
      2
  """
  @spec col_at_display(String.t(), pos_integer(), pos_integer()) :: pos_integer()
  def col_at_display(line, display_x, tab \\ @tab) when is_binary(line) and display_x >= 1,
    do: elem(seek(line, {:vcol, display_x - 1}, tab), 1) + 1

  @doc """
  Where a place on `line` is, as `{byte, column, display column}`: the byte offset and the
  grapheme column of a grapheme's start, and the display column it starts at (0-based, tabs
  every `tab` columns). The place is one of:

    * `{:col, c}` — grapheme column `c` (the line's end when it is shorter);
    * `{:vcol, t}` — the first grapheme that draws past display column `t` (the line's end when
      none does), so the one covering column `t`;
    * `:end` — the line's end, so the display column is the line's width.

  A long line costs what is read of it, not the whole line (BUG-13): a run of ASCII is measured
  by its bytes (only its tabs and control characters looked at one by one), and only the other
  characters are walked a grapheme at a time.

      iex> Geex.Width.seek("a\\tb字c", {:col, 3}, 4)
      {3, 3, 5}
      iex> Geex.Width.seek("a\\tb字c", {:vcol, 6}, 4)
      {3, 3, 5}
      iex> Geex.Width.seek("a\\tb字c", :end, 4)
      {7, 5, 8}
  """
  @spec seek(String.t(), {:col, non_neg_integer()} | {:vcol, integer()} | :end, pos_integer()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def seek(line, target, tab \\ @tab) when is_binary(line), do: seek(line, target, tab, 0, 0, 0)

  @high for b <- 128..255, do: <<b>>
  @controls for b <- Enum.to_list(0..31) ++ [127], do: <<b>>

  defp seek(l, target, tab, p, col, v) do
    size = byte_size(l)

    cond do
      p >= size ->
        {size, col, v}

      at_col?(target, col) ->
        {p, col, v}

      true ->
        high =
          case :binary.match(l, @high, scope: {p, size - p}) do
            {i, 1} -> i
            :nomatch -> size
          end

        # Up to the byte before the first non-ASCII one: that byte may start a grapheme with a
        # combining mark after it, so it is walked as a grapheme with what follows.
        run_end = if high < size, do: max(high - 1, p), else: size

        case ascii_run(l, p, run_end, target, tab, col, v) do
          {:found, b, c, vv} ->
            {b, c, vv}

          {:at, c, vv} when run_end >= size ->
            {size, c, vv}

          {:at, c, vv} ->
            {g, _rest} = String.next_grapheme(binary_part(l, run_end, size - run_end))
            wd = advance(g, vv, tab)

            if at_col?(target, c) or draws_past?(target, vv, wd),
              do: {run_end, c, vv},
              else: seek(l, target, tab, run_end + byte_size(g), c + 1, vv + wd)
        end
    end
  end

  defp at_col?({:col, c}, col), do: col >= c
  defp at_col?(_target, _col), do: false

  defp draws_past?({:vcol, t}, v, wd), do: v + wd > t
  defp draws_past?(_target, _v, _wd), do: false

  # Bytes `[p, e)` of `l`, every one an ASCII grapheme of its own, from grapheme column `col` at
  # display column `v`: `{:found, byte, col, vcol}` where the target is among them, else
  # `{:at, col, vcol}` at `e`.
  defp ascii_run(l, p, e, {:col, c}, tab, col, v) do
    k = c - col

    if k < e - p,
      do: {:found, p + k, c, ascii_advance(l, p, p + k, v, tab)},
      else: {:at, col + e - p, ascii_advance(l, p, e, v, tab)}
  end

  defp ascii_run(l, p, e, :end, tab, col, v),
    do: {:at, col + e - p, ascii_advance(l, p, e, v, tab)}

  defp ascii_run(l, p, e, {:vcol, t}, tab, col, v) do
    controls = for {s, 1} <- :binary.matches(l, @controls, scope: {p, e - p}), do: s
    vcol_run(l, p, e, controls, t, tab, col - p, v)
  end

  # `col0 + byte` is a byte's grapheme column in the run.
  defp vcol_run(l, cur, e, [s | rest], t, tab, col0, v) do
    i = max(t - v, 0)

    if i < s - cur do
      {:found, cur + i, col0 + cur + i, v + i}
    else
      v = v + (s - cur)
      wd = if :binary.at(l, s) == ?\t, do: tab - rem(v, tab), else: 0

      if v + wd > t,
        do: {:found, s, col0 + s, v},
        else: vcol_run(l, s + 1, e, rest, t, tab, col0, v + wd)
    end
  end

  defp vcol_run(_l, cur, e, [], t, _tab, col0, v) do
    i = max(t - v, 0)

    if i < e - cur,
      do: {:found, cur + i, col0 + cur + i, v + i},
      else: {:at, col0 + e, v + e - cur}
  end

  # The display column after ASCII bytes `[p, e)` of `l` from display column `v`: a byte a
  # column, a tab to its stop, a control character none.
  defp ascii_advance(l, p, e, v, tab) do
    {v, cur} =
      for {s, 1} <- :binary.matches(l, @controls, scope: {p, e - p}), reduce: {v, p} do
        {v, cur} ->
          v = v + (s - cur)
          {if(:binary.at(l, s) == ?\t, do: v + tab - rem(v, tab), else: v), s + 1}
      end

    v + (e - cur)
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
