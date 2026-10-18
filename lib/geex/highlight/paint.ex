defmodule Geex.Highlight.Paint do
  @moduledoc """
  Resolve highlight spans + a theme into per-byte styles, and project them onto a
  `Geex.Screen` ([ADR-0022](../../../doc/adr/0022-capability-reactor.md) display
  side / [ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md)).

  Spans can overlap (an `escape` inside a `string`; a `string.special.key` over a
  `string`). `styles/2` paints **widest span first**, so a narrower — more
  specific — span wins its bytes; equal-width ties go to the more-dotted (more
  specific) capture. The same resolution backs both the terminal-string render
  (`Geex.Ansi`) and the on-screen cell render here.
  """

  alias Geex.{Cell, Screen, Selection, Theme, Width}
  alias Geex.Theme.Style

  @doc """
  A map of `byte offset => Style` for `spans` under `theme`. Unstyled bytes are
  simply absent (the caller uses the theme's default foreground there).
  """
  @spec styles(Theme.t(), [Geex.Highlight.Span.t()]) :: %{non_neg_integer() => Style.t()}
  def styles(%Theme{} = theme, spans) do
    spans
    |> Enum.map(fn span -> {span, Theme.style_for(theme, span.capture)} end)
    |> Enum.reject(fn {_span, style} -> is_nil(style) end)
    |> Enum.sort_by(fn {span, _style} ->
      {-(span.end_byte - span.start_byte), dot_count(span.capture)}
    end)
    |> Enum.reduce(%{}, fn {span, style}, acc ->
      Enum.reduce(span.start_byte..(span.end_byte - 1)//1, acc, &Map.put(&2, &1, style))
    end)
  end

  @doc """
  Project `text` highlighted by `spans` under `theme` onto a `w`×`h` `Geex.Screen`,
  scrolled down by `scroll` rows (the first visible buffer line), inset from the left by
  `x0` columns (the line-number gutter — text begins at column `x0`), and scrolled right
  by `hscroll` display columns (the first `hscroll` columns of each line are off-screen).

  Splits on `\n` into lines — the **same split `Geex.Buffer.Doc` uses**, so a `\r` is
  ordinary line content at its Doc column (a CRLF line's `\r` is *not* folded into a `\r\n`
  terminator grapheme), and Paint's column model matches the cursor's and a selection's.
  Each line is then walked grapheme by grapheme, tracking the byte offset (so multibyte
  characters map to the right span — the `\n` between lines is the one byte that keeps these
  offsets aligned with the original text) and the line's **virtual column** (its display
  column had nothing scrolled, starting at `x0`). Each grapheme's screen column is
  `virtual − hscroll`; it advances the virtual column by the grapheme's **display width**
  ([`Geex.Width`](`Geex.Width`)) — a wide glyph takes two, a zero-width one (a combining
  mark, or a `\r`) none. The **whole pane is filled with the theme's editor background**
  first, then glyphs overlay it — so blank lines and the gaps after short lines carry the
  theme background. The `x0` gutter columns are left as background for the caller to draw
  over. Text is clipped to the rect `[x0, w)`: the right edge by `Geex.Screen`, the **left
  edge here** (a grapheme scrolled past `x0` is dropped; a wide glyph straddling `x0` — its
  lead scrolled off, its second column visible — shows a blank in that column).

  When a `selection` is given, each selected grapheme's cell takes the palette's selection
  background, and a line whose **trailing newline** falls inside the selection (an interior
  line of a multi-line span) has the run from its content end to the right edge filled with
  the selection background too — so a spanned line reads as fully selected rather than
  stopping ragged at its last glyph.
  """
  @spec to_screen(
          String.t(),
          [Geex.Highlight.Span.t()],
          Theme.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Selection.t() | nil
        ) ::
          Screen.t()
  def to_screen(
        text,
        spans,
        %Theme{} = theme,
        w,
        h,
        scroll \\ 0,
        x0 \\ 0,
        hscroll \\ 0,
        selection \\ nil
      )
      when is_binary(text) and w >= 0 and h >= 0 and scroll >= 0 and x0 >= 0 and hscroll >= 0 do
    by_byte = styles(theme, spans)
    fg = theme.palette.fg
    bg = theme.palette.bg
    sel_bg = theme.palette.selection
    # Reverse video for the selection when the palette has no colour for it (ADR-0040 §1).
    sel_attrs = theme.palette.mark

    # Paint the whole pane with the theme's editor background first, then overlay
    # the glyphs — so blank lines, the gaps after short lines, and the area below
    # the buffer all show the theme background, not the terminal's default.
    base = Screen.fill_rect(Screen.new(w, h), 0, 0, w, h, %Cell{char: " ", fg: fg, bg: bg})

    # Walk lines the way the Doc does — split on "\n" only, so a "\r" stays a content
    # grapheme at its Doc column. The outer accumulator carries the running byte offset
    # (aligned with the original text: +1 per "\n" between lines); the inner walk tracks
    # `col` (grapheme index) so a `Geex.Selection` (caret coordinates) tints the right cells.
    {screen, _byte} =
      text
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.reduce({base, 0}, fn {line, row}, {screen, byte0} ->
        sy = row - scroll

        {screen, byte_end, end_vcol, len} =
          line
          |> String.graphemes()
          |> Enum.reduce({screen, byte0, x0, 0}, fn g, {screen, byte, vcol, col} ->
            wd = Width.cells(g)
            cell = cell_for(g, style_at(by_byte, byte, byte_size(g)), fg, bg)

            cell =
              if selected?(selection, row, col),
                do: %{cell | bg: sel_bg, attrs: cell.attrs ++ sel_attrs},
                else: cell

            screen = place(screen, vcol - hscroll, sy, cell, wd, x0)
            {screen, byte + byte_size(g), vcol + wd, col + 1}
          end)

        # A multi-line selection covers this line's *newline* (the EOL caret {row, len} is in
        # range): tint the trailing run from the content end to the right edge so the spanned
        # line reads as fully selected, not ragged. The last buffer line has no newline, so its
        # EOL caret is never `< end` — this never fires there. `+1` for the "\n" separator.
        screen =
          if selected?(selection, row, len) do
            fill_eol(screen, sy, max(end_vcol - hscroll, x0), w, %Cell{
              char: " ",
              fg: fg,
              bg: sel_bg,
              attrs: sel_attrs
            })
          else
            screen
          end

        {screen, byte_end + 1}
      end)

    screen
  end

  # Tint screen-row `sy` from column `sx` to the right edge `w` with `cell` — the selection
  # fill for a line whose newline is selected. A no-op above the viewport or once the content
  # already reaches the edge; `Geex.Screen` drops any cell below it.
  defp fill_eol(screen, sy, sx, w, cell) when sy >= 0 and sx < w,
    do: Enum.reduce(sx..(w - 1)//1, screen, fn x, acc -> Screen.set_cell(acc, x, sy, cell) end)

  defp fill_eol(screen, _sy, _sx, _w, _cell), do: screen

  defp selected?(nil, _row, _col), do: false
  defp selected?(%Selection{} = sel, row, col), do: Selection.contains?(sel, {row, col})

  # Place a grapheme at screen column `x` on `row`, given its display width `wd` and the
  # left edge `x0` of the text rect (the gutter inset). `Geex.Screen.put_grapheme/4` handles
  # the **right** edge (a wide glyph in the last column is padded); this adds the **left**
  # edge that horizontal scroll needs:
  #   * zero-width grapheme — draw nothing;
  #   * lead at or past `x0` — normal placement (put_grapheme, right edge handled);
  #   * wide glyph straddling `x0` (lead at `x0-1`, second column at `x0`) — its left half is
  #     scrolled off, so its visible column shows a blank in the glyph's style;
  #   * anything fully left of `x0` — dropped.
  defp place(screen, _x, _row, _cell, 0, _x0), do: screen

  defp place(screen, x, row, cell, _wd, x0) when x >= x0,
    do: elem(Screen.put_grapheme(screen, x, row, cell), 0)

  defp place(screen, x, row, cell, 2, x0) when x == x0 - 1,
    do: Screen.set_cell(screen, x0, row, %{cell | char: " "})

  defp place(screen, _x, _row, _cell, _wd, _x0), do: screen

  # A grapheme can span several bytes; take the style of the first styled byte in
  # its range, so a span that begins mid-grapheme still colours the grapheme.
  defp style_at(by_byte, byte, size) do
    Enum.find_value(byte..(byte + size - 1)//1, fn b -> Map.get(by_byte, b) end)
  end

  defp cell_for(g, nil, fg, bg), do: %Cell{char: g, fg: fg, bg: bg}

  defp cell_for(g, %Style{} = s, fg, bg),
    do: %Cell{char: g, fg: pick(s.fg, fg), bg: pick(s.bg, bg), attrs: s.attrs}

  defp pick(:default, fallback), do: fallback
  defp pick(colour, _fallback), do: colour

  defp dot_count(capture), do: capture |> String.graphemes() |> Enum.count(&(&1 == "."))
end
