defmodule Geex.Command.CatalogTest do
  use ExUnit.Case, async: true

  alias Geex.Command.Catalog
  alias Geex.Command.Catalog.Entry

  doctest Geex.Command.Catalog

  defp names(entries), do: Enum.map(entries, & &1.name)

  describe "all/0" do
    test "lists the v1 human command vocabulary" do
      names = names(Catalog.all())

      for v <- ~w(copy cut paste undo redo highlight save quit line) do
        assert v in names, "expected #{v} in the catalog"
      end

      assert "select all" in names
    end

    test "every entry carries a dispatchable invoke" do
      for %Entry{invoke: invoke} <- Catalog.all() do
        assert match?({:action, a} when is_atom(a), invoke) or
                 match?({:action, {:theme, name}} when is_binary(name), invoke) or
                 match?({:typed, p} when is_binary(p), invoke)
      end
    end
  end

  # Roadmap item 18.6: the settings view's Commands tab lists this catalog, so every word the
  # minibuffer's parser takes must be in it, as a name or an alias. The words are read from the
  # parser's own source (its `do_parse` and `path_verb` heads and `when verb in` lists), so a new
  # verb there without an entry fails here; `parse/1`'s own prefixes (`!!`, `!`, `|`) are listed
  # by hand. Command mode only: grid mode's verbs (`goto`, `copy`, `cut`) aren't commands.
  describe "covers the typed verbs (18.6)" do
    defp parser_words do
      src = File.read!(Path.join(File.cwd!(), "lib/geex/loop/verbs.ex"))

      singles =
        Regex.scan(~r/defp (?:do_parse|path_verb)\("([^"]+)"/, src, capture: :all_but_first)

      lists = Regex.scan(~r/when verb in \[([^\]]+)\]/, src, capture: :all_but_first)

      listed =
        for [list] <- lists,
            [w] <- Regex.scan(~r/"([^"]+)"/, list, capture: :all_but_first),
            do: w

      (List.flatten(singles) ++ listed ++ ["!!", "!", "|"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end

    test "every word the parser takes is a command's name or alias" do
      known = Enum.flat_map(Catalog.all(), &[&1.name | &1.aliases])
      words = parser_words()
      assert length(words) > 30

      for w <- words, do: assert(w in known, "#{inspect(w)} is typed but not in the catalog")
    end

    test "every command that runs as picked parses as typed" do
      for %Entry{name: name, invoke: {:action, _}} <- Catalog.all(),
          do: refute(Geex.Loop.Verbs.parse(name) == :unknown, "#{name} doesn't parse")
    end

    test "an alias finds its command" do
      assert [%Entry{name: "quit"} | _] = Catalog.search("exit")
      assert [%Entry{name: "rename"} | _] = Catalog.search("mv")
    end
  end

  test "the palette lists `preview`, naming its key (ADR-0043 §1)" do
    assert %Entry{invoke: {:action, :toggle_preview}, description: d} =
             Enum.find(Catalog.all(), &(&1.name == "preview"))

    assert d =~ "Alt+Shift+P"
  end

  describe "search/1" do
    test "a blank query returns the whole catalog in canonical order" do
      assert Catalog.search("") == Catalog.all()
      assert Catalog.search("   ") == Catalog.all()
    end

    test "an exact name floats to the top" do
      assert [%Entry{name: "copy"} | _] = Catalog.search("copy")
      assert [%Entry{name: "undo"} | _] = Catalog.search("undo")
    end

    test "a fuzzy subsequence still matches (even when a prefix outranks it)" do
      results = Catalog.search("sa")
      # "save" is a prefix of the query, so it leads; "select all" is matched as an acronym
      assert hd(results).name == "save"
      assert "select all" in names(results)
    end

    test "a description-only hit is found, but ranks below any name match" do
      # "clipboard" is in copy/cut/paste descriptions, not any name
      results = Catalog.search("clip")
      assert "copy" in names(results)
      refute results == []
    end

    test "a name match outranks a description-only match for the same query" do
      # "paste" matches its own name; it must rank above copy/cut (which only mention
      # "clipboard"/"selection") — i.e. the name-banding holds
      results = Catalog.search("paste")
      assert hd(results).name == "paste"
    end

    test "no match returns an empty list" do
      assert Catalog.search("zzzqqq") == []
    end
  end
end
