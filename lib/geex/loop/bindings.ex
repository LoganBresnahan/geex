defmodule Geex.Loop.Bindings do
  @moduledoc """
  The **key bindings** ([ADR-0047](../../../doc/adr/0047-every-key-runs-a-named-command.md)): which
  command each bound key runs, as data. Pure.

  A *bound key* is a chord (`Alt+…`, `Ctrl+…`, Alt with an arrow) or a navigation key (an arrow,
  Home, End, Page Up, Page Down). The loop turns one into `{:cmd, command}` as it arrives
  (`translate/2`), so everything after it reads commands, never chords. The focused view's own
  keys (printable characters, a paste, Enter, Esc, Tab, Shift+Tab, Backspace, Delete, the mouse)
  are never bound: they pass through as they came.

  A command is a term of the loop's action vocabulary: `:undo`, `:toggle_tree`, `{:tab, 2}`,
  `{:resize, :left}`. Each has a name in `Geex.Command.Catalog`, typed in `Alt+M`.

  The bindings are a map, `chord => command`; the loop holds them, starting from `defaults/0`.
  """

  @type dir :: :up | :down | :left | :right
  @type chord ::
          {:alt, char() | dir()}
          | {:ctrl, char()}
          | {:key, dir() | :home | :end | :page_up | :page_down}
  @type command :: atom() | {:tab, non_neg_integer()} | {:resize, dir()}
  @type t :: %{chord() => command()}

  # The defaults, each command with its keys in the order the help shows them. An Alt+letter
  # covers Alt+Shift+letter too (`translate/2`, Caps Lock); the Shift chords listed are the ones
  # that mean something else: the motion cluster's are the moves (ADR-0052). Alt+3, Alt+4, Alt+6
  # and Alt+0 are left for the user (ADR-0051), Alt+5 for multiple cursors.
  @defaults [
    # Motion (ADR-0026, ADR-0049): the arrows and the right hand's IJKL cluster.
    {:up, [{:alt, ?i}, {:key, :up}]},
    {:left, [{:alt, ?j}, {:key, :left}]},
    {:down, [{:alt, ?k}, {:key, :down}]},
    {:right, [{:alt, ?l}, {:key, :right}]},
    {:word_back, [{:alt, ?u}]},
    {:word_forward, [{:alt, ?o}]},
    {:line_start, [{:alt, ?h}, {:key, :home}]},
    {:line_end, [{:alt, ?;}, {:key, :end}]},
    {:page_up, [{:key, :page_up}]},
    {:page_down, [{:key, :page_down}]},
    # Selection (ADR-0029) and the clipboard (ADR-0015).
    {:select_start, [{:alt, ?s}]},
    {:select_all, [{:alt, ?a}]},
    {:copy, [{:alt, ?c}]},
    {:cut, [{:alt, ?x}]},
    {:paste, [{:alt, ?v}]},
    # The other kind of indent, beside the key above Tab (ADR-0050, ADR-0051).
    {:indent_other, [{:alt, ?1}]},
    # The editing keys (ADR-0052): duplicate; a character, a word, a line; the matching bracket;
    # comment; and, Shift on the motion cluster, moving lines and selected text.
    {:duplicate, [{:alt, ?2}]},
    {:select_char, [{:alt, ?7}]},
    {:select_word, [{:alt, ?8}]},
    {:select_line, [{:alt, ?9}]},
    {:matching_bracket, [{:alt, ?\\}]},
    {:comment, [{:alt, ?/}]},
    {:move_up, [{:alt, ?I}]},
    {:move_down, [{:alt, ?K}]},
    {:move_left, [{:alt, ?J}]},
    {:move_right, [{:alt, ?L}]},
    {:move_word_back, [{:alt, ?U}]},
    {:move_word_forward, [{:alt, ?O}]},
    {:move_line_start, [{:alt, ?H}]},
    {:move_line_end, [{:alt, ?:}]},
    # History (ADR-0031, ADR-0033 §7) and the file (ADR-0019, ADR-0034).
    {:undo, [{:alt, ?z}]},
    {:redo, [{:alt, ?Z}]},
    {:revert_hunk, [{:alt, ?r}]},
    {:revert_call, [{:alt, ?R}]},
    {:save, [{:ctrl, ?o}]},
    {:fast_forward, [{:alt, ?d}]},
    # Files and panes (ADR-0037, ADR-0038, ADR-0043, ADR-0051).
    {:find_file, [{:alt, ?f}]},
    {:close, [{:alt, ?w}]},
    {:toggle_tree, [{:alt, ?t}]},
    {:toggle_edits, [{:alt, ?e}]},
    {:prev_pane, [{:alt, ?<}]},
    {:next_pane, [{:alt, ?>}]},
    {:toggle_preview, [{:alt, ?p}]},
    {:split_rows, [{:alt, ?-}]},
    {:split_cols, [{:alt, ?=}]},
    {:tab_prev, [{:alt, ?,}]},
    {:tab_next, [{:alt, ?.}]},
    # Resizing (roadmap item 18.8).
    {{:resize, :up}, [{:alt, :up}]},
    {{:resize, :down}, [{:alt, :down}]},
    {{:resize, :left}, [{:alt, :left}]},
    {{:resize, :right}, [{:alt, :right}]},
    # The command surfaces (ADR-0027, ADR-0028, ADR-0040, ADR-0042).
    {:minibuffer, [{:alt, ?m}]},
    {:palette, [{:alt, ?b}]},
    {:grid, [{:alt, ?g}]},
    {:settings, [{:alt, ?y}]},
    {:stop_shell, [{:ctrl, ?g}]},
    {:quit, [{:ctrl, ?x}, {:ctrl, ?q}, {:ctrl, ?c}]}
  ]

  @doc """
  The keys listed under more than one command (or twice under one) in `list`, a list of
  `{command, chords}` as the defaults are written. The defaults are checked with it as they
  compile: a key bound twice would quietly run only one of its commands.

      iex> Geex.Loop.Bindings.bound_twice([{:up, [{:alt, ?w}]}, {:down, [{:alt, ?s}, {:alt, ?w}]}])
      [{:alt, ?w}]
  """
  @spec bound_twice([{command(), [chord()]}]) :: [chord()]
  def bound_twice(list) do
    chords = Enum.flat_map(list, &elem(&1, 1))
    Enum.uniq(chords -- Enum.uniq(chords))
  end

  # A key bound twice would quietly run only one of its commands: refuse to compile (the same
  # check as `bound_twice/1`, which can't be called from here).
  @default_chords Enum.flat_map(@defaults, &elem(&1, 1))
  if @default_chords != Enum.uniq(@default_chords),
    do: raise("Geex.Loop.Bindings: a key bound twice in the defaults")

  # Each default chord's place, so a command's keys list in the order above.
  @order @defaults
         |> Enum.flat_map(fn {_command, chords} -> chords end)
         |> Enum.with_index()
         |> Map.new()

  # The editor's own keys, named so each key in the editor has a command (ADR-0047 §2): typed,
  # or bound to a chord, the command does what its key does.
  @own %{
    newline: {:key, :enter},
    indent: {:key, :tab},
    unindent: {:key, :shift_tab},
    delete_back: {:key, :backspace},
    delete_forward: {:key, :delete}
  }

  @doc "The defaults as they are written: each command with its keys, in the help's order."
  @spec default_list() :: [{command(), [chord()]}]
  def default_list, do: @defaults

  @doc """
  The default bindings: every bound key and the command it runs.

      iex> Geex.Loop.Bindings.defaults()[{:alt, ?z}]
      :undo
      iex> Geex.Loop.Bindings.defaults()[{:key, :home}]
      :line_start
  """
  @spec defaults() :: t()
  def defaults do
    for {command, chords} <- @defaults, chord <- chords, into: %{}, do: {chord, command}
  end

  # The moves on the motion cluster's Shift chords (ADR-0052) and the motion each is.
  @motion_of %{
    move_up: :up,
    move_down: :down,
    move_left: :left,
    move_right: :right,
    move_word_back: :word_back,
    move_word_forward: :word_forward,
    move_line_start: :line_start,
    move_line_end: :line_end
  }

  @doc """
  A move of text as its motion, for the places with no text to move: the tree, the panes, the
  pickers, the settings view, the command line, a preview (ADR-0052 §8). There, Caps Lock with
  the motion cluster still moves the highlight, as it did before the moves were bound.

      iex> Geex.Loop.Bindings.as_motion({:cmd, :move_down})
      {:cmd, :down}
      iex> Geex.Loop.Bindings.as_motion({:cmd, :duplicate})
      {:cmd, :duplicate}
  """
  @spec as_motion(term()) :: term()
  def as_motion({:cmd, command} = event) do
    case @motion_of do
      %{^command => motion} -> {:cmd, motion}
      _ -> event
    end
  end

  def as_motion(event), do: event

  @doc """
  The command a key runs under `bindings`, as `{:cmd, command}`; any other event as it came. An
  `Alt+Shift+letter` (or `Ctrl`) that isn't bound itself runs its lower case's command, so Caps
  Lock doesn't turn the keys off. A command passes through, so translating twice is translating
  once.

      iex> b = Geex.Loop.Bindings.defaults()
      iex> Geex.Loop.Bindings.translate({:alt, ?i}, b)
      {:cmd, :up}
      iex> Geex.Loop.Bindings.translate({:alt, ?W}, b)
      {:cmd, :close}
      iex> Geex.Loop.Bindings.translate({:alt, ?Z}, b)
      {:cmd, :redo}
      iex> Geex.Loop.Bindings.translate({:key, :enter}, b)
      {:key, :enter}
      iex> Geex.Loop.Bindings.translate({:cmd, :up}, b)
      {:cmd, :up}
  """
  @spec translate(term(), t()) :: term()
  def translate({:cmd, _} = event, _bindings), do: event

  def translate({kind, _} = chord, bindings) when kind in [:alt, :ctrl, :key] do
    case Map.fetch(bindings, chord) do
      {:ok, command} ->
        {:cmd, command}

      :error ->
        with {^kind, c} when c in ?A..?Z and kind in [:alt, :ctrl] <- chord,
             {:ok, command} <- Map.fetch(bindings, {kind, c + 32}) do
          {:cmd, command}
        else
          _ -> chord
        end
    end
  end

  def translate(event, _bindings), do: event

  @doc """
  The key a command named for one of the editor's own keys stands for (`line break` is Enter), or
  `nil`.

      iex> Geex.Loop.Bindings.own_key(:newline)
      {:key, :enter}
      iex> Geex.Loop.Bindings.own_key(:undo)
      nil
  """
  @spec own_key(command()) :: {:key, atom()} | nil
  def own_key(command), do: Map.get(@own, command)

  @doc "The commands named for the editor's own keys (`line break`, `indent` …)."
  @spec own_commands() :: [command()]
  def own_commands, do: Map.keys(@own)

  @doc """
  The keys that run `command` for a person to read: the bound ones (`keys/2`), then the
  focused view's own key that does the same in the editor (Enter for `line break`, Esc for `no`).

      iex> Geex.Loop.Bindings.shown_keys(Geex.Loop.Bindings.defaults(), :select_clear)
      [{:key, :esc}]
  """
  @spec shown_keys(t(), command()) :: [chord() | {:key, atom()}]
  def shown_keys(bindings, command) do
    own = if command == :select_clear, do: [{:key, :esc}], else: List.wrap(own_key(command))
    keys(bindings, command) ++ own
  end

  @doc """
  The keys bound to `command`: Alt chords, Alt with an arrow, Ctrl chords, then the named keys;
  within each, in the order the defaults list them (others after).

      iex> Geex.Loop.Bindings.keys(Geex.Loop.Bindings.defaults(), :quit)
      [{:ctrl, ?x}, {:ctrl, ?q}, {:ctrl, ?c}]
  """
  @spec keys(t(), command()) :: [chord()]
  def keys(bindings, command) do
    for({chord, ^command} <- bindings, do: chord)
    |> Enum.sort_by(&{kind(&1), Map.get(@order, &1, map_size(@order)), &1})
  end

  # Chords first, Alt with an arrow next, then Ctrl, then the named keys.
  defp kind({:alt, c}) when is_integer(c), do: 0
  defp kind({:alt, _dir}), do: 1
  defp kind({:ctrl, _c}), do: 2
  defp kind(_key), do: 3

  @doc """
  How `chord` is written for a person: `Alt+I`, `Alt+;`, `Alt+Shift+Z`, `Ctrl-O`, `Alt+↑`, `Home`.

      iex> Enum.map([{:alt, ?i}, {:alt, ?;}, {:alt, ?Z}, {:alt, ?1}, {:alt, :left}, {:ctrl, ?o}, {:key, :page_up}],
      ...>   &Geex.Loop.Bindings.label/1)
      ["Alt+I", "Alt+;", "Alt+Shift+Z", "Alt+1", "Alt+←", "Ctrl-O", "PgUp"]
  """
  @spec label(chord() | {:key, atom()}) :: String.t()
  def label({:alt, c}) when c in ?a..?z, do: "Alt+" <> <<c - 32>>
  def label({:alt, c}) when c in ?A..?Z, do: "Alt+Shift+" <> <<c>>
  def label({:alt, dir}) when is_atom(dir), do: "Alt+" <> arrow(dir)
  # `Alt+Shift+;` arrives as `ESC :` (ADR-0052); written as it's pressed.
  def label({:alt, ?:}), do: "Alt+Shift+;"
  def label({:alt, c}), do: "Alt+" <> <<c>>
  def label({:ctrl, c}) when c in ?a..?z, do: "Ctrl-" <> <<c - 32>>
  def label({:ctrl, c}), do: "Ctrl-" <> <<c>>
  def label({:key, :enter}), do: "Enter"
  def label({:key, :esc}), do: "Esc"
  def label({:key, :tab}), do: "Tab"
  def label({:key, :shift_tab}), do: "Shift+Tab"
  def label({:key, :backspace}), do: "Backspace"
  def label({:key, :delete}), do: "Delete"
  def label({:key, :home}), do: "Home"
  def label({:key, :end}), do: "End"
  def label({:key, :page_up}), do: "PgUp"
  def label({:key, :page_down}), do: "PgDn"
  def label({:key, dir}), do: arrow(dir)

  defp arrow(:up), do: "↑"
  defp arrow(:down), do: "↓"
  defp arrow(:left), do: "←"
  defp arrow(:right), do: "→"

  @doc """
  Whether `query` names one of the keys of `commands`, whole: `alt+w` finds `close`, `alt+5` bound
  to tab 5 finds it (its own key, not a range the help writes), `alt+s` finds `highlight` and not
  `Alt+Shift+Z`. Case and spaces don't matter, `ctrl+o` is `Ctrl-O`, and `alt+left` is `Alt+←`.
  A bare key counts too (`enter`, `home`): the palette ranks a command named like a key above
  the key's (ADR-0048), so `delete` is still the `delete` command first.

      iex> b = Geex.Loop.Bindings.defaults()
      iex> {Geex.Loop.Bindings.names_key?(b, [:close], "alt+w"), Geex.Loop.Bindings.names_key?(b, [:redo], "alt+s")}
      {true, false}
      iex> Geex.Loop.Bindings.names_key?(%{{:alt, ?5} => {:tab, 4}}, [{:tab, 4}], " Alt+5 ")
      true
      iex> Geex.Loop.Bindings.names_key?(b, [{:resize, :left}], "alt+left")
      true
      iex> Geex.Loop.Bindings.names_key?(b, [:newline], "Enter")
      true
  """
  @spec names_key?(t(), [command()], String.t()) :: boolean()
  def names_key?(bindings, commands, query), do: named_command(bindings, commands, query) != nil

  @doc """
  Which of `commands` the key `query` names runs, or `nil` (`names_key?/3`'s rule): with the nine
  tab commands on Alt+1 … Alt+9, `alt+5` of them is `{:tab, 4}`.

      iex> b = Map.new(0..8, &{{:alt, ?1 + &1}, {:tab, &1}})
      iex> Geex.Loop.Bindings.named_command(b, for(i <- 0..8, do: {:tab, i}), "alt+5")
      {:tab, 4}
      iex> Geex.Loop.Bindings.named_command(b, [:close], "tab")
      nil
  """
  @spec named_command(t(), [command()], String.t()) :: command() | nil
  def named_command(bindings, commands, query) do
    case written_form(query) do
      "" ->
        nil

      q ->
        Enum.find(commands, fn command ->
          Enum.any?(shown_keys(bindings, command), &(written_form(label(&1)) == q))
        end)
    end
  end

  @arrow_words %{"up" => "↑", "down" => "↓", "left" => "←", "right" => "→"}

  defp written_form(text) do
    text
    |> String.downcase()
    |> String.replace(" ", "")
    |> String.replace("ctrl-", "ctrl+")
    |> String.replace(~r/\+(up|down|left|right)$/, fn m ->
      "+" <> @arrow_words[String.trim_leading(m, "+")]
    end)
  end

  @doc """
  The keys of each of `commands`, written for a person and joined: `"Alt+Z  Alt+Shift+Z"`. With
  `range: true` and more than two keys, the first and the last (`"Alt+1 … Alt+9"`). A command
  bound to nothing adds nothing.

      iex> b = Geex.Loop.Bindings.defaults()
      iex> Geex.Loop.Bindings.labels(b, [:undo, :redo])
      "Alt+Z  Alt+Shift+Z"
      iex> Geex.Loop.Bindings.labels(b, [:line_start])
      "Alt+H Home"
      iex> tabs = Map.new(0..8, &{{:alt, ?1 + &1}, {:tab, &1}})
      iex> Geex.Loop.Bindings.labels(tabs, for(i <- 0..8, do: {:tab, i}), range: true)
      "Alt+1 … Alt+9"
  """
  @spec labels(t(), [command()], keyword()) :: String.t()
  def labels(bindings, commands, opts \\ []) do
    per_command =
      for command <- commands,
          chords = shown_keys(bindings, command),
          chords != [],
          do: Enum.map(chords, &label/1)

    case {opts[:range], List.flatten(per_command)} do
      {true, [first | rest]} when length(rest) > 1 -> first <> " … " <> List.last(rest)
      _ -> Enum.map_join(per_command, "  ", &Enum.join(&1, " "))
    end
  end
end
