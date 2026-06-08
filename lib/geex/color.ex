defmodule Geex.Color do
  @moduledoc """
  Parse hex colours to 24-bit truecolor and flatten alpha against a background.

  Terminals have **no alpha** ([ADR-0023](../../doc/adr/0023-theming-and-extension-loading.md)),
  so an `#RRGGBBAA` colour from a theme is composited over an opaque background
  at load time and stored as a plain `{:rgb, r, g, b}` (the `Geex.Cell` colour
  shape). This is the only place colour math lives.
  """

  @type rgb :: {:rgb, 0..255, 0..255, 0..255}

  @doc """
  Parse `#RRGGBB` or `#RRGGBBAA`. An 8-digit colour is flattened against `bg`
  (an already-opaque `{:rgb, …}`); without a `bg`, alpha composites over black.
  """
  @spec from_hex(String.t(), rgb() | nil) :: rgb()
  def from_hex(hex, bg \\ nil)

  def from_hex("#" <> <<r::binary-2, g::binary-2, b::binary-2>>, _bg) do
    {:rgb, byte(r), byte(g), byte(b)}
  end

  def from_hex("#" <> <<r::binary-2, g::binary-2, b::binary-2, a::binary-2>>, bg) do
    flatten({:rgb, byte(r), byte(g), byte(b)}, byte(a), bg || {:rgb, 0, 0, 0})
  end

  @doc "Composite `fg` at alpha `a` (0..255) over opaque `bg`."
  @spec flatten(rgb(), 0..255, rgb()) :: rgb()
  def flatten({:rgb, fr, fg, fb}, a, {:rgb, br, bg, bb}) do
    blend = fn f, b -> round((f * a + b * (255 - a)) / 255) end
    {:rgb, blend.(fr, br), blend.(fg, bg), blend.(fb, bb)}
  end

  defp byte(<<_, _>> = two_hex), do: String.to_integer(two_hex, 16)
end
