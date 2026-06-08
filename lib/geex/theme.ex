defmodule Geex.Theme do
  @moduledoc """
  A theme: capture name → `Style` (syntax) plus a `Palette` (editor chrome).

  [ADR-0023](../../doc/adr/0023-theming-and-extension-loading.md): a theme is
  **swappable data, never code**. Its vocabulary is the **tree-sitter capture
  name** (the engine↔theme contract from
  [ADR-0021](../../doc/adr/0021-capability-connections.md)) — *not* any external
  format. External formats (Zed/Helix/VS Code) are importer-adapters that
  produce this struct; because Zed/Helix already key on tree-sitter captures,
  that import is near-lossless. `Geex.Theme.BirdsOfParadise` is the first theme
  (the author's Zed port) and the template others follow.

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
end
