defmodule Geex.Ansi do
  @moduledoc """
  The render stage of the highlight pipeline
  ([ADR-0023](../../doc/adr/0023-theming-and-extension-loading.md)): turn
  capture `spans` + a `Theme` into a **24-bit truecolor** ANSI string.

      text → capture spans (Geex.Highlight) → Theme styles → ANSI (here)

  Spans can overlap (an `escape` inside a `string`; a `string.special.key`
  over a `string`). Resolution paints **widest span first**, so a narrower —
  more specific — span wins its bytes; equal-width ties go to the more dotted
  (more specific) capture. Unstyled bytes keep the terminal default.

  This renders a styled *string* (for previews, logs, the `mix geex.highlight`
  demo). Painting buffer text onto the `Geex.Screen`/`Geex.Cell` grid for the
  live editor (teaching `Geex.Renderer` to emit SGR per cell) is the connected
  follow-up; the colour/attr vocabulary here is already `Geex.Cell`'s.
  """

  alias Geex.Theme
  alias Geex.Theme.Style

  @reset "\e[0m"

  @doc """
  Render `text` highlighted by `spans` under `theme` to a truecolor ANSI string.
  Byte offsets in `spans` index `text` directly.
  """
  @spec highlight(Theme.t(), String.t(), [Geex.Highlight.Span.t()]) :: String.t()
  def highlight(%Theme{} = theme, text, spans) when is_binary(text) do
    painted = paint(theme, spans)
    n = byte_size(text)

    if n == 0 do
      ""
    else
      0..(n - 1)//1
      |> Enum.chunk_by(&Map.get(painted, &1))
      |> Enum.map_join("", fn [first | _] = idxs ->
        seg = binary_part(text, first, length(idxs))

        case Map.get(painted, first) do
          nil -> seg
          %Style{} = style -> sgr(style) <> seg <> @reset
        end
      end)
    end
  end

  @doc "The SGR escape for a `Style` (truecolor fg/bg + attrs). `\"\"` if it paints nothing."
  @spec sgr(Style.t()) :: String.t()
  def sgr(%Style{fg: fg, bg: bg, attrs: attrs}) do
    case attr_codes(attrs) ++ colour_codes(38, fg) ++ colour_codes(48, bg) do
      [] -> ""
      codes -> "\e[" <> Enum.join(codes, ";") <> "m"
    end
  end

  # %{byte_index => Style} — widest spans first so narrower/more-specific win.
  defp paint(theme, spans) do
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

  defp dot_count(capture), do: capture |> String.graphemes() |> Enum.count(&(&1 == "."))

  defp colour_codes(_base, :default), do: []

  defp colour_codes(base, {:rgb, r, g, b}),
    do: [Integer.to_string(base), "2", Integer.to_string(r), Integer.to_string(g), Integer.to_string(b)]

  defp attr_codes(attrs), do: Enum.flat_map(attrs, &attr_code/1)

  defp attr_code(:bold), do: ["1"]
  defp attr_code(:dim), do: ["2"]
  defp attr_code(:italic), do: ["3"]
  defp attr_code(:underline), do: ["4"]
  defp attr_code(:reverse), do: ["7"]
end
