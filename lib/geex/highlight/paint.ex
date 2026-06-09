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

  Walks the text grapheme by grapheme, tracking the byte offset (so multibyte characters
  map to the right span) and the line's **virtual column** (its display column had nothing
  scrolled, starting at `x0`). Each grapheme's screen column is `virtual − hscroll`; it
  advances the virtual column by the grapheme's **display width** ([`Geex.Width`](`Geex.Width`))
  — a wide glyph takes two. The **whole pane is filled with the theme's editor background**
  first, then glyphs overlay it — so blank lines and the gaps after short lines carry the
  theme background. The `x0` gutter columns are left as background for the caller to draw
  over. Text is clipped to the rect `[x0, w)`: the right edge by `Geex.Screen`, the **left
  edge here** (a grapheme scrolled past `x0` is dropped; a wide glyph straddling `x0` — its
  lead scrolled off, its second column visible — shows a blank in that column). Newlines
  return to the virtual column `x0`.
  """
  @spec to_screen(String.t(), [Geex.Highlight.Span.t()], Theme.t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), Selection.t() | nil) ::
          Screen.t()
  def to_screen(text, spans, %Theme{} = theme, w, h, scroll \\ 0, x0 \\ 0, hscroll \\ 0, selection \\ nil)
      when is_binary(text) and w >= 0 and h >= 0 and scroll >= 0 and x0 >= 0 and hscroll >= 0 do
    by_byte = styles(theme, spans)
    fg = theme.palette.fg
    bg = theme.palette.bg
    sel_bg = theme.palette.selection

    # Paint the whole pane with the theme's editor background first, then overlay
    # the glyphs — so blank lines, the gaps after short lines, and the area below
    # the buffer all show the theme background, not the terminal's default.
    base = Screen.fill_rect(Screen.new(w, h), 0, 0, w, h, %Cell{char: " ", fg: fg, bg: bg})

    # The accumulator also tracks `col` (grapheme index within the line) so a
    # `Geex.Selection` (caret coordinates) can tint the selected cells' background.
    {screen, _byte, _row, _vcol, _col} =
      text
      |> String.graphemes()
      |> Enum.reduce({base, 0, 0, x0, 0}, fn
        # "\r\n" is a single grapheme; both forms terminate the line.
        g, {screen, byte, row, _vcol, _col} when g in ["\n", "\r\n"] ->
          {screen, byte + byte_size(g), row + 1, x0, 0}

        g, {screen, byte, row, vcol, col} ->
          wd = Width.cells(g)
          cell = cell_for(g, style_at(by_byte, byte, byte_size(g)), fg, bg)
          cell = if selected?(selection, row, col), do: %{cell | bg: sel_bg}, else: cell
          screen = place(screen, vcol - hscroll, row - scroll, cell, wd, x0)
          {screen, byte + byte_size(g), row, vcol + wd, col + 1}
      end)

    screen
  end

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
  defp place(screen, x, row, cell, _wd, x0) when x >= x0, do: elem(Screen.put_grapheme(screen, x, row, cell), 0)
  defp place(screen, x, row, cell, 2, x0) when x == x0 - 1, do: Screen.set_cell(screen, x0, row, %{cell | char: " "})
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
