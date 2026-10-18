defmodule Geex.Theme do
  @moduledoc """
  A theme: capture name → `Style` (syntax) plus a `Palette` (editor chrome).

  [ADR-0023](../../doc/adr/0023-theming-and-extension-loading.md): a theme is
  **swappable data, never code**. Its vocabulary is the **tree-sitter capture
  name** (the engine↔theme contract from
  [ADR-0021](../../doc/adr/0021-capability-connections.md)) — *not* any external
  format. External formats (Zed/Helix/VS Code) are importer-adapters that
  produce this struct; because Zed/Helix already key on tree-sitter captures,
  that import is near-lossless (`Geex.Theme.Import.Zed`).

  A theme is **loaded from a JSON data file**, not written in code — `load/1`
  reads + validates one, `bundled/1` loads a default from `priv/themes/<name>.json`,
  and `default/0` is Birds of Paradise (`priv/themes/birds-of-paradise.json`, the
  author's Zed port and the reference others copy). The native shape:

      {
        "name": "Birds of Paradise",
        "appearance": "dark",
        "palette": { "bg": "#372725", "fg": "#E6E1C4", ... },
        "syntax": {
          "keyword": "#EF5D32",                         // bare hex = fg only
          "comment": { "fg": "#6B4E32", "italic": true } // object adds attrs
        }
      }

  Resolution is **longest-prefix**: a capture like `string.escape` falls back to
  `string` if the theme doesn't style the more specific name, and
  `comment.doc.__attribute__` falls back through `comment.doc` to `comment`.
  """

  alias Geex.Theme.{Palette, Style}

  @enforce_keys [:name, :appearance, :styles, :palette]
  defstruct [:name, :appearance, :styles, :palette]

  @type appearance :: :dark | :light
  @type t :: %__MODULE__{
          name: String.t(),
          appearance: appearance(),
          styles: %{optional(String.t()) => Style.t()},
          palette: Palette.t()
        }

  @doc """
  Resolve a capture name to a `Style` via longest-prefix fallback, or `nil` if
  neither it nor any prefix is styled (the renderer then leaves default fg).
  """
  @spec style_for(t(), String.t()) :: Style.t() | nil
  def style_for(%__MODULE__{styles: styles}, capture) when is_binary(capture) do
    resolve(styles, capture)
  end

  defp resolve(styles, capture) do
    case Map.fetch(styles, capture) do
      {:ok, style} ->
        style

      :error ->
        case drop_last_segment(capture) do
          :done -> nil
          shorter -> resolve(styles, shorter)
        end
    end
  end

  defp drop_last_segment(capture) do
    case String.split(capture, ".") do
      [_only] -> :done
      parts -> parts |> Enum.drop(-1) |> Enum.join(".")
    end
  end

  ## Loading (themes are data — ADR-0023)

  @default_theme "birds-of-paradise"

  @doc "geex's default theme — Birds of Paradise, the bundled reference."
  @spec default() :: t()
  def default, do: bundled!(@default_theme)

  @doc """
  The themes there are by name: the built-in `"terminal"` (`Geex.Theme.Terminal`, the terminal's
  own colours, ADR-0040) and each bundled file.
  """
  @spec names() :: [String.t()]
  def names do
    bundled =
      Application.app_dir(:geex, "priv/themes")
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))

    installed = Enum.map(Geex.Installed.themes(), & &1["name"])
    terminal = Geex.Theme.Terminal.name()
    # The built-in name always means the built-in theme.
    [terminal | Enum.sort(Enum.uniq(installed ++ bundled) -- [terminal])]
  end

  @doc """
  Load the theme named `name`: an installed one (ADR-0040 §4), else a bundled one. The built-in
  `"terminal"` theme isn't a file; see `Geex.Theme.Terminal`.
  """
  @spec named(String.t()) :: {:ok, t()} | {:error, term()}
  def named(name) when is_binary(name) do
    case Geex.Installed.theme(name) do
      %{"dir" => dir} -> load(Path.join(dir, name <> ".json"))
      nil -> bundled(name)
    end
  end

  @doc "Load a bundled theme by name from `priv/themes/<name>.json`."
  @spec bundled(String.t()) :: {:ok, t()} | {:error, term()}
  def bundled(name) when is_binary(name) do
    load(Application.app_dir(:geex, Path.join(["priv", "themes", name <> ".json"])))
  end

  @doc "Like `bundled/1` but raises — for the known-good bundled set."
  @spec bundled!(String.t()) :: t()
  def bundled!(name) do
    case bundled(name) do
      {:ok, theme} ->
        theme

      {:error, reason} ->
        raise "geex: cannot load bundled theme #{inspect(name)}: #{inspect(reason)}"
    end
  end

  @doc """
  Load + validate a native theme JSON file. Returns `{:ok, t}` or `{:error, reason}`
  (`{:read, posix}` / `{:bad_json, _}` / `{:missing, field}` / `{:bad_color, where,
  value}` / …) — never raises on a bad file.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, content} <- read(path),
         {:ok, data} <- decode(content) do
      from_json(data)
    end
  end

  @doc "Build a theme from a decoded native-format map (the validating core)."
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(%{} = data) do
    with {:ok, name} <- req_string(data, "name"),
         {:ok, appearance} <- appearance(data),
         {:ok, palette} <- build_palette(data),
         {:ok, syntax} <- build_syntax(Map.get(data, "syntax", %{}), palette.bg) do
      {:ok, %__MODULE__{name: name, appearance: appearance, palette: palette, styles: syntax}}
    end
  end

  def from_json(_), do: {:error, :not_a_theme_object}

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

  defp req_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, v} -> {:error, {:bad_field, key, v}}
      :error -> {:error, {:missing, key}}
    end
  end

  defp appearance(data) do
    case Map.get(data, "appearance", "dark") do
      "dark" -> {:ok, :dark}
      "light" -> {:ok, :light}
      other -> {:error, {:bad_appearance, other}}
    end
  end

  defp build_palette(%{"palette" => pal}) when is_map(pal) do
    with {:ok, bg} <- req_color(pal, "bg", nil),
         {:ok, fg} <- req_color(pal, "fg", bg),
         {:ok, line_number} <- opt_color(pal, "line_number", bg, bg),
         {:ok, active_line_number} <- opt_color(pal, "active_line_number", bg, fg),
         {:ok, active_line_bg} <- opt_color(pal, "active_line_bg", bg, bg),
         {:ok, cursor} <- opt_color(pal, "cursor", bg, fg),
         {:ok, selection} <- opt_color(pal, "selection", bg, fg) do
      {:ok,
       %Palette{
         bg: bg,
         fg: fg,
         line_number: line_number,
         active_line_number: active_line_number,
         active_line_bg: active_line_bg,
         cursor: cursor,
         selection: selection
       }}
    end
  end

  defp build_palette(_), do: {:error, {:missing, "palette"}}

  defp build_syntax(syntax, bg) when is_map(syntax) do
    Enum.reduce_while(syntax, {:ok, %{}}, fn {capture, spec}, {:ok, acc} ->
      case style(spec, bg, capture) do
        {:ok, st} -> {:cont, {:ok, Map.put(acc, capture, st)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp build_syntax(_, _bg), do: {:error, {:bad_field, "syntax", :not_a_map}}

  # A syntax spec is a bare hex string (fg only) or an object {fg, bg?, attrs…}.
  defp style(hex, bg, capture) when is_binary(hex) do
    with {:ok, fg} <- color(hex, bg, capture), do: {:ok, %Style{fg: fg}}
  end

  defp style(%{} = obj, bg, capture) do
    with {:ok, fg} <- req_color(obj, "fg", bg, capture),
         {:ok, bg_c} <- opt_color(obj, "bg", bg, :default, capture) do
      {:ok, %Style{fg: fg, bg: bg_c, attrs: attrs(obj)}}
    end
  end

  defp style(other, _bg, capture), do: {:error, {:bad_style, capture, other}}

  defp attrs(obj) do
    for {key, attr} <- [
          {"bold", :bold},
          {"italic", :italic},
          {"underline", :underline},
          {"dim", :dim},
          {"reverse", :reverse}
        ],
        Map.get(obj, key) == true,
        do: attr
  end

  # Colour helpers. `label` is what an error names (a palette key or a capture).
  defp req_color(map, key, bg, label \\ nil) do
    case Map.fetch(map, key) do
      {:ok, hex} -> color(hex, bg, label || key)
      :error -> {:error, {:missing, dotted(label, key)}}
    end
  end

  defp opt_color(map, key, bg, default, label \\ nil) do
    case Map.fetch(map, key) do
      {:ok, hex} -> color(hex, bg, label || key)
      :error -> {:ok, default}
    end
  end

  defp color(hex, bg, label) do
    case Geex.Color.parse(hex, bg) do
      {:ok, rgb} -> {:ok, rgb}
      :error -> {:error, {:bad_color, label, hex}}
    end
  end

  defp dotted(nil, key), do: key
  defp dotted(label, _key), do: label
end
