defmodule Geex.Sgr do
  @moduledoc """
  Encode a cell style — foreground/background colour + attrs — as an ANSI **SGR**
  escape. The single place colour/attr → terminal bytes happens, shared by the
  highlight string renderer (`Geex.Ansi`) and the screen renderer (`Geex.Renderer`).

  Supports every `Geex.Cell` colour shape: `:default` (emit nothing — the
  terminal default), `{:ansi, 0..15}` (the 16-colour SGR codes 30–37/90–97 fg,
  40–47/100–107 bg), `{:xterm, 0..255}` (256-colour `38;5;n` / `48;5;n`), and
  `{:rgb, r, g, b}` (24-bit truecolor `38;2;r;g;b` / `48;2;r;g;b`).
  """

  @reset "\e[0m"

  @doc "The SGR reset sequence."
  @spec reset() :: binary()
  def reset, do: @reset

  @doc """
  The SGR escape for `fg`/`bg`/`attrs`, or `\"\"` when it would paint nothing
  (default colours, no attrs) — so callers can skip emitting bytes for plain cells.
  """
  @spec escape(Geex.Cell.colour(), Geex.Cell.colour(), [Geex.Cell.attr()]) :: binary()
  def escape(fg, bg, attrs) do
    case attr_codes(attrs) ++ fg_codes(fg) ++ bg_codes(bg) do
      [] -> ""
      codes -> "\e[" <> Enum.join(codes, ";") <> "m"
    end
  end

  defp fg_codes(:default), do: []
  defp fg_codes({:rgb, r, g, b}), do: ["38", "2", i(r), i(g), i(b)]
  defp fg_codes({:xterm, n}), do: ["38", "5", i(n)]
  defp fg_codes({:ansi, n}) when n in 0..7, do: [i(30 + n)]
  defp fg_codes({:ansi, n}) when n in 8..15, do: [i(90 + (n - 8))]

  defp bg_codes(:default), do: []
  defp bg_codes({:rgb, r, g, b}), do: ["48", "2", i(r), i(g), i(b)]
  defp bg_codes({:xterm, n}), do: ["48", "5", i(n)]
  defp bg_codes({:ansi, n}) when n in 0..7, do: [i(40 + n)]
  defp bg_codes({:ansi, n}) when n in 8..15, do: [i(100 + (n - 8))]

  defp attr_codes(attrs), do: Enum.flat_map(attrs, &attr_code/1)

  defp attr_code(:bold), do: ["1"]
  defp attr_code(:dim), do: ["2"]
  defp attr_code(:italic), do: ["3"]
  defp attr_code(:underline), do: ["4"]
  defp attr_code(:reverse), do: ["7"]

  defp i(n), do: Integer.to_string(n)
end
