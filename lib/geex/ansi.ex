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
  demo). For the live editor, `Geex.Highlight.Paint.to_screen/6` projects the same
  spans onto the `Geex.Screen`/`Geex.Cell` grid and `Geex.Renderer` emits the SGR;
  both share the per-byte resolution in `Geex.Highlight.Paint` and the encoding in
  `Geex.Sgr`.
  """

  alias Geex.Highlight.Paint
  alias Geex.Sgr
  alias Geex.Theme
  alias Geex.Theme.Style

  @doc """
  Render `text` highlighted by `spans` under `theme` to a truecolor ANSI string.
  Byte offsets in `spans` index `text` directly.
  """
  @spec highlight(Theme.t(), String.t(), [Geex.Highlight.Span.t()]) :: String.t()
  def highlight(%Theme{} = theme, text, spans) when is_binary(text) do
    painted = Paint.styles(theme, spans)
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
          %Style{} = style -> sgr(style) <> seg <> Sgr.reset()
        end
      end)
    end
  end

  @doc "The SGR escape for a `Style` (truecolor fg/bg + attrs). `\"\"` if it paints nothing."
  @spec sgr(Style.t()) :: String.t()
  def sgr(%Style{fg: fg, bg: bg, attrs: attrs}), do: Sgr.escape(fg, bg, attrs)
end
