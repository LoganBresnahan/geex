defmodule Geex.Loop.KeyHelp do
  @moduledoc """
  The keys, for the settings view's Keys tab ([ADR-0040](../../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §7): what each chord does, grouped, as `Geex.Loop.Keymap` and the loop resolve them
  ([ADR-0026](../../../doc/adr/0026-terminal-input-model.md), [ADR-0037](../../../doc/adr/0037-pane-and-file-keys.md),
  [ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md), [ADR-0039](../../../doc/adr/0039-mouse.md)).
  Pure data, kept beside the keymap; `search/1` filters it.
  """

  @entries [
    {"Move", "Alt+W  Alt+A  Alt+S  Alt+D", "up, left, down, right (or the arrows)"},
    {"Move", "Alt+Q  Alt+E", "a word back, a word forward"},
    {"Move", "Alt+R  Alt+F", "the line's start, its end (or Home, End)"},
    {"Select", "Alt+H", "start a selection at the cursor; moving extends it"},
    {"Select", "Alt+B", "select the whole file"},
    {"Select", "Alt+N  Esc", "clear the selection"},
    {"Edit", "Alt+C  Alt+X  Alt+V", "copy, cut, paste (copy also to the system clipboard)"},
    {"Edit", "Alt+Z  Alt+Shift+Z", "undo, redo"},
    {"Edit", "Alt+U", "take back the change under the cursor (one hunk)"},
    {"Edit", "Ctrl-O", "save"},
    {"Files", "Alt+O", "open a file: the fuzzy finder"},
    {"Files", "Alt+K", "close the file (not with unsaved edits)"},
    {"Files", "Alt+J", "take in the file's change on disk, merging your edits"},
    {"Panes", "Alt+T", "show or hide the file tree"},
    {"Panes", "Alt+L", "show or hide the edits pane"},
    {"Panes", "Alt+P", "the next pane: tree, editor, edits"},
    {"Panes", "Alt+-  Alt+=", "split the pane top and bottom, side by side"},
    {"Panes", "Alt+,  Alt+.", "the previous tab, the next tab"},
    {"Panes", "Alt+1 … Alt+9", "tab 1 to 9"},
    {"Commands", "Alt+M", "type a command (`theme`, `open`, `mouse`, `quit` …)"},
    {"Commands", "Alt+I", "the command palette"},
    {"Commands", "Alt+G", "grid mode: pick by row and column"},
    {"Commands", "Alt+Y", "these settings"},
    {"Commands", "Ctrl-X  Ctrl-Q  Ctrl-C", "quit"},
    {"Mouse", "click", "place the cursor; a tab, a tree row, an edit: open it"},
    {"Mouse", "drag", "select; past the edge it scrolls"},
    {"Mouse", "Shift+click  Alt+click", "extend the selection"},
    {"Mouse", "double-click", "select a word"},
    {"Mouse", "wheel", "scroll what's under the pointer"},
    {"Mouse", "drag ⠿", "resize a split, the tree, the edits pane; double-click evens"},
    {"Mouse", "click ×", "close a tab, or a pane"}
  ]

  @type entry :: {String.t(), String.t(), String.t()}

  @doc "Every entry: `{group, keys, what it does}`."
  @spec all() :: [entry()]
  def all, do: @entries

  @doc """
  The entries whose group, keys or description contain every word of `query`, ignoring case.

      iex> Geex.Loop.KeyHelp.search("tab next") |> Enum.map(&elem(&1, 1))
      ["Alt+,  Alt+."]
      iex> length(Geex.Loop.KeyHelp.search("")) == length(Geex.Loop.KeyHelp.all())
      true
  """
  @spec search(String.t()) :: [entry()]
  def search(query) do
    words = query |> String.downcase() |> String.split()

    Enum.filter(@entries, fn {group, keys, what} ->
      text = String.downcase(group <> " " <> keys <> " " <> what)
      Enum.all?(words, &String.contains?(text, &1))
    end)
  end
end
