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

  alias Geex.{Cell, Screen, Theme}
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
  scrolled down by `scroll` rows (the first visible buffer line).

  Walks the text grapheme by grapheme, tracking the byte offset (so multibyte
  characters map to the right span) and the line/column. Each grapheme becomes a
  styled `Geex.Cell` — the token's foreground over the theme's editor background;
  off-screen cells are clipped by `Geex.Screen`. Newlines advance the row.
  """
  @spec to_screen(String.t(), [Geex.Highlight.Span.t()], Theme.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          Screen.t()
  def to_screen(text, spans, %Theme{} = theme, w, h, scroll \\ 0)
      when is_binary(text) and w >= 0 and h >= 0 and scroll >= 0 do
    by_byte = styles(theme, spans)
    fg = theme.palette.fg
    bg = theme.palette.bg

    {screen, _byte, _row, _col} =
      text
      |> String.graphemes()
      |> Enum.reduce({Screen.new(w, h), 0, 0, 0}, fn
        "\n", {screen, byte, row, _col} ->
          {screen, byte + 1, row + 1, 0}

        g, {screen, byte, row, col} ->
          cell = cell_for(g, Map.get(by_byte, byte), fg, bg)
          {Screen.set_cell(screen, col, row - scroll, cell), byte + byte_size(g), row, col + 1}
      end)

    screen
  end

  defp cell_for(g, nil, fg, bg), do: %Cell{char: g, fg: fg, bg: bg}

  defp cell_for(g, %Style{} = s, fg, bg),
    do: %Cell{char: g, fg: pick(s.fg, fg), bg: pick(s.bg, bg), attrs: s.attrs}

  defp pick(:default, fallback), do: fallback
  defp pick(colour, _fallback), do: colour

  defp dot_count(capture), do: capture |> String.graphemes() |> Enum.count(&(&1 == "."))
end
