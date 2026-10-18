defmodule Geex.Fixtures do
  @moduledoc """
  The grammars and the theme the tests use ([ADR-0040](../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §1: geex ships none). `test/fixtures/grammars/{elixir,json}` are tree-sitter builds with their
  queries and manifests, and `test/fixtures/themes/birds-of-paradise.json` the native theme; NOTICE
  says where each came from.

  `test_helper.exs` installs them (`install/1`) into the test data directory before the suite,
  so a test that highlights Elixir or JSON, or asks for Birds of Paradise, finds them as it would
  on a machine where the user installed them.
  """

  @root Path.expand("../fixtures", __DIR__)

  @doc "A fixture grammar's directory: `parser.wasm`, `highlights.scm`, `manifest.json`."
  @spec grammar_dir(String.t()) :: Path.t()
  def grammar_dir(name), do: Path.join([@root, "grammars", name])

  @doc "The Birds of Paradise theme file."
  @spec birds_path() :: Path.t()
  def birds_path, do: Path.join([@root, "themes", "birds-of-paradise.json"])

  @doc "Birds of Paradise, loaded: the truecolor theme the rendering tests check against."
  @spec birds() :: Geex.Theme.t()
  def birds do
    {:ok, theme} = Geex.Theme.load(birds_path())
    theme
  end

  @doc """
  Install the fixture grammars and the theme into `data_dir` as packages a user installed
  locally would be: each directory with its files and an `installed.json`.
  """
  @spec install(Path.t()) :: :ok
  def install(data_dir) do
    for name <- ["elixir", "json"] do
      dir = Path.join([data_dir, "grammars", name])
      File.mkdir_p!(dir)

      for f <- File.ls!(grammar_dir(name)),
          do: File.cp!(Path.join(grammar_dir(name), f), Path.join(dir, f))

      File.write!(Path.join(dir, "installed.json"), ~s({"source":"local","sha256":"fixture"}))
    end

    dir = Path.join([data_dir, "themes", "birds-of-paradise"])
    File.mkdir_p!(dir)
    File.cp!(birds_path(), Path.join(dir, "birds-of-paradise.json"))

    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"kind":"theme","name":"birds-of-paradise","display":"Birds of Paradise","license":"BSD-3-Clause"})
    )

    File.write!(Path.join(dir, "installed.json"), ~s({"source":"local","sha256":"fixture"}))
    :ok
  end
end
