defmodule Geex.Theme.BirdsOfParadise do
  @moduledoc """
  The **Birds of Paradise** theme — geex's first theme and the template others
  follow ([ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md)).

  Ported from the author's Zed theme
  ([birds-of-paradise-zed](../../../../birds-of-paradise-zed)). Because Zed keys
  its `style.syntax` on tree-sitter capture names — the same vocabulary geex
  uses — the port is a near-mechanical 1:1 (Zed `font_style: "italic"` →
  `:italic`, `font_weight: 700` → `:bold`, `#RRGGBB[AA]` → `Geex.Color`). The
  few elixir-grammar captures Zed didn't name (e.g. `module`) reuse the obvious
  sibling colour; everything else resolves by longest-prefix at lookup time.
  """

  alias Geex.Color
  alias Geex.Theme
  alias Geex.Theme.{Palette, Style}

  @bg Color.from_hex("#372725")

  @doc "The Birds of Paradise `Geex.Theme`."
  @spec theme() :: Theme.t()
  def theme do
    %Theme{
      name: "Birds of Paradise",
      appearance: :dark,
      palette: %Palette{
        bg: @bg,
        fg: Color.from_hex("#E6E1C4"),
        line_number: Color.from_hex("#6B4E32"),
        active_line_number: Color.from_hex("#E6E1C4"),
        active_line_bg: Color.from_hex("#281C1C66", @bg),
        cursor: Color.from_hex("#EF5D32"),
        selection: Color.from_hex("#EF5D3233", @bg)
      },
      styles: styles()
    }
  end

  # capture name → Style. Keys are tree-sitter captures (Zed's `style.syntax`
  # verbatim, plus a few elixir-grammar captures). Longest-prefix resolution at
  # lookup means we only list the names that carry a *distinct* style.
  defp styles do
    %{
      "attribute" => fg("#EFAC32"),
      "boolean" => fg("#6C99BB"),
      "comment" => fg("#6B4E32", [:italic]),
      "comment.doc" => fg("#6B4E32", [:italic]),
      "constant" => fg("#6C99BB"),
      "constructor" => fg("#EFAC32"),
      "embedded" => fg("#E6E1C4"),
      "emphasis" => fg("#EF5D32", [:italic]),
      "emphasis.strong" => fg("#EF5D32", [:bold]),
      "enum" => fg("#6C99BB"),
      "function" => fg("#EFAC32"),
      "hint" => fg("#8A9A95", [:italic]),
      "keyword" => fg("#EF5D32"),
      "label" => fg("#EFAC32"),
      "module" => fg("#EFAC32"),
      "namespace" => fg("#EFAC32"),
      "number" => fg("#6C99BB"),
      "operator" => fg("#EF5D32"),
      "preproc" => fg("#8996A8"),
      "primary" => fg("#E6E1C4"),
      "property" => fg("#E6E1C4"),
      "punctuation" => fg("#E6E1C4"),
      "punctuation.bracket" => fg("#E6E1C4"),
      "punctuation.delimiter" => fg("#E6E1C4"),
      "punctuation.special" => fg("#EF5D32"),
      "string" => fg("#D9D762", [:italic]),
      "string.escape" => fg("#BE73FD"),
      "string.regex" => fg("#8856D2"),
      "string.special" => fg("#6C99BB", [:italic]),
      "string.special.symbol" => fg("#6C99BB"),
      "tag" => fg("#86B4BB"),
      "text.literal" => fg("#D9D762"),
      "title" => fg("#EFAC32", [:bold]),
      "type" => fg("#EFAC32"),
      "variable" => fg("#7DAF9C"),
      "variable.special" => fg("#C699BB"),
      "variant" => fg("#6C99BB")
    }
  end

  defp fg(hex, attrs \\ []), do: %Style{fg: Color.from_hex(hex), attrs: attrs}
end
