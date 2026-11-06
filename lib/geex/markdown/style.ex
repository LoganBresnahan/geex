defmodule Geex.Markdown.Style do
  @moduledoc """
  The colours and attributes a markdown preview run's roles (`Geex.Markdown.Layout`) get under
  a theme ([ADR-0043](../../../doc/adr/0043-markdown-preview.md) §5), resolved when drawing.

  Themes style tree-sitter captures, and few of them style markdown's, so each role tries the
  captures a theme might style for it and falls back to the palette: headings and links to
  `accent`, code's tint to `active_line_bg`, borders and rules to `line_number`. Roles apply in
  order, outermost first, so a link inside a heading is the link's colour, bold. A code run's
  `{:captures, names}` takes the first capture the theme styles, the colour the editor gives the
  same byte (`Geex.Highlight.Paint`). When the palette has no tint for code (`active_line_bg` is
  `:default`: the terminal theme with no OSC 11 answer), a code row's gutter is drawn as a `▏`
  bar in `line_number`, so a block with no language still reads as code.

  `:strike` is one attribute `Geex.Cell` doesn't have yet; `mix geex.render` writes it.
  """

  alias Geex.Theme
  alias Geex.Theme.Style

  @doc """
  A run as drawn under `theme`: its text and its style.
  """
  @spec run(Theme.t(), {String.t(), [term()]}) :: {String.t(), Style.t()}
  def run(%Theme{} = theme, {text, roles}) do
    style = resolve(theme, roles)

    if :code_gutter in roles and not tinted?(theme),
      do: {"▏", %{style | fg: muted(theme)}},
      else: {text, style}
  end

  @doc "The style for `roles` under `theme`."
  @spec resolve(Theme.t(), [term()]) :: Style.t()
  def resolve(%Theme{palette: p} = theme, roles) do
    Enum.reduce(roles, %Style{fg: p.fg, bg: p.bg, attrs: []}, &role(&1, &2, theme))
  end

  defp role(:heading, st, t),
    do: %{st | fg: pick(t, ["markup.heading", "text.title"], t.palette.accent)} |> attr(:bold)

  defp role(:heading_rule, st, t), do: %{st | fg: t.palette.accent}
  defp role(:strong, st, _t), do: attr(st, :bold)
  defp role(:em, st, _t), do: attr(st, :italic)
  defp role(:strike, st, _t), do: attr(st, :strike)

  defp role(:code, st, t),
    do: %{st | fg: pick(t, ["markup.raw", "text.literal", "string"], st.fg), bg: tint(t, st.bg)}

  defp role(:link, st, t),
    do: %{st | fg: pick(t, ["markup.link", "text.uri"], t.palette.accent)} |> attr(:underline)

  defp role(:image, st, t), do: %{st | fg: t.palette.accent} |> attr(:italic)
  defp role(:quote_bar, st, t), do: %{st | fg: pick(t, ["markup.quote", "comment"], muted(t))}
  defp role(:quote, st, _t), do: attr(st, :italic)

  defp role(:bullet, st, t),
    do: %{st | fg: pick(t, ["markup.list", "punctuation.special"], t.palette.accent)}

  defp role(:task_done, st, t), do: %{st | fg: t.palette.accent}
  defp role(:task_open, st, t), do: %{st | fg: muted(t)}
  defp role(:border, st, t), do: %{st | fg: muted(t)}
  defp role(:rule, st, t), do: %{st | fg: muted(t)}
  defp role(:table_header, st, _t), do: attr(st, :bold)
  defp role(:code_block, st, t), do: %{st | bg: tint(t, st.bg)}
  defp role(:code_label, st, t), do: %{st | fg: pick(t, ["comment"], muted(t))}
  defp role(:muted, st, t), do: %{st | fg: muted(t)}

  defp role(role, st, t) when role in [:html, :meta],
    do: %{st | fg: pick(t, ["comment"], muted(t))}

  defp role({:captures, names}, st, t) do
    case Enum.find_value(names, &Theme.style_for(t, &1)) do
      nil ->
        st

      %Style{} = s ->
        fg = if s.fg == :default, do: st.fg, else: s.fg
        %{st | fg: fg, attrs: Enum.uniq(st.attrs ++ s.attrs)}
    end
  end

  defp role(_role, st, _t), do: st

  defp attr(st, a), do: %{st | attrs: Enum.uniq(st.attrs ++ [a])}

  # The first of `captures` the theme gives a foreground, else `fallback`.
  defp pick(theme, captures, fallback) do
    Enum.find_value(captures, fallback, fn capture ->
      case Theme.style_for(theme, capture) do
        %Style{fg: fg} when fg != :default -> fg
        _ -> nil
      end
    end)
  end

  defp tint(%Theme{palette: %{active_line_bg: bg}}, _base) when bg not in [nil, :default], do: bg
  defp tint(_theme, base), do: base

  defp tinted?(%Theme{palette: %{active_line_bg: bg}}), do: bg not in [nil, :default]

  defp muted(%Theme{palette: %{line_number: c}}) when c not in [nil, :default], do: c
  defp muted(%Theme{palette: p}), do: p.fg
end
