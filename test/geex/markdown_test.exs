defmodule Geex.MarkdownTest do
  # The markdown preview's grammars (ADR-0043 §4, §7): the fixture packages, the render handles
  # and the checks around them. Rewrites the installed markdown packages in the test data
  # directory, so not async; each test puts the fixtures back.
  use ExUnit.Case, async: false

  alias Geex.{Fixtures, Installed, Markdown}
  alias Geex.Highlight.Grammars
  alias Geex.Markdown.Parse

  doctest Markdown

  setup do
    on_exit(fn ->
      for name <- Markdown.grammars() do
        dir = Installed.dir(:grammar, name)
        File.rm_rf!(dir)
        File.rm_rf!(dir <> ".aside")
        File.mkdir_p!(dir)

        for f <- File.ls!(Fixtures.grammar_dir(name)),
            do: File.cp!(Path.join(Fixtures.grammar_dir(name), f), Path.join(dir, f))

        File.write!(Path.join(dir, "installed.json"), ~s({"source":"local","sha256":"fixture"}))
        Grammars.forget(name)
      end

      Installed.refresh()
    end)
  end

  defp manifest(name, changes) do
    path = Path.join(Installed.dir(:grammar, name), "manifest.json")
    File.write!(path, JSON.encode!(Map.merge(JSON.decode!(File.read!(path)), changes)))
    Installed.refresh()
  end

  test "the fixtures are the catalog's packages, at the recipe's commit" do
    {recipes, _} = Code.eval_file("catalog/grammars.exs")

    for name <- Markdown.grammars() do
      recipe = Enum.find(recipes, &(&1.name == name))
      fixture = JSON.decode!(File.read!(Path.join(Fixtures.grammar_dir(name), "manifest.json")))

      # A recipe bump that leaves the fixtures behind fails here: the render queries would be
      # tested against grammars users no longer get.
      assert fixture["upstream"] == %{
               "repo" => recipe.repo,
               "tag" => recipe.tag,
               "commit" => recipe.commit
             },
             name

      assert fixture["for"] == recipe[:for]
      assert fixture["abi"] == Geex.Catalog.grammar(name)["abi"]
    end
  end

  test "the render handles parse a document" do
    assert {:ok, grammars} = Markdown.handles()
    text = "# Title ##\n\nSome *em* and `code`.\n"
    assert {:ok, tree, stats} = Parse.parse(text, grammars)
    assert stats.inline_calls == 2

    types = flatten(tree) |> Enum.map(& &1.type)
    assert [:document, :atx_heading, :h1, :inline, :paragraph, :inline | inline] = types
    assert :emphasis in inline and :code_span in inline
  end

  defp flatten(node), do: [node | Enum.flat_map(node.children, &flatten/1)]

  test "a render handle is cached by the install's sha256 and the query, apart from highlighting's" do
    query = Parse.query("markdown")
    assert {:ok, h} = Grammars.render_handle("markdown", query)
    assert {:ok, ^h} = Grammars.render_handle("markdown", query)
    assert {{"fixture", _}, ^h} = :persistent_term.get({Grammars, :render, "markdown"})

    # The package is replaced: its build differs, so the cached handle is never used again.
    File.write!(
      Path.join(Installed.dir(:grammar, "markdown"), "installed.json"),
      ~s({"source":"local","sha256":"another"})
    )

    Installed.refresh()
    assert {:ok, _} = Grammars.render_handle("markdown", query)
    assert {{"another", _}, _} = :persistent_term.get({Grammars, :render, "markdown"})

    # Another query is another handle.
    assert {:ok, _} = Grammars.render_handle("markdown", "(paragraph) @paragraph")
    {{"another", tag}, _} = :persistent_term.get({Grammars, :render, "markdown"})
    assert tag == :erlang.phash2("(paragraph) @paragraph")
  end

  test "forget/1 drops the render handle with the highlight handle" do
    assert {:ok, _} = Markdown.handles()
    assert {:ok, _} = Grammars.handle("markdown")

    Grammars.forget("markdown_inline")
    assert :persistent_term.get({Grammars, :render, "markdown_inline"}, :miss) == :miss
    assert {_, _} = :persistent_term.get({Grammars, :render, "markdown"}, :miss)

    Grammars.forget("markdown")
    assert :persistent_term.get({Grammars, :render, "markdown"}, :miss) == :miss
    assert :persistent_term.get({Grammars, "markdown"}, :miss) == :miss
  end

  test "a package of an ABI geex doesn't load is never handed to the engine: needs an update" do
    manifest("markdown_inline", %{"abi" => 12})

    assert Grammars.render_handle("markdown_inline", Parse.query("markdown_inline")) ==
             {:error, {:abi, 12}}

    assert Markdown.handles() == {:error, :update}
    assert Markdown.describe(:update) == "Markdown preview needs an update (Alt+Y)"
  end

  test "a render query that doesn't compile says the preview needs an update, not the engine's words" do
    broken = fn
      "markdown" -> "(no_such_node) @x"
      name -> Parse.query(name)
    end

    assert {:error, {:engine, message}} = Grammars.render_handle("markdown", broken.("markdown"))
    assert message =~ "Query"
    assert :persistent_term.get({Grammars, :render, "markdown"}, :miss) == :miss

    assert Markdown.handles(query: broken) == {:error, :update}
    refute Markdown.describe(:update) =~ "Query"
  end

  test "a missing package is named, so the user knows what to install" do
    dir = Installed.dir(:grammar, "markdown_inline")
    File.rename!(dir, dir <> ".aside")
    Installed.refresh()

    assert Markdown.handles() == {:error, {:missing, ["markdown_inline"]}}

    assert Markdown.describe({:missing, ["markdown_inline"]}) ==
             "Markdown preview needs Markdown inline installed (Alt+Y)"
  end

  test "only a file whose installed grammar is Markdown is a markdown file" do
    assert Markdown.file?("README.md")
    assert Markdown.file?("/x/notes.markdown")
    refute Markdown.file?("lib/geex.ex")
    refute Markdown.file?("README")
    refute Markdown.file?(nil)
  end

  test "installing the companion says the preview is available, not that it highlights" do
    {:noreply, state} =
      Geex.Loop.handle_info(
        {:geex_installed, :grammar, "markdown_inline"},
        Geex.Loop.new_state(120, 30)
      )

    assert state.notice == "Markdown inline installed: the Markdown preview is available"
  end

  describe "mix geex.catalog's load check" do
    test "compiles the render query against the grammar it built" do
      for name <- Markdown.grammars() do
        wasm = File.read!(Path.join(Fixtures.grammar_dir(name), "parser.wasm"))
        assert Mix.Tasks.Geex.Catalog.check_render_query!(name, wasm) == :ok
      end

      # A grammar with no render query has nothing to check.
      json = File.read!(Path.join(Fixtures.grammar_dir("json"), "parser.wasm"))
      assert Mix.Tasks.Geex.Catalog.check_render_query!("json", json) == :ok
    end

    test "stops the build when the query names a node the grammar doesn't have" do
      wasm = File.read!(Path.join(Fixtures.grammar_dir("markdown"), "parser.wasm"))

      assert_raise Mix.Error, ~r/markdown doesn't load geex's render query/, fn ->
        Mix.Tasks.Geex.Catalog.check_render_query!("markdown", wasm, "(no_such_node) @x")
      end
    end
  end
end
