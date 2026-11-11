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
  # covers Alt+Shift+letter too (`translate/2`, Caps Lock); the two Shift chords listed are the
  # ones that mean something else.
  @defaults [
              # Motion (ADR-0026): the arrows and the left-hand cluster.
              {:up, [{:alt, ?w}, {:key, :up}]},
              {:left, [{:alt, ?a}, {:key, :left}]},
              {:down, [{:alt, ?s}, {:key, :down}]},
              {:right, [{:alt, ?d}, {:key, :right}]},
              {:word_back, [{:alt, ?q}]},
              {:word_forward, [{:alt, ?e}]},
              {:line_start, [{:alt, ?r}, {:key, :home}]},
              {:line_end, [{:alt, ?f}, {:key, :end}]},
              {:page_up, [{:key, :page_up}]},
              {:page_down, [{:key, :page_down}]},
              # Selection (ADR-0029) and the clipboard (ADR-0015).
              {:select_start, [{:alt, ?h}]},
              {:select_all, [{:alt, ?b}]},
              {:select_clear, [{:alt, ?n}]},
              {:copy, [{:alt, ?c}]},
              {:cut, [{:alt, ?x}]},
              {:paste, [{:alt, ?v}]},
              # History (ADR-0031, ADR-0033 §7) and the file (ADR-0019, ADR-0034).
              {:undo, [{:alt, ?z}]},
              {:redo, [{:alt, ?Z}]},
              {:revert_hunk, [{:alt, ?u}]},
              {:save, [{:ctrl, ?o}]},
              {:fast_forward, [{:alt, ?j}]},
              # Files and panes (ADR-0037, ADR-0038, ADR-0043).
              {:find_file, [{:alt, ?o}]},
              {:close, [{:alt, ?k}]},
              {:toggle_tree, [{:alt, ?t}]},
              {:toggle_edits, [{:alt, ?l}]},
              {:next_pane, [{:alt, ?p}]},
              {:toggle_preview, [{:alt, ?P}]},
              {:split_rows, [{:alt, ?-}]},
              {:split_cols, [{:alt, ?=}]},
              {:tab_prev, [{:alt, ?,}]},
              {:tab_next, [{:alt, ?.}]}
            ] ++
              for(
                i <- 0..8,
                do: {{:tab, i}, [{:alt, ?1 + i}]}
              ) ++
              [
                # Resizing (roadmap item 18.8).
                {{:resize, :up}, [{:alt, :up}]},
                {{:resize, :down}, [{:alt, :down}]},
                {{:resize, :left}, [{:alt, :left}]},
                {{:resize, :right}, [{:alt, :right}]},
                # The command surfaces (ADR-0027, ADR-0028, ADR-0040, ADR-0042).
                {:minibuffer, [{:alt, ?m}]},
                {:palette, [{:alt, ?i}]},
                {:grid, [{:alt, ?g}]},
                {:settings, [{:alt, ?y}]},
                {:stop_shell, [{:ctrl, ?g}]},
                {:quit, [{:ctrl, ?x}, {:ctrl, ?q}, {:ctrl, ?c}]}
              ]

  # A key bound twice would quietly run only one of its commands: refuse to compile.
  @default_chords Enum.flat_map(@defaults, &elem(&1, 1))
  if length(@default_chords) != length(Enum.uniq(@default_chords)),
    do:
      raise(
        "Geex.Loop.Bindings: a key bound twice: #{inspect(@default_chords -- Enum.uniq(@default_chords))}"
      )

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
    indent_other: {:key, :shift_tab},
    delete_back: {:key, :backspace},
    delete_forward: {:key, :delete}
  }

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

  @doc """
  The command a key runs under `bindings`, as `{:cmd, command}`; any other event as it came. An
  `Alt+Shift+letter` (or `Ctrl`) that isn't bound itself runs its lower case's command, so Caps
  Lock doesn't turn the keys off. A command passes through, so translating twice is translating
  once.

      iex> b = Geex.Loop.Bindings.defaults()
      iex> Geex.Loop.Bindings.translate({:alt, ?w}, b)
      {:cmd, :up}
      iex> Geex.Loop.Bindings.translate({:alt, ?K}, b)
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
  The key a command named for one of the editor's own keys stands for (`newline` is Enter), or
  `nil`.

      iex> Geex.Loop.Bindings.own_key(:newline)
      {:key, :enter}
      iex> Geex.Loop.Bindings.own_key(:undo)
      nil
  """
  @spec own_key(command()) :: {:key, atom()} | nil
  def own_key(command), do: Map.get(@own, command)

  @doc "The commands named for the editor's own keys (`newline`, `indent` …)."
  @spec own_commands() :: [command()]
  def own_commands, do: Map.keys(@own)

  @doc """
  The keys that run `command` for a person to read: the bound ones (`keys/2`), then the
  focused view's own key that does the same in the editor (Enter for `newline`, Esc for `no`).

      iex> Geex.Loop.Bindings.shown_keys(Geex.Loop.Bindings.defaults(), :select_clear)
      [{:alt, ?n}, {:key, :esc}]
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
  How `chord` is written for a person: `Alt+W`, `Alt+Shift+Z`, `Ctrl-O`, `Alt+↑`, `Home`.

      iex> Enum.map([{:alt, ?w}, {:alt, ?Z}, {:alt, ?1}, {:alt, :left}, {:ctrl, ?o}, {:key, :page_up}],
      ...>   &Geex.Loop.Bindings.label/1)
      ["Alt+W", "Alt+Shift+Z", "Alt+1", "Alt+←", "Ctrl-O", "PgUp"]
  """
  @spec label(chord() | {:key, atom()}) :: String.t()
  def label({:alt, c}) when c in ?a..?z, do: "Alt+" <> <<c - 32>>
  def label({:alt, c}) when c in ?A..?Z, do: "Alt+Shift+" <> <<c>>
  def label({:alt, dir}) when is_atom(dir), do: "Alt+" <> arrow(dir)
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
  The keys of each of `commands`, written for a person and joined: `"Alt+Z  Alt+Shift+Z"`. With
  `range: true` and more than two keys, the first and the last (`"Alt+1 … Alt+9"`). A command
  bound to nothing adds nothing.

      iex> b = Geex.Loop.Bindings.defaults()
      iex> Geex.Loop.Bindings.labels(b, [:undo, :redo])
      "Alt+Z  Alt+Shift+Z"
      iex> Geex.Loop.Bindings.labels(b, [:line_start])
      "Alt+R Home"
      iex> Geex.Loop.Bindings.labels(b, for(i <- 0..8, do: {:tab, i}), range: true)
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
