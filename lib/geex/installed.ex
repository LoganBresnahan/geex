defmodule Geex.Installed do
  @moduledoc """
  The grammars and themes on this machine ([ADR-0040](../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §4): `$XDG_DATA_HOME/geex/grammars/<name>/` and `…/themes/<name>/` (default
  `~/.local/share/geex/`), each a package's files plus `installed.json`, which `Geex.Install`
  writes last. A directory without it is an install that didn't finish, and is ignored.

  geex ships with none (ADR-0040 §1): these directories are every grammar and theme it has, the
  built-in terminal theme aside.

  Reading the directories is cached (`:persistent_term`): `refresh/0` reads them again, which
  an install does, and so does opening the settings view. Every entry is its manifest (string
  keys, as in the JSON) plus `"dir"` and `"installed"` (the record).
  """

  @key {__MODULE__, :packages}

  @doc """
  Where installed packages live: `$XDG_DATA_HOME/geex`, else `~/.local/share/geex`; the app's
  `data_dir`, when set, instead (tests).
  """
  @spec root() :: Path.t()
  def root do
    case {Application.get_env(:geex, :data_dir), System.get_env("XDG_DATA_HOME")} do
      {dir, _} when is_binary(dir) -> dir
      {nil, xdg} when xdg in [nil, ""] -> Path.expand("~/.local/share/geex")
      {nil, xdg} -> Path.join(xdg, "geex")
    end
  end

  @doc "The directory for a `:grammar` or `:theme` named `name`."
  @spec dir(:grammar | :theme, String.t()) :: Path.t()
  def dir(:grammar, name), do: Path.join([root(), "grammars", name])
  def dir(:theme, name), do: Path.join([root(), "themes", name])

  @doc "The installed grammars, by name."
  @spec grammars() :: [map()]
  def grammars, do: packages().grammars

  @doc "The installed themes, by name."
  @spec themes() :: [map()]
  def themes, do: packages().themes

  @doc "The grammar named `name`, or nil."
  @spec grammar(String.t()) :: map() | nil
  def grammar(name), do: Enum.find(grammars(), &(&1["name"] == name))

  @doc "The installed theme named `name`, or nil."
  @spec theme(String.t()) :: map() | nil
  def theme(name), do: Enum.find(themes(), &(&1["name"] == name))

  @doc "The grammar for a file `path`: a whole file name, then the longest ending."
  @spec for_path(String.t()) :: map() | nil
  def for_path(path), do: Geex.Catalog.match(grammars(), Path.basename(path))

  @doc """
  Whether the catalog has a different build of an installed package (its sha256 differs), so
  "update" can be offered with no request (ADR-0040 §3). A local install never has one.
  """
  @spec update?(map()) :: boolean()
  def update?(%{"installed" => %{"source" => "catalog", "sha256" => sha}, "name" => name} = pkg) do
    entry =
      if pkg["kind"] == "theme", do: Geex.Catalog.theme(name), else: Geex.Catalog.grammar(name)

    entry != nil and entry["sha256"] != sha
  end

  def update?(_pkg), do: false

  @doc "Read the directories again."
  @spec refresh() :: :ok
  def refresh do
    :persistent_term.put(@key, read())
    :ok
  end

  defp packages do
    case :persistent_term.get(@key, nil) do
      nil ->
        refresh()
        :persistent_term.get(@key)

      packages ->
        packages
    end
  end

  defp read do
    %{
      grammars: read_kind(Path.join(root(), "grammars")),
      themes: read_kind(Path.join(root(), "themes"))
    }
  end

  # Each directory with a readable manifest and its record, by name.
  defp read_kind(parent) do
    case File.ls(parent) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(&read_package(Path.join(parent, &1)))

      {:error, _} ->
        []
    end
  end

  defp read_package(dir) do
    with {:ok, manifest} <- read_json(Path.join(dir, "manifest.json")),
         {:ok, record} <- read_json(Path.join(dir, "installed.json")),
         true <- manifest["name"] == Path.basename(dir) do
      [manifest |> Map.put("dir", dir) |> Map.put("installed", record)]
    else
      _ -> []
    end
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = map} <- JSON.decode(bytes) do
      {:ok, map}
    else
      _ -> :error
    end
  end
end
