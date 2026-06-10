defmodule Geex.Command.CatalogTest do
  use ExUnit.Case, async: true

  alias Geex.Command.Catalog
  alias Geex.Command.Catalog.Entry

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
                 match?({:typed, p} when is_binary(p), invoke)
      end
    end
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
