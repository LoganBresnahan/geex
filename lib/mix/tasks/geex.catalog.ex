defmodule Mix.Tasks.Geex.Catalog do
  @shortdoc "Build the grammar and theme packages and write catalog/catalog.json (ADR-0040)"
  @moduledoc """
  Build the catalog's packages from the recipes in `catalog/` and write `catalog/catalog.json`,
  which geex embeds at compile time ([ADR-0040](../../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §2, §4).

      mix geex.catalog                       build every package
      mix geex.catalog --only rust --only go just these; the rest of catalog.json is kept
      mix geex.catalog --base URL            the URL the assets will be under

  For each grammar in `catalog/grammars.exs`:

  1. **Fetch** its repository at the recipe's tag into `_build/catalog/src/`, and stop if the
     tag no longer names the pinned commit.
  2. **Build** `parser.wasm` with `tree-sitter build --wasm`. The CLI must be the version the
     `tree_sitter_wasm` NIF pins (#{"0.26.9"}), so its ABI matches; `TREE_SITTER` names it, else
     `PATH`, else `~/.cargo/bin`.
  3. **Merge** the recipe's highlights, an inherited grammar's included, into one
     `highlights.scm`, each part headed by where it came from.
  4. **Check** it loads: `TreeSitterWasm.load_grammar/3` must accept the wasm and the query.
  5. **Pack** `parser.wasm`, `highlights.scm`, `manifest.json` and the upstream licence files
     into a deterministic zip (`Geex.Catalog.Package`), named by its hash, in
     `_build/catalog/dist/`.

  Each theme in `catalog/themes.exs` is checked with `Geex.Theme.load/1` and packed with its
  licence. Then `catalog/catalog.json` lists every package: name, file endings, ABI, licence,
  upstream, size, sha256 and URL. Upload `_build/catalog/dist/*` to the release the URLs name;
  an asset already uploaded keeps its name, since an unchanged package zips to the same bytes.

  The URLs name the release in mix.exs's `catalog_release` (`--base` overrides it), and a full
  build first empties `_build/catalog/dist/`, so it holds that release's whole set of assets and
  nothing else. A changed catalog goes on a new release, with `catalog_release` bumped; the
  binaries built before keep the release they name.
  """
  use Mix.Task

  alias Geex.Catalog.Package

  @cli_version "0.26.9"
  # The release the assets go on: mix.exs's `catalog_release` (`v0.2.0`). It holds the whole
  # catalog, and is bumped only when the catalog changes (ADR-0040 §2).
  @releases "https://github.com/LoganBresnahan/geex/releases/download/"
  @catalog "catalog/catalog.json"
  @src "_build/catalog/src"
  @dist "_build/catalog/dist"

  defp default_base, do: @releases <> Mix.Project.config()[:catalog_release] <> "/"

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [only: :keep, base: :string])
    Mix.Task.run("compile")

    base = Keyword.get(opts, :base, default_base())
    only = Keyword.get_values(opts, :only)

    # A full build leaves in dist exactly the release's assets.
    if only == [], do: File.rm_rf!(@dist)
    {grammars, _} = Code.eval_file("catalog/grammars.exs")
    {themes, _} = Code.eval_file("catalog/themes.exs")
    check_names!(grammars ++ themes, only)

    cli = tree_sitter!()
    File.mkdir_p!(@src)
    File.mkdir_p!(@dist)

    built_grammars =
      for recipe <- grammars, picked?(recipe, only), do: grammar(recipe, grammars, cli, base)

    built_themes = for recipe <- themes, picked?(recipe, only), do: theme(recipe, base)

    previous = if only == [], do: %{"grammars" => [], "themes" => []}, else: read_catalog()

    catalog = %{
      "v" => 1,
      "tree_sitter_cli" => @cli_version,
      "base" => base,
      "grammars" => merge(previous["grammars"], built_grammars),
      "themes" => merge(previous["themes"], built_themes)
    }

    File.write!(@catalog, encode(catalog))

    Mix.shell().info(
      "geex catalog: #{length(built_grammars)} grammars, #{length(built_themes)} themes " <>
        "in #{@dist}; #{@catalog} written"
    )
  end

  ## Grammars

  defp grammar(recipe, recipes, cli, base) do
    Mix.shell().info("geex catalog: #{recipe.name} (#{recipe.tag})")
    dir = fetch!(recipe)
    gdir = Path.join(dir, recipe.path)
    out = Path.join(System.tmp_dir!(), "geex-catalog-#{recipe.name}.wasm")

    case System.cmd(cli, ["build", "--wasm", "-o", out, gdir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {log, status} -> Mix.raise("geex catalog: #{recipe.name} didn't build (#{status}):\n#{log}")
    end

    wasm = File.read!(out)
    File.rm(out)
    highlights = highlights(recipe, recipes)

    case TreeSitterWasm.load_grammar(wasm, recipe.name, highlights) do
      {:ok, _grammar} -> :ok
      {:error, reason} -> Mix.raise("geex catalog: #{recipe.name} doesn't load: #{reason}")
    end

    abi =
      case Package.abi(File.read!(Path.join([gdir, "src", "parser.c"]))) do
        {:ok, abi} -> abi
        :error -> Mix.raise("geex catalog: #{recipe.name}: no LANGUAGE_VERSION in parser.c")
      end

    manifest = %{
      "kind" => "grammar",
      "name" => recipe.name,
      "display" => recipe.display,
      "extensions" => recipe.extensions,
      "filenames" => recipe.filenames,
      "abi" => abi,
      "license" => recipe.license,
      "upstream" => %{"repo" => recipe.repo, "tag" => recipe.tag, "commit" => recipe.commit},
      "tree_sitter_cli" => @cli_version
    }

    licenses = for f <- recipe.license_files, do: {f, File.read!(Path.join(dir, f))}

    files =
      [
        {"parser.wasm", wasm},
        {"highlights.scm", highlights},
        {"manifest.json", JSON.encode!(manifest)}
      ] ++ licenses

    entry(:grammar, manifest, Package.zip(files), base)
  end

  # The recipe's query files, in order, each headed by where it came from. A file from another
  # grammar (an inherited query) is read from that grammar's recipe.
  defp highlights(recipe, recipes) do
    Enum.map_join(recipe.highlights, "\n", fn {from, path} ->
      source = Enum.find(recipes, &(&1.name == from)) || Mix.raise("no recipe #{from}")
      text = File.read!(Path.join(fetch!(source), path))

      ";; #{source.repo} @ #{source.tag} (#{binary_part(source.commit, 0, 12)}), #{path}\n" <>
        text
    end)
  end

  # The recipe's repository at its tag, checked against the pinned commit. Shared by recipes
  # with the same repository and commit (TypeScript and TSX).
  defp fetch!(recipe) do
    dir = Path.join(@src, "#{Path.basename(recipe.repo)}-#{binary_part(recipe.commit, 0, 12)}")

    unless File.dir?(Path.join(dir, ".git")) do
      File.rm_rf!(dir)

      {log, status} =
        System.cmd(
          "git",
          ["clone", "--quiet", "--depth", "1", "--branch", recipe.tag, recipe.repo, dir],
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("geex catalog: cloning #{recipe.repo} failed:\n#{log}")
    end

    {head, 0} = System.cmd("git", ["-C", dir, "rev-parse", "HEAD"])

    if String.trim(head) != recipe.commit do
      File.rm_rf!(dir)

      Mix.raise(
        "geex catalog: #{recipe.repo} #{recipe.tag} is #{String.trim(head)}, " <>
          "not the pinned #{recipe.commit}"
      )
    end

    dir
  end

  ## Themes

  defp theme(recipe, base) do
    Mix.shell().info("geex catalog: theme #{recipe.name}")
    {manifest, zip} = theme_zip(recipe)
    entry(:theme, manifest, zip, base)
  end

  @doc """
  A theme recipe's package, `{manifest, zip}`: its JSON (checked with `Geex.Theme.load/1`), its
  manifest and its licence, zipped deterministically. The same bytes every time, so a test can
  rebuild what the catalog pins.
  """
  @spec theme_zip(map()) :: {map(), binary()}
  def theme_zip(recipe) do
    path = Path.join("catalog", recipe.file)

    theme =
      case Geex.Theme.load(path) do
        {:ok, theme} -> theme
        {:error, reason} -> Mix.raise("geex catalog: #{path}: #{inspect(reason)}")
      end

    manifest = %{
      "kind" => "theme",
      "name" => recipe.name,
      "display" => recipe.display,
      "appearance" => Atom.to_string(theme.appearance),
      "license" => recipe.license
    }

    files = [
      {recipe.name <> ".json", File.read!(path)},
      {"manifest.json", JSON.encode!(manifest)},
      {"LICENSE", File.read!(Path.join("catalog", recipe.license_file))}
    ]

    {manifest, Package.zip(files)}
  end

  ## The catalog

  # Write the package to dist under its hashed name, and describe it for catalog.json.
  defp entry(kind, manifest, zip, base) do
    sha = Package.sha256(zip)
    asset = Package.asset_name(kind, manifest["name"], sha)
    File.write!(Path.join(@dist, asset), zip)

    manifest
    |> Map.drop(["kind", "tree_sitter_cli"])
    |> Map.merge(%{
      "asset" => asset,
      "url" => base <> asset,
      "size" => byte_size(zip),
      "sha256" => sha
    })
  end

  defp merge(previous, built) do
    names = MapSet.new(built, & &1["name"])

    (Enum.reject(previous, &(&1["name"] in names)) ++ built)
    |> Enum.sort_by(& &1["name"])
  end

  defp read_catalog do
    case File.read(@catalog) do
      {:ok, json} -> JSON.decode!(json)
      {:error, _} -> %{"grammars" => [], "themes" => []}
    end
  end

  # One package to a line, so a change reads as a one-line diff.
  defp encode(catalog) do
    list = fn key ->
      rows = Enum.map_join(catalog[key], ",\n", &("    " <> JSON.encode!(&1)))
      ~s|  "#{key}": [\n#{rows}\n  ]|
    end

    """
    {
      "v": #{catalog["v"]},
      "tree_sitter_cli": #{JSON.encode!(catalog["tree_sitter_cli"])},
      "base": #{JSON.encode!(catalog["base"])},
    #{list.("grammars")},
    #{list.("themes")}
    }
    """
  end

  ## Checks

  defp picked?(recipe, only), do: only == [] or recipe.name in only

  defp check_names!(recipes, only) do
    names = Enum.map(recipes, & &1.name)
    if length(Enum.uniq(names)) != length(names), do: Mix.raise("geex catalog: a name repeats")

    case only -- names do
      [] -> :ok
      unknown -> Mix.raise("geex catalog: no recipe #{Enum.join(unknown, ", ")}")
    end
  end

  defp tree_sitter! do
    cli =
      System.get_env("TREE_SITTER") || System.find_executable("tree-sitter") ||
        Path.expand("~/.cargo/bin/tree-sitter")

    case System.cmd(cli, ["--version"], stderr_to_stdout: true) do
      {"tree-sitter " <> version, 0} ->
        if String.starts_with?(version, @cli_version <> " ") or
             String.trim(version) == @cli_version,
           do: cli,
           else: Mix.raise("geex catalog: #{cli} is #{String.trim(version)}, not #{@cli_version}")

      {out, _} ->
        Mix.raise("geex catalog: no tree-sitter CLI at #{cli}: #{out}")
    end
  rescue
    e in ErlangError -> Mix.raise("geex catalog: no tree-sitter CLI: #{inspect(e)}")
  end
end
