defmodule Geex.Loop.BindingsTest do
  # The key bindings (ADR-0047): which command each bound key runs, as data. Pure.
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Geex.Loop.Bindings

  alias Geex.Command.Catalog
  alias Geex.Loop.{Bindings, Keymap, Verbs}

  @defaults Bindings.defaults()

  # The focused view's own keys, never bound (ADR-0047 §1).
  @own_keys [
    {:key, :enter},
    {:key, :esc},
    {:key, :tab},
    {:key, :shift_tab},
    {:key, :backspace},
    {:key, :delete}
  ]

  # The commands the loop's front takes before the keymap (`Geex.Loop`'s `dispatch_key/2`, and
  # the preview for the page keys): the keymap resolves them to nothing.
  @front [:settings, :stop_shell, :page_up, :page_down] ++
           for(d <- [:up, :down, :left, :right], do: {:resize, d})

  # Any key event the parser hands over, bound or not.
  defp event do
    one_of([
      tuple({constant(:alt), one_of([integer(?a..?z), integer(?A..?Z), integer(?0..?9)])}),
      tuple({constant(:alt), member_of([:up, :down, :left, :right, ?-, ?=, ?,, ?., ?;, ?`])}),
      tuple({constant(:ctrl), integer(?a..?z)}),
      tuple(
        {constant(:key),
         member_of([:up, :down, :left, :right, :home, :end, :page_up, :page_down])}
      ),
      member_of(@own_keys),
      map(string(:alphanumeric, length: 1), &{:char, &1}),
      map(string(:printable, max_length: 8), &{:paste, &1})
    ])
  end

  # Bindings as a user might make them: some of the default keys, some moved to other chords.
  defp bindings do
    commands = Enum.uniq(Map.values(@defaults))

    gen all(
          base <- list_of(member_of(Map.keys(@defaults)), max_length: 40),
          extra <- list_of(tuple({event(), member_of(commands)}), max_length: 12)
        ) do
      moved =
        for {chord, _} = binding <- extra,
            match?({k, _} when k in [:alt, :ctrl, :key], chord),
            chord not in @own_keys,
            into: %{},
            do: binding

      Map.merge(Map.take(@defaults, base), moved)
    end
  end

  describe "translate/2" do
    property "translating twice is translating once" do
      check all(b <- bindings(), e <- event()) do
        once = Bindings.translate(e, b)
        assert Bindings.translate(once, b) == once
      end
    end

    property "a bound key runs its command; the view's own keys, characters and pastes pass" do
      check all(b <- bindings(), e <- event()) do
        case Map.fetch(b, e) do
          {:ok, command} -> assert Bindings.translate(e, b) == {:cmd, command}
          :error when e in @own_keys -> assert Bindings.translate(e, b) == e
          :error when elem(e, 0) in [:char, :paste] -> assert Bindings.translate(e, b) == e
          :error -> :ok
        end
      end
    end

    property "Caps Lock: Alt+Shift+letter not bound itself runs Alt+letter's command" do
      check all(b <- bindings(), c <- integer(?a..?z), kind <- member_of([:alt, :ctrl])) do
        upper = {kind, c - 32}

        unless Map.has_key?(b, upper) do
          case Map.fetch(b, {kind, c}) do
            {:ok, command} -> assert Bindings.translate(upper, b) == {:cmd, command}
            :error -> assert Bindings.translate(upper, b) == upper
          end
        end

        # Never the other way: an unbound lower case doesn't borrow the Shift chord's command.
        unless Map.has_key?(b, {kind, c}),
          do: assert(Bindings.translate({kind, c}, b) == {kind, c})
      end
    end

    test "Alt+Shift+Z and Alt+Shift+P are the Shift chords bound themselves" do
      assert Bindings.translate({:alt, ?Z}, @defaults) == {:cmd, :redo}
      assert Bindings.translate({:alt, ?z}, @defaults) == {:cmd, :undo}
      assert Bindings.translate({:alt, ?P}, @defaults) == {:cmd, :toggle_preview}
      assert Bindings.translate({:alt, ?p}, @defaults) == {:cmd, :next_pane}

      shifted = for {{:alt, c}, _} <- @defaults, c in ?A..?Z, do: c
      assert Enum.sort(shifted) == [?P, ?Z]
    end

    # The property's "never the other way" needs a lower case dropped and its Shift chord kept,
    # rare in a random subset of the defaults: pinned here.
    test "an unbound lower case doesn't borrow its Shift chord's command" do
      for c <- [?z, ?p] do
        b = Map.delete(@defaults, {:alt, c})
        assert Bindings.translate({:alt, c}, b) == {:alt, c}
      end
    end

    test "an unbound chord arrives as it came" do
      assert Bindings.translate({:alt, ?9}, Map.delete(@defaults, {:alt, ?9})) == {:alt, ?9}
      assert Bindings.translate({:ctrl, ?b}, @defaults) == {:ctrl, ?b}
    end
  end

  describe "the defaults" do
    test "no view's own key is bound, and only bound keys are" do
      for chord <- Map.keys(@defaults) do
        refute chord in @own_keys
        assert match?({k, _} when k in [:alt, :ctrl, :key], chord)
      end
    end

    test "the default keys: IJKL and the right hand moves, the left hand's commands (ADR-0049)" do
      expected = %{
        {:alt, ?i} => :up,
        {:alt, ?j} => :left,
        {:alt, ?k} => :down,
        {:alt, ?l} => :right,
        {:alt, ?u} => :word_back,
        {:alt, ?o} => :word_forward,
        {:alt, ?h} => :line_start,
        {:alt, ?;} => :line_end,
        {:key, :home} => :line_start,
        {:key, :end} => :line_end,
        {:alt, ?m} => :minibuffer,
        {:alt, ?g} => :grid,
        {:alt, ?b} => :palette,
        {:alt, ?y} => :settings,
        {:alt, ?r} => :revert_hunk,
        {:alt, ?f} => :find_file,
        {:alt, ?w} => :close,
        {:alt, ?t} => :toggle_tree,
        {:alt, ?e} => :toggle_edits,
        {:alt, ?d} => :fast_forward,
        {:alt, ?s} => :select_start,
        {:alt, ?a} => :select_all,
        {:alt, ?c} => :copy,
        {:alt, ?x} => :cut,
        {:alt, ?v} => :paste,
        {:alt, ?`} => :indent_other,
        {:alt, ?-} => :split_rows,
        {:alt, ?=} => :split_cols,
        {:alt, ?,} => :tab_prev,
        {:alt, ?.} => :tab_next,
        {:alt, ?1} => {:tab, 0},
        {:alt, ?9} => {:tab, 8},
        {:alt, :left} => {:resize, :left},
        {:ctrl, ?o} => :save,
        {:ctrl, ?g} => :stop_shell,
        {:ctrl, ?x} => :quit,
        {:ctrl, ?q} => :quit,
        {:ctrl, ?c} => :quit
      }

      for {chord, command} <- expected,
          do: assert(Bindings.translate(chord, @defaults) == {:cmd, command}, inspect(chord))

      # Alt+Q and Alt+N are kept for find (ADR-0049 §2a), unbound until find is built; Esc
      # clears a selection.
      for c <- [?q, ?Q, ?n, ?N], do: assert(Bindings.translate({:alt, c}, @defaults) == {:alt, c})
    end

    test "the defaults bind no key twice" do
      assert Bindings.bound_twice(Bindings.default_list()) == []
      assert Bindings.bound_twice([{:up, [{:alt, ?i}]}, {:copy, [{:alt, ?i}]}]) == [{:alt, ?i}]
    end

    test "each key is written as a person reads it" do
      written = %{
        {:key, :enter} => "Enter",
        {:key, :esc} => "Esc",
        {:key, :tab} => "Tab",
        {:key, :shift_tab} => "Shift+Tab",
        {:key, :backspace} => "Backspace",
        {:key, :delete} => "Delete",
        {:key, :home} => "Home",
        {:key, :end} => "End",
        {:key, :page_up} => "PgUp",
        {:key, :page_down} => "PgDn",
        {:key, :up} => "↑",
        {:key, :down} => "↓",
        {:key, :left} => "←",
        {:key, :right} => "→",
        {:alt, :right} => "Alt+→",
        {:alt, ?u} => "Alt+U",
        {:alt, ?P} => "Alt+Shift+P",
        {:alt, ?-} => "Alt+-",
        {:alt, ?9} => "Alt+9",
        {:ctrl, ?x} => "Ctrl-X"
      }

      for {chord, label} <- written, do: assert(Bindings.label(chord) == label)

      for {command, key} <- [newline: "Enter", delete_back: "Backspace", delete_forward: "Delete"],
          do: assert(Bindings.labels(@defaults, [command]) == key)
    end

    test "every key has its own label" do
      labels = Enum.map(Map.keys(@defaults), &Bindings.label/1)
      assert length(Enum.uniq(labels)) == length(labels)
    end
  end

  # ADR-0047 §2: every command a key runs has a name, typed in Alt+M, that runs it.
  describe "every bound command has a name" do
    test "in the catalog" do
      named = Enum.flat_map(Catalog.all(), &Catalog.commands/1)

      for command <- Enum.uniq(Map.values(@defaults)) ++ Bindings.own_commands(),
          do: assert(command in named, "#{inspect(command)} has no catalog entry")
    end

    test "typed, it parses to the command its key runs" do
      for %{name: name} = entry <- Catalog.all(),
          command <- Catalog.commands(entry),
          not match?({:tab, _}, command) do
        assert Verbs.parse(name) in [{:command, command}, {:action, command}], name
      end

      assert Verbs.parse("tab 3") == {:action, {:tab, 2}}
    end

    test "the keymap runs every one, but those the loop takes first" do
      # The editor's own commands are turned into their keys by the loop (`line break` is Enter),
      # so the keymap never resolves one itself.
      for command <- Bindings.own_commands(),
          do: assert(Keymap.resolve({:cmd, command}, {0, 1}, "ab") == :ignore)

      for command <- Enum.uniq(Map.values(@defaults)) do
        resolved = Keymap.resolve({:cmd, command}, {0, 1}, "ab")

        if command in @front,
          do: assert(resolved == :ignore, inspect(command)),
          else: refute(resolved == :ignore, inspect(command))
      end
    end
  end

  test "labels/3 follows the bindings it is given" do
    moved = @defaults |> Map.delete({:alt, ?i}) |> Map.put({:alt, ?b}, :up)
    assert Bindings.labels(moved, [:up]) == "Alt+B ↑"
    assert Bindings.labels(moved, [:palette]) == ""
    assert Bindings.labels(@defaults, [:newline, :select_clear]) == "Enter  Esc"
  end
end
