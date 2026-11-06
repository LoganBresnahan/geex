defmodule Geex.CatalogTest do
  # The embedded catalog and its packages' shape (ADR-0040 §2, §4). The catalog is the
  # committed catalog/catalog.json, written by `mix geex.catalog`.
  use ExUnit.Case, async: true

  alias Geex.Catalog
  alias Geex.Catalog.Package

  doctest Catalog
  doctest Package

  test "every recipe is in the catalog, and nothing else" do
    {grammars, _} = Code.eval_file("catalog/grammars.exs")
    {themes, _} = Code.eval_file("catalog/themes.exs")

    assert Enum.map(Catalog.grammars(), & &1["name"]) == Enum.sort(Enum.map(grammars, & &1.name))
    assert Enum.map(Catalog.themes(), & &1["name"]) == Enum.sort(Enum.map(themes, & &1.name))
  end

  test "each entry is pinned: a sha256, an asset named by it, a URL ending in it, a size" do
    for e <- Catalog.grammars() ++ Catalog.themes() do
      assert e["sha256"] =~ ~r/\A[0-9a-f]{64}\z/, e["name"]

      assert e["asset"] =~
               ~r/\A(grammar|theme)-#{e["name"]}-#{binary_part(e["sha256"], 0, 12)}\.zip\z/

      assert String.ends_with?(e["url"], "/" <> e["asset"])
      assert String.starts_with?(e["url"], "https://")
      assert is_integer(e["size"]) and e["size"] > 0
      assert is_binary(e["license"]) and e["license"] != ""
    end
  end

  test "each grammar names its file endings, an ABI the NIF loads, and its upstream commit" do
    for g <- Catalog.grammars() do
      # A companion (ADR-0043 §7) highlights no file of its own.
      if g["for"], do: :ok, else: assert(g["extensions"] != [] or g["filenames"] != [], g["name"])
      assert g["abi"] in 13..15, g["name"]
      assert g["upstream"]["commit"] =~ ~r/\A[0-9a-f]{40}\z/
    end

    endings = Enum.flat_map(Catalog.grammars(), & &1["extensions"])
    assert length(endings) == length(Enum.uniq(endings)), "an ending claimed twice"
  end

  test "a companion grammar names a catalog grammar, and no file endings (ADR-0043 §7)" do
    companions = Enum.filter(Catalog.grammars(), & &1["for"])
    names = Enum.map(Catalog.grammars(), & &1["name"])

    assert Enum.map(companions, &{&1["name"], &1["for"]}) == [{"markdown_inline", "markdown"}]

    for g <- companions do
      assert g["for"] in names and g["for"] != g["name"], g["name"]
      assert g["extensions"] == [] and g["filenames"] == [], g["name"]
      # It is built from its grammar's repository and commit.
      assert g["upstream"] == Catalog.grammar(g["for"])["upstream"]
    end
  end

  test "file names match the right grammar" do
    for {path, lang} <- [
          {"a.ts", "typescript"},
          {"a.tsx", "tsx"},
          {"x.jsx", "javascript"},
          {"rebar.config", "erlang"},
          {"/home/u/.bashrc", "bash"},
          {"index.html.heex", "heex"},
          {"Cargo.toml", "toml"},
          {"ci.yml", "yaml"}
        ] do
      assert Catalog.for_path(path)["name"] == lang, path
    end

    # A dotfile named like an ending isn't that language.
    assert Catalog.for_path(".md") == nil
  end
end
