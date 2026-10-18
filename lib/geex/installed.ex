defmodule Geex.Installed do
  @moduledoc """
  The grammars and themes on this machine ([ADR-0040](../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §4): `$XDG_DATA_HOME/geex/grammars/<name>/` and `…/themes/<name>/` (default
  `~/.local/share/geex/`), each a package's files plus `installed.json`, which `Geex.Install`
  writes last. A directory without it is an install that didn't finish, and is ignored.

  The bundled grammars in `priv/grammars` are read the same way (each has a `manifest.json`)
  until geex ships bare (step 7); an installed one of the same name wins.

  Reading the directories is cached (`:persistent_term`): `refresh/0` reads them again, which
  an install does, and so does opening the settings view. Every entry is its manifest (string
  keys, as in the JSON) plus `"dir"`, and `"installed"` (the record) for a real install.
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

  @doc "The grammars there are, by name: installed, then bundled ones not installed."
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
    installed = read_kind(Path.join(root(), "grammars"), true)
    names = MapSet.new(installed, & &1["name"])

    bundled =
      read_kind(bundled_dir(), false)
      |> Enum.reject(&(&1["name"] in names))

    %{
      grammars: Enum.sort_by(installed ++ bundled, & &1["name"]),
      themes: read_kind(Path.join(root(), "themes"), true)
    }
  end

  defp bundled_dir do
    Application.app_dir(:geex, Path.join("priv", "grammars"))
  rescue
    ArgumentError -> "/nonexistent"
  end

  # Each directory with a readable manifest (and, for an install, its record).
  defp read_kind(parent, record?) do
    case File.ls(parent) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(&read_package(Path.join(parent, &1), record?))

      {:error, _} ->
        []
    end
  end

  defp read_package(dir, record?) do
    with {:ok, manifest} <- read_json(Path.join(dir, "manifest.json")),
         {:ok, record} <-
           if(record?, do: read_json(Path.join(dir, "installed.json")), else: {:ok, nil}),
         true <- manifest["name"] == Path.basename(dir) do
      entry = Map.put(manifest, "dir", dir)
      [if(record, do: Map.put(entry, "installed", record), else: entry)]
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
