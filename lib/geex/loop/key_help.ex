defmodule Geex.Loop.KeyHelp do
  @moduledoc """
  The keys, for the settings view's Keys tab ([ADR-0040](../../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §7): what each chord does, grouped, as `Geex.Loop.Keymap` and the loop resolve them
  ([ADR-0026](../../../doc/adr/0026-terminal-input-model.md), [ADR-0037](../../../doc/adr/0037-pane-and-file-keys.md),
  [ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md), [ADR-0039](../../../doc/adr/0039-mouse.md)).
  Pure data, kept beside the keymap; `search/2` filters it. A row about a command shows the keys
  the bindings give it ([ADR-0047](../../../doc/adr/0047-every-key-runs-a-named-command.md)), so a
  changed binding changes the help.
  """

  alias Geex.Loop.Bindings

  # `{group, keys, what}`: `keys` is the commands whose keys to show (`Geex.Loop.Bindings`,
  # ADR-0047), with `range: true` for a run like Alt+1 … Alt+9, or a string for the keys that
  # aren't bound (a view's own keys, the mouse). A row whose commands have no key is left out:
  # tab 1 to 9 has none by default (ADR-0051), and a binding taken away hides its row.
  @entries [
    {"Move", {[:up, :left, :down, :right]}, "up, left, down, right"},
    {"Move", {[:word_back, :word_forward]}, "a word back, a word forward"},
    {"Move", {[:line_start, :line_end]}, "the line's start, its end"},
    {"Move", {[:page_up, :page_down]}, "a page up, a page down"},
    {"Select", {[:select_start]}, "start a selection at the cursor; moving extends it"},
    {"Select", {[:select_all]}, "select the whole file"},
    {"Select", {[:select_clear]}, "clear the selection"},
    {"Edit", {[:copy, :cut, :paste]}, "copy, cut, paste (copy also to the system clipboard)"},
    {"Edit", "( [ { ' \" `",
     "typed with its closer, the cursor between; over a selection, wraps it (a setting turns it off)"},
    {"Edit", "Enter",
     "a new line, keeping the indent; one more after an opener (a setting turns it off)"},
    {"Edit", "Tab",
     "indent: as the file does (Go and Makefiles get tabs) or as the settings say; a selection's lines"},
    {"Edit", "Shift+Tab", "un-indent the selection's lines, or the cursor's line"},
    {"Edit", {[:indent_other]},
     "the other kind of indent: a tab where Tab gives spaces, or spaces"},
    {"Edit", {[:undo, :redo]}, "undo, redo"},
    {"Edit", {[:revert_hunk]}, "take back the change under the cursor (one hunk)"},
    {"Edit", {[:revert_call]}, "take back the whole tool call that changed this line"},
    {"Edit", {[:save]}, "save"},
    {"Files", {[:find_file]}, "open a file: the fuzzy finder"},
    {"Files", {[:close]}, "close the file (not with unsaved edits)"},
    {"Files", {[:fast_forward]}, "take in the file's change on disk, merging your edits"},
    {"Files", "a  d  r",
     "in the tree: add a file (a trailing / makes a directory), delete, rename"},
    {"Files", {[:minibuffer]},
     "then type a file operation: `new PATH`, `mkdir DIR`, `delete`, `rename PATH`"},
    {"Panes", {[:toggle_tree]}, "show or hide the file tree"},
    {"Panes", {[:toggle_edits]}, "show or hide the edits pane"},
    {"Panes", {[:prev_pane, :next_pane]},
     "the previous pane, the next pane: tree, editor, edits"},
    {"Panes", {[:split_rows, :split_cols]}, "split the pane top and bottom, side by side"},
    {"Panes", {[{:resize, :up}, {:resize, :down}, {:resize, :left}, {:resize, :right}]},
     "resize: move the focused pane's edge that way (a split, the tree, the edits pane)"},
    {"Panes", {[:tab_prev, :tab_next]}, "the previous tab, the next tab"},
    {"Panes", {for(i <- 0..8, do: {:tab, i}), range: true}, "tab 1 to 9"},
    {"Panes", {[:toggle_preview]}, "a markdown file's preview, beside it: show or hide"},
    {"Commands", {[:minibuffer]}, "type a command (`theme`, `open`, `mouse`, `quit` …)"},
    {"Commands", {[:up, :down]}, "in the command line: what was entered before"},
    {"Commands", "!cmd  !!  |cmd",
     "typed: run a shell command (its output below), the last again, pipe the selection through one"},
    {"Commands", {[:stop_shell]}, "stop the shell command running"},
    {"Commands", "Enter  !  q", "in the output: open its path:line, run it again, close it"},
    {"Commands", {[:palette]}, "the command palette"},
    {"Commands", {[:grid]}, "grid mode: pick by row and column"},
    {"Commands", {[:settings]}, "these settings"},
    {"Settings", {[:left, :right]}, "in these settings: the tab to the left, to the right"},
    {"Settings", {[:up, :down]}, "in these settings: move the highlight"},
    {"Commands", {[:quit]}, "quit"},
    {"Mouse", "click", "place the cursor; a tab, a tree row, an edit: open it"},
    {"Mouse", "drag", "select; past the edge it scrolls"},
    {"Mouse", "Shift+click  Alt+click", "extend the selection"},
    {"Mouse", "double-click", "select a word"},
    {"Mouse", "wheel", "scroll what's under the pointer"},
    {"Mouse", "drag #{Geex.Loop.TabBar.handle(:cols)}  #{Geex.Loop.TabBar.handle(:rows)}",
     "resize a split, the tree, the edits pane; double-click evens"},
    {"Mouse", "scroll bar", "a click jumps there; drag the thumb to scroll"},
    {"Mouse", "click ×", "close a tab, or a pane"},
    {"Mouse", "click #{Geex.Loop.TabBar.preview_glyph()}",
     "show or hide a markdown file's preview"}
  ]

  @type entry :: {String.t(), String.t(), String.t()}

  @doc """
  Every entry with a key: `{group, keys, what it does}`, the keys written from `bindings`.

      iex> Geex.Loop.KeyHelp.all() |> Enum.any?(&(elem(&1, 2) == "tab 1 to 9"))
      false
      iex> tabs = Map.new(0..8, &{{:alt, ?1 + &1}, {:tab, &1}})
      iex> Geex.Loop.KeyHelp.all(tabs) |> Enum.find(&(elem(&1, 2) == "tab 1 to 9"))
      {"Panes", "Alt+1 … Alt+9", "tab 1 to 9"}
  """
  @spec all(Bindings.t()) :: [entry()]
  def all(bindings \\ Bindings.defaults()) do
    for {group, keys, what} <- @entries,
        written = written(keys, bindings),
        written != "",
        do: {group, written, what}
  end

  defp written(keys, _bindings) when is_binary(keys), do: keys
  defp written({commands}, bindings), do: Bindings.labels(bindings, commands)
  defp written({commands, opts}, bindings), do: Bindings.labels(bindings, commands, opts)

  @doc """
  The entries whose group, keys or description contain every word of `query`, ignoring case.

      iex> Geex.Loop.KeyHelp.search("tab next") |> Enum.map(&elem(&1, 1))
      ["Alt+,  Alt+."]
      iex> length(Geex.Loop.KeyHelp.search("")) == length(Geex.Loop.KeyHelp.all())
      true
  """
  @spec search(String.t(), Bindings.t()) :: [entry()]
  def search(query, bindings \\ Bindings.defaults()) do
    words = query |> String.downcase() |> String.split()

    Enum.filter(all(bindings), fn {group, keys, what} ->
      text = String.downcase(group <> " " <> keys <> " " <> what)
      Enum.all?(words, &String.contains?(text, &1))
    end)
  end
end
