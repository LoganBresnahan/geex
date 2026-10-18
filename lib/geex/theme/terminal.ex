defmodule Geex.Theme.Terminal do
  @moduledoc """
  The built-in theme that is the user's own terminal ([ADR-0040](../../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §1): the default foreground and background (SGR 39/49) and the 16 ANSI colours, so geex looks
  right in any terminal and any colour scheme with no theme installed. It is code, not a file:
  there is nothing to install or to fail to load.

  Syntax captures map to ANSI colours (keywords magenta, strings green, comments dim and italic,
  and so on), resolved by longest prefix like any theme.

  To shade the active line and the selection, it needs the terminal's background, which
  `Geex.TerminalIO` asks for (OSC 11). Given one, `theme/1` blends a subtle tint from it,
  lighter on a dark background and darker on a light one. Without one, there is no active-line
  shade and the palette's `mark` is `[:reverse]`: the selection and picked rows are drawn in
  reverse video.
  """

  alias Geex.Theme
  alias Geex.Theme.{Palette, Style}

  @name "terminal"

  # How far the active line and the selection move from the background toward its contrast.
  @active_line 0.07
  @selection 0.22

  @syntax %{
    "attribute" => {3, []},
    "boolean" => {3, []},
    # Dim, not bright black: some schemes (Solarized Dark) make ANSI 8 the background itself.
    "comment" => {:default, [:dim, :italic]},
    "constant" => {3, []},
    "constant.builtin" => {3, []},
    "constructor" => {6, []},
    "embedded" => {:default, []},
    "emphasis" => {:default, [:italic]},
    "emphasis.strong" => {:default, [:bold]},
    "enum" => {6, []},
    "function" => {4, []},
    "hint" => {:default, [:dim]},
    "keyword" => {5, []},
    "label" => {5, []},
    "markup.bold" => {:default, [:bold]},
    "markup.heading" => {4, [:bold]},
    "markup.italic" => {:default, [:italic]},
    "markup.link" => {4, [:underline]},
    "markup.raw" => {2, []},
    "module" => {6, []},
    "namespace" => {6, []},
    "number" => {3, []},
    "operator" => {:default, []},
    "preproc" => {5, []},
    "primary" => {:default, []},
    "property" => {:default, []},
    "punctuation" => {:default, []},
    "punctuation.special" => {5, []},
    "string" => {2, []},
    "string.escape" => {6, []},
    "string.regex" => {6, []},
    "string.special" => {6, []},
    "string.special.symbol" => {6, []},
    "tag" => {4, []},
    "text.literal" => {2, []},
    "title" => {4, [:bold]},
    "type" => {6, []},
    "variable" => {:default, []},
    "variable.builtin" => {5, []},
    "variable.special" => {5, []},
    "variant" => {6, []}
  }

  @doc "The theme's name, as the `theme` verb takes it."
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  The terminal theme. `bg` is the terminal's background, if it answered (OSC 11).

      iex> t = Geex.Theme.Terminal.theme(nil)
      iex> {t.palette.bg, t.palette.active_line_bg, t.palette.mark}
      {:default, :default, [:reverse]}
      iex> Geex.Theme.style_for(t, "string.special.key").fg
      {:ansi, 6}

      iex> t = Geex.Theme.Terminal.theme({:rgb, 0, 0, 0})
      iex> {t.appearance, t.palette.active_line_bg, t.palette.selection, t.palette.mark}
      {:dark, {:rgb, 18, 18, 18}, {:rgb, 56, 56, 56}, []}
      iex> Geex.Theme.Terminal.theme({:rgb, 255, 255, 255}).palette.active_line_bg
      {:rgb, 237, 237, 237}
  """
  @spec theme(Geex.Color.rgb() | nil) :: Theme.t()
  def theme(bg) do
    %Theme{
      name: @name,
      appearance: appearance(bg),
      palette: palette(bg),
      styles:
        Map.new(@syntax, fn {capture, {colour, attrs}} -> {capture, style(colour, attrs)} end)
    }
  end

  defp style(:default, attrs), do: %Style{fg: :default, attrs: attrs}
  defp style(n, attrs), do: %Style{fg: {:ansi, n}, attrs: attrs}

  defp palette(nil) do
    %Palette{
      bg: :default,
      fg: :default,
      line_number: {:ansi, 8},
      active_line_number: :default,
      active_line_bg: :default,
      cursor: {:ansi, 3},
      selection: :default,
      # What the Alt+Y view shows as installed: bright cyan, the terminal's light blue.
      installed: {:ansi, 14},
      mark: [:reverse]
    }
  end

  defp palette({:rgb, _, _, _} = bg) do
    dark? = appearance(bg) == :dark
    toward = if dark?, do: {:rgb, 255, 255, 255}, else: {:rgb, 0, 0, 0}

    %{
      palette(nil)
      | active_line_bg: mix(bg, toward, @active_line),
        selection: mix(bg, toward, @selection),
        # On a light background cyan washes out: blue.
        installed: if(dark?, do: {:ansi, 14}, else: {:ansi, 4}),
        mark: []
    }
  end

  # Dark when the background's relative luminance is under half.
  defp appearance(nil), do: :dark

  defp appearance({:rgb, r, g, b}),
    do: if(0.2126 * r + 0.7152 * g + 0.0722 * b < 128, do: :dark, else: :light)

  defp mix({:rgb, r, g, b}, {:rgb, tr, tg, tb}, t),
    do: {:rgb, blend(r, tr, t), blend(g, tg, t), blend(b, tb, t)}

  defp blend(from, to, t), do: round(from + (to - from) * t)

  @doc """
  The terminal's background from an OSC 11 answer's colour spec: `rgb:R/G/B` (or `rgba:`), each
  1 to 4 hex digits, scaled to 0..255. Anything else is `:error`.

      iex> Geex.Theme.Terminal.parse_rgb("rgb:1e1e/1e1e/2e2e")
      {:ok, {:rgb, 30, 30, 46}}
      iex> Geex.Theme.Terminal.parse_rgb("rgb:ff/80/00")
      {:ok, {:rgb, 255, 128, 0}}
      iex> Geex.Theme.Terminal.parse_rgb("#123456")
      :error
  """
  @spec parse_rgb(String.t()) :: {:ok, Geex.Color.rgb()} | :error
  def parse_rgb("rgb:" <> spec), do: components(String.split(spec, "/"))
  def parse_rgb("rgba:" <> spec), do: components(Enum.take(String.split(spec, "/"), 3))
  def parse_rgb(_spec), do: :error

  defp components([_, _, _] = parts) do
    scaled =
      for part <- parts, byte_size(part) in 1..4, {n, ""} <- [Integer.parse(part, 16)] do
        max = Integer.pow(16, byte_size(part)) - 1
        round(n * 255 / max)
      end

    case scaled do
      [r, g, b] -> {:ok, {:rgb, r, g, b}}
      _ -> :error
    end
  end

  defp components(_parts), do: :error
end
