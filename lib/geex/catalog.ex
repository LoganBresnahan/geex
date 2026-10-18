defmodule Geex.Catalog do
  @moduledoc """
  The catalog this build of geex can install from ([ADR-0040](../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §2): `catalog/catalog.json`, written by `mix geex.catalog`, embedded at compile time. Each
  package has its sha256, so what geex installs is fixed by the binary, and nothing here
  touches the network: knowing what's available, or that an installed package differs from
  this geex's, needs no request.

  An entry is a map with string keys, as in the JSON: `name`, `display`, `asset`, `url`, `size`,
  `sha256`, `license`; a grammar also `extensions`, `filenames`, `abi` and `upstream`; a theme
  `appearance`.
  """

  @path Path.expand("../../catalog/catalog.json", __DIR__)
  @external_resource @path

  @catalog (case File.read(@path) do
              {:ok, json} -> JSON.decode!(json)
              {:error, _} -> %{"grammars" => [], "themes" => []}
            end)

  @type entry :: %{optional(String.t()) => term()}

  @doc "The grammars, by name."
  @spec grammars() :: [entry()]
  def grammars, do: @catalog["grammars"]

  @doc "The themes, by name."
  @spec themes() :: [entry()]
  def themes, do: @catalog["themes"]

  @doc "The grammar named `name`, or nil."
  @spec grammar(String.t()) :: entry() | nil
  def grammar(name), do: Enum.find(grammars(), &(&1["name"] == name))

  @doc "The theme named `name`, or nil."
  @spec theme(String.t()) :: entry() | nil
  def theme(name), do: Enum.find(themes(), &(&1["name"] == name))

  @doc """
  The catalog grammar for a file `path`, or nil: a whole file name first (`rebar.config`), then
  the longest file-name ending (`.app.src` before `.src`). For the hint that highlighting is
  available (ADR-0040 §4), so it says nothing about what's installed.

      iex> Geex.Catalog.for_path("lib/geex/loop.ex")["name"]
      "elixir"
      iex> Geex.Catalog.for_path("/x/y.tsx")["name"]
      "tsx"
      iex> Geex.Catalog.for_path("src/app.app.src")["name"]
      "erlang"
      iex> Geex.Catalog.for_path("README")
      nil
  """
  @spec for_path(String.t()) :: entry() | nil
  def for_path(path), do: match(grammars(), Path.basename(path))

  @doc """
  The entry in `entries` (manifests or catalog entries, each with `extensions` and `filenames`)
  for a file named `basename`: an exact `filenames` match, else the longest matching ending.
  Shared with what's installed (step 5).
  """
  @spec match([entry()], String.t()) :: entry() | nil
  def match(entries, basename) do
    Enum.find(entries, &(basename in Map.get(&1, "filenames", []))) ||
      entries
      |> Enum.flat_map(fn e ->
        for ext <- Map.get(e, "extensions", []),
            String.ends_with?(basename, ext) and basename != ext,
            do: {byte_size(ext), e}
      end)
      |> Enum.max_by(&elem(&1, 0), fn -> {0, nil} end)
      |> elem(1)
  end
end
