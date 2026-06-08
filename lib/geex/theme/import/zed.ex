defmodule Geex.Theme.Import.Zed do
  @moduledoc """
  Import a [Zed](https://zed.dev) theme into geex's native `Geex.Theme`
  ([ADR-0023](../../../../doc/adr/0023-theming-and-extension-loading.md)).

  Zed keys its `style.syntax` on **tree-sitter capture names** — the same
  vocabulary geex uses — so the import is near-lossless: it reshapes a Zed theme
  JSON into geex's native map and hands it to `Geex.Theme.from_json/1`, reusing
  all of that validation + colour parsing. `font_style: "italic"` → `italic`,
  `font_weight: 700` → `bold`; the UI palette comes from the `editor.*` keys and
  the first `players` entry (cursor/selection).

  This is the importer-adapter pattern: geex owns the native format; an external
  format is a pure transform onto it. (A Helix importer would be the same shape;
  VS Code is the lossy, deferred one — TextMate scopes, not captures.)
  """

  alias Geex.Theme

  @doc "Import a decoded Zed theme map (a family `{themes: [...]}` or a single theme)."
  @spec import_map(map()) :: {:ok, Theme.t()} | {:error, term()}
  def import_map(%{"themes" => [theme | _]}), do: import_theme(theme)
  def import_map(%{"style" => _} = theme), do: import_theme(theme)
  def import_map(_), do: {:error, :not_a_zed_theme}

  @doc "Read + import a Zed theme JSON file."
  @spec import_file(Path.t()) :: {:ok, Theme.t()} | {:error, term()}
  def import_file(path) when is_binary(path) do
    with {:ok, content} <- read(path),
         {:ok, data} <- decode(content) do
      import_map(data)
    end
  end

  defp import_theme(%{"style" => style} = theme) when is_map(style) do
    Theme.from_json(%{
      "name" => Map.get(theme, "name", "Imported"),
      "appearance" => Map.get(theme, "appearance", "dark"),
      "palette" => palette(style),
      "syntax" => syntax(style)
    })
  end

  defp import_theme(_), do: {:error, :not_a_zed_theme}

  defp palette(style) do
    %{}
    |> put_present("bg", first(style, ["editor.background", "background"]))
    |> put_present("fg", first(style, ["editor.foreground", "text"]))
    |> put_present("line_number", style["editor.line_number"])
    |> put_present("active_line_number", style["editor.active_line_number"])
    |> put_present("active_line_bg", style["editor.active_line.background"])
    |> put_present("cursor", player(style, "cursor"))
    |> put_present("selection", player(style, "selection"))
  end

  defp syntax(%{"syntax" => syn}) when is_map(syn) do
    syn
    |> Enum.flat_map(fn {capture, spec} ->
      case style_spec(spec) do
        nil -> []
        native -> [{capture, native}]
      end
    end)
    |> Map.new()
  end

  defp syntax(_), do: %{}

  # Zed: {"color": "#…", "font_style": "italic", "font_weight": 700}. No colour → skip.
  defp style_spec(%{"color" => color} = spec) when is_binary(color) do
    %{"fg" => color}
    |> maybe_put("italic", Map.get(spec, "font_style") == "italic")
    |> maybe_put("bold", bold?(Map.get(spec, "font_weight")))
  end

  defp style_spec(_), do: nil

  defp bold?(weight) when is_integer(weight), do: weight >= 700
  defp bold?(_), do: false

  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, true), do: Map.put(map, key, true)

  defp player(style, field) do
    case style["players"] do
      [first | _] when is_map(first) -> Map.get(first, field)
      _ -> nil
    end
  end

  defp first(style, keys), do: Enum.find_value(keys, fn k -> Map.get(style, k) end)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, posix} -> {:error, {:read, posix}}
    end
  end

  defp decode(content) do
    case JSON.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:bad_json, reason}}
    end
  end
end
