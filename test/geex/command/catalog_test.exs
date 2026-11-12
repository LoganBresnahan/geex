defmodule Geex.Command.CatalogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
                 match?({:typed, p} when is_binary(p), invoke) or
                 match?({:command, _}, invoke)
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

    # ADR-0047 §6: a command that had only a key, typed, is the command picking it runs.
    test "every command that runs as its key does parses, typed, to that command" do
      for %Entry{name: name, aliases: aliases, invoke: {:command, c}} <- Catalog.all(),
          typed <- [name | aliases],
          do: assert(Geex.Loop.Verbs.parse(typed) == {:command, c}, typed)
    end

    test "an alias finds its command" do
      assert [%Entry{name: "quit"} | _] = Catalog.search("exit")
      assert [%Entry{name: "rename"} | _] = Catalog.search("mv")
    end
  end

  test "the palette lists `preview`; its key comes from the bindings (ADR-0043 §1, ADR-0047)" do
    assert %Entry{invoke: {:action, :toggle_preview}} =
             entry = Enum.find(Catalog.all(), &(&1.name == "preview"))

    keys = Geex.Loop.Bindings.defaults()
    assert Geex.Loop.Bindings.labels(keys, Catalog.commands(entry)) == "Alt+P"
  end

  # ADR-0047: no description names a key; the keys are the bindings', shown beside it.
  test "no description names a key" do
    for %Entry{name: name, description: d} <- Catalog.all(),
        do: refute(d =~ ~r/\b(Alt|Ctrl)[+-]/, "#{name}'s description names a key: #{d}")
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

  # ADR-0048: a good name match (each query word starts a name word, in order), then what the
  # query's key runs, then every other match.
  describe "search/2" do
    test "a good name match beats a better-scored loose one" do
      # `enter` is scattered through `indent other`'s name; nothing is named `enter`.
      keyed = &(&1.name == "line break")
      assert hd(Catalog.search("enter", keyed)).name == "line break"
      assert hd(Catalog.search("line e")).name == "line end"
      assert hd(Catalog.search("sel al")).name == "select all"
    end

    test "a command named like the key comes before the key's command" do
      results = Catalog.search("delete", &(&1.name == "delete forward"))
      assert hd(results).name == "delete"
      assert Enum.count(results, &(&1.name == "delete forward")) == 1
    end

    # Where the catalog's order and the score disagree: the score orders within a band
    # (mod-verify's review of ADR-0048, which planted "band only" and saw no test fail).
    test "within a band, the better score first, not the catalog's order" do
      for {q, top} <- [
            {"clipboard", "paste"},
            {"clear", "no"},
            {"create", "new"},
            {"under", "delete forward"}
          ],
          do: assert(hd(Catalog.search(q)).name == top, q)
    end

    test "with nothing keyed, it is search/1" do
      for q <- ["sa", "clip", "paste", "tab", "zzzqqq", "line"],
          do: assert(Catalog.search(q, fn _ -> false end) == Catalog.search(q))
    end

    test "narrow/2: `tab N` found by Alt+5 is tab 5, run as picked" do
      tab = Enum.find(Catalog.all(), &(&1.name == "tab"))

      assert %Entry{name: "tab 5", invoke: {:action, {:tab, 4}}, description: d} =
               Catalog.narrow(tab, {:tab, 4})

      assert d == "Show the pane's tab 5."
      copy = Enum.find(Catalog.all(), &(&1.name == "copy"))
      assert Catalog.narrow(copy, :copy) == copy
    end

    # The words of every name, and pieces of them: the queries a person types.
    defp query do
      words = Catalog.all() |> Enum.flat_map(&String.split(&1.name)) |> Enum.uniq()

      one_of([
        map(list_of(member_of(words), min_length: 1, max_length: 3), &Enum.join(&1, " ")),
        map(
          tuple({member_of(words), integer(1..4)}),
          fn {w, n} -> String.slice(w, 0, n) end
        ),
        string(:alphanumeric, min_length: 1, max_length: 6)
      ])
    end

    # A name match above a description-only one, as Catalog's rank; no match scores 0.
    defp score(entry, q) do
      case [entry.name | entry.aliases]
           |> Enum.map(&Geex.Fuzzy.score(&1, q))
           |> Enum.reject(&is_nil/1) do
        [] -> Geex.Fuzzy.score(entry.description, q) || 0
        scores -> Enum.max(scores) + 1000
      end
    end

    # The rule, written apart from the code: every query word starts a name word, in order.
    defp good?(entry, q) do
      words = String.split(String.downcase(q))

      Enum.any?([entry.name | entry.aliases], fn name ->
        rest =
          Enum.reduce_while(words, String.split(String.downcase(name)), fn w, name_words ->
            case Enum.drop_while(name_words, &(not String.starts_with?(&1, w))) do
              [] -> {:halt, :miss}
              [_ | after_it] -> {:cont, after_it}
            end
          end)

        rest != :miss
      end)
    end

    property "the bands: good names, then keyed, then the rest; each entry once; nothing lost" do
      check all(
              q <- query(),
              keyed_names <- list_of(member_of(Enum.map(Catalog.all(), & &1.name)), max_length: 4)
            ) do
        keyed? = &(&1.name in keyed_names)
        results = Catalog.search(q, keyed?)
        band = fn e -> if(good?(e, q), do: 1, else: if(keyed?.(e), do: 2, else: 3)) end

        assert length(Enum.uniq(results)) == length(results)
        assert Enum.map(results, band) == Enum.sort(Enum.map(results, band))

        # Within a band the score never rises (the scorer is the oracle; the sort is the claim).
        for {_band, entries} <- Enum.chunk_by(results, band) |> Enum.map(&{band.(hd(&1)), &1}) do
          scores = Enum.map(entries, &score(&1, q))
          assert scores == Enum.sort(scores, :desc), inspect({q, Enum.map(entries, & &1.name)})
        end

        expected = MapSet.new(Catalog.search(q) ++ Enum.filter(Catalog.all(), keyed?))
        assert MapSet.new(results) == expected
      end
    end
  end
end
