defmodule Geex.Command.Catalog do
  @moduledoc """
  The **command catalog** — the single structured list of commands a *human* can pick from the
  command palette ([ADR-0028](../../../doc/adr/0028-editor-shell-and-minibuffer.md) §3).

  This is the catalog the palette browses and fuzzy-matches (`Geex.Fuzzy`). It replaces the
  "what verbs exist?" knowledge that was implicit in the hardcoded `Geex.Loop.Verbs` table: a
  palette entry knows its `name`, a human `description`, and **how to invoke it** — either a
  zero-arg `{:action, atom}` dispatched straight through the loop's shared `apply_action/4`
  vocabulary (the same path `Alt+C`/a typed `copy` take), or a `{:typed, prefix}` that drops the
  user into `:command` mode pre-filled with the verb so they can supply its argument (e.g.
  `line `), or a `{:command, command}`: since ADR-0047 every key runs a named command, and the
  ones that had only a key (motion, resizing, the command surfaces) run as their key does.
  An entry's keys aren't written into it: they are read from the bindings
  (`Geex.Loop.Bindings`, `commands/1`).

  **Scope (ADR-0028 §3, decision "A").** v1 lists the **human command vocabulary that exists
  today** — the clipboard / history / selection verbs, `save`, `quit`, and `line`. It deliberately
  does **not** yet union the agent-only MCP tool descriptors (`tools/list`): the raw edit
  primitives (`insert`/`delete`/`replace`) are not human "commands" (you type to edit). The
  file operations arrived as the human's own: `open` is the fuzzy finder, `new`/`mkdir` take a
  typed path, and `rename`/`delete` act on the current file (ADR-0019's 2026-10-19 amendment). Exposing these verbs as agent-visible tools is the **grid-agent-parity** work
  that follows; when it lands, those descriptors fold into this catalog and `Verbs` can resolve
  against it too. One catalog, many surfaces — the same instinct as ADR-0003.
  """

  alias Geex.Fuzzy
  alias Geex.Command.Catalog.Entry

  @entries [
    %Entry{
      name: "copy",
      description: "Copy the selection to the clipboard.",
      invoke: {:action, :copy}
    },
    %Entry{
      name: "cut",
      description: "Cut the selection to the clipboard (deletes it).",
      invoke: {:action, :cut}
    },
    %Entry{
      name: "paste",
      description: "Paste the clipboard at the cursor.",
      invoke: {:action, :paste}
    },
    %Entry{name: "undo", description: "Undo the last edit.", invoke: {:action, :undo}},
    %Entry{name: "redo", description: "Redo the last undone edit.", invoke: {:action, :redo}},
    %Entry{
      name: "revert",
      description:
        "Take back the agent's (or outside) change under the cursor, keeping later edits.",
      invoke: {:action, :revert_hunk}
    },
    %Entry{
      name: "revert-call",
      description: "Take back the whole tool call that changed this line, keeping later edits.",
      invoke: {:action, :revert_call}
    },
    %Entry{
      name: "open",
      usage: "open [PATH]",
      aliases: ["find"],
      description: "Find a file by name and open it, or switch to it.",
      invoke: {:action, :find_file}
    },
    %Entry{
      name: "buffers",
      description: "Switch to another open buffer.",
      invoke: {:action, :buffers}
    },
    %Entry{
      name: "close",
      description: "Close this tab; the buffer too, unless it has unsaved changes.",
      invoke: {:action, :close}
    },
    %Entry{
      name: "new",
      usage: "new PATH",
      description:
        "Create a file, from the project root, and open it (`new DIR/` makes a directory).",
      invoke: {:typed, "new"}
    },
    %Entry{
      name: "mkdir",
      usage: "mkdir DIR",
      description: "Make a directory, from the project root.",
      invoke: {:typed, "mkdir"}
    },
    %Entry{
      name: "rename",
      usage: "rename [PATH]",
      aliases: ["mv"],
      description: "Rename or move this file, keeping its undo history.",
      invoke: {:action, :rename_file}
    },
    %Entry{
      name: "delete",
      description: "Delete this file from disk, after a y/n.",
      invoke: {:action, :delete_file}
    },
    %Entry{
      name: "!",
      usage: "!COMMAND",
      description:
        "Run a shell command in the project root; its output shows below (`!!` again).",
      invoke: {:typed, "!"}
    },
    %Entry{
      name: "|",
      usage: "|COMMAND",
      description: "Pipe the selection through a shell command and replace it with the output.",
      invoke: {:typed, "|"}
    },
    %Entry{
      name: "tree",
      description: "Show or hide the file tree (`pane-next` moves into it).",
      invoke: {:action, :toggle_tree}
    },
    %Entry{
      name: "edits",
      description: "Show or hide the edits pane: who changed which file, and when.",
      invoke: {:action, :toggle_edits}
    },
    %Entry{
      name: "preview",
      description: "Show or hide a markdown file's rendered preview beside it (read-only).",
      invoke: {:action, :toggle_preview}
    },
    %Entry{
      name: "split",
      description: "Split the pane top and bottom.",
      invoke: {:action, :split_rows}
    },
    %Entry{
      name: "vsplit",
      description: "Split the pane side by side.",
      invoke: {:action, :split_cols}
    },
    %Entry{
      name: "tab-next",
      description: "Show the pane's next tab.",
      invoke: {:action, :tab_next}
    },
    %Entry{
      name: "tab-prev",
      description: "Show the pane's previous tab.",
      invoke: {:action, :tab_prev}
    },
    %Entry{
      name: "mouse",
      description: "Turn the mouse off, so the terminal selects and copies text, or back on.",
      invoke: {:action, :toggle_mouse}
    },
    %Entry{
      name: "theme terminal",
      description: "Use the terminal's own colours, for this session (`theme` lists the rest).",
      invoke: {:action, {:theme, "terminal"}}
    },
    %Entry{
      name: "theme",
      usage: "theme [NAME]",
      description:
        "Use an installed theme, for this session (`settings` installs and keeps one).",
      invoke: {:typed, "theme"}
    },
    %Entry{
      name: "fast-forward",
      description: "Take in the file's change on disk, merging your unsaved edits.",
      invoke: {:action, :fast_forward}
    },
    %Entry{
      name: "highlight",
      aliases: ["select"],
      description: "Start a selection at the cursor (extend it with motion).",
      invoke: {:action, :select_start}
    },
    %Entry{
      name: "select-all",
      aliases: ["highlight-all"],
      description: "Select the whole buffer.",
      invoke: {:action, :select_all}
    },
    %Entry{
      name: "line",
      usage: "line N",
      aliases: ["N"],
      description: "Go to a line by number (1-based; 0 = last line).",
      invoke: {:typed, "line"}
    },
    %Entry{
      name: "save",
      description: "Write the active buffer to disk.",
      invoke: {:action, :save}
    },
    %Entry{
      name: "no",
      description: "Clear the selection; in the command line, close it.",
      invoke: {:action, :select_clear}
    },
    %Entry{
      name: "!!",
      description: "Run the last shell command again.",
      invoke: {:typed, "!!"}
    },
    %Entry{
      name: "tab",
      usage: "tab N",
      description: "Show the pane's tab N.",
      invoke: {:typed, "tab"},
      binds: for(i <- 0..8, do: {:tab, i})
    },
    # The commands that had only a key until ADR-0047: typed, or picked here, they do what
    # their key does in the editor (ADR-0047 §6).
    %Entry{
      name: "command-line",
      description: "Type a command (this line).",
      invoke: {:command, :minibuffer}
    },
    %Entry{
      name: "palette",
      aliases: ["catalog"],
      description: "Pick a command from this list.",
      invoke: {:command, :palette}
    },
    %Entry{
      name: "grid",
      description: "Grid mode: pick a place or a range by row and column.",
      invoke: {:command, :grid}
    },
    %Entry{
      name: "settings",
      description: "Languages, themes, keys, commands and settings.",
      invoke: {:command, :settings}
    },
    %Entry{
      name: "search",
      aliases: ["find-in-file"],
      usage: "search [TEXT]",
      description:
        "Search this file: type, Enter keeps the match selected, Esc goes back; `search TEXT` searches for TEXT.",
      invoke: {:command, :search}
    },
    %Entry{
      name: "search-project",
      usage: "search-project [TEXT]",
      aliases: ["grep"],
      description:
        "Search the project's files (git grep), build and dependency folders left out; results below.",
      invoke: {:command, :search_project}
    },
    %Entry{
      name: "search-all",
      usage: "search-all [TEXT]",
      description: "Search every file in the project, ignored ones too; results below.",
      invoke: {:command, :search_all}
    },
    %Entry{
      name: "next-match",
      description: "Select the next match of the last search, wrapping at the end of the file.",
      invoke: {:command, :next_match}
    },
    %Entry{
      name: "pane-next",
      aliases: ["next-pane"],
      description: "Move to the next pane: the tree, the editor's panes, the edits pane.",
      invoke: {:command, :next_pane}
    },
    %Entry{
      name: "pane-prev",
      aliases: ["previous-pane"],
      description: "Move to the previous pane: the edits pane, the editor's panes, the tree.",
      invoke: {:command, :prev_pane}
    },
    %Entry{
      name: "stop",
      description: "Stop the shell command running.",
      invoke: {:command, :stop_shell}
    },
    %Entry{
      name: "up",
      description: "Move up a line; in a list, up a row; in the command line, an earlier entry.",
      invoke: {:command, :up}
    },
    %Entry{
      name: "down",
      description: "Move down a line; in a list, down a row; in the command line, a later entry.",
      invoke: {:command, :down}
    },
    %Entry{
      name: "left",
      description: "Move left; in the tree, close a directory or go up to it.",
      invoke: {:command, :left}
    },
    %Entry{
      name: "right",
      description: "Move right; in the tree, open a directory.",
      invoke: {:command, :right}
    },
    %Entry{
      name: "word-back",
      description: "Move to the start of the word before.",
      invoke: {:command, :word_back}
    },
    %Entry{
      name: "word-forward",
      description: "Move to the start of the next word.",
      invoke: {:command, :word_forward}
    },
    %Entry{
      name: "line-start",
      description: "Move to the line's start; in the output pane or a preview, the top.",
      invoke: {:command, :line_start}
    },
    %Entry{
      name: "line-end",
      description: "Move to the line's end; in the output pane or a preview, the bottom.",
      invoke: {:command, :line_end}
    },
    %Entry{
      name: "page-up",
      description: "Scroll a preview up a page.",
      invoke: {:command, :page_up}
    },
    %Entry{
      name: "page-down",
      description: "Scroll a preview down a page.",
      invoke: {:command, :page_down}
    },
    %Entry{
      name: "resize-up",
      description: "Move the focused pane's edge up.",
      invoke: {:command, {:resize, :up}}
    },
    %Entry{
      name: "resize-down",
      description: "Move the focused pane's edge down.",
      invoke: {:command, {:resize, :down}}
    },
    %Entry{
      name: "resize-left",
      description: "Move the focused pane's edge left.",
      invoke: {:command, {:resize, :left}}
    },
    %Entry{
      name: "resize-right",
      description: "Move the focused pane's edge right.",
      invoke: {:command, {:resize, :right}}
    },
    %Entry{
      name: "line-break",
      aliases: ["newline"],
      description: "Break the line here, keeping the indent.",
      invoke: {:command, :newline}
    },
    %Entry{
      name: "indent",
      description:
        "Insert one indent level, as the file indents, or indent the selection's lines.",
      invoke: {:command, :indent}
    },
    %Entry{
      name: "unindent",
      description: "Take one indent level from the selection's lines, or from the cursor's line.",
      aliases: ["outdent", "dedent"],
      invoke: {:command, :unindent}
    },
    %Entry{
      name: "indent-other",
      description:
        "Insert the other kind of indent: a tab where `indent` gives spaces, or spaces.",
      invoke: {:command, :indent_other}
    },
    %Entry{
      name: "duplicate",
      description: "Copy the cursor's line, or the selection's lines, below themselves.",
      invoke: {:command, :duplicate}
    },
    %Entry{
      name: "select-character",
      aliases: ["select-char"],
      description: "Select the character at the cursor, or one more.",
      invoke: {:command, :select_char}
    },
    %Entry{
      name: "select-word",
      description: "Select the word at the cursor, or take in the next word.",
      invoke: {:command, :select_word}
    },
    %Entry{
      name: "select-line",
      description: "Select the cursor's whole line, or take in the next line.",
      invoke: {:command, :select_line}
    },
    %Entry{
      name: "matching-bracket",
      aliases: ["bracket"],
      description:
        "Go to the bracket paired with the one at the cursor, or to the one around it.",
      invoke: {:command, :matching_bracket}
    },
    %Entry{
      name: "comment",
      aliases: ["uncomment"],
      description: "Comment out the cursor's line or the selection's lines, or uncomment them.",
      invoke: {:command, :comment}
    },
    %Entry{
      name: "move-up",
      aliases: ["move-line-up"],
      description: "Swap the cursor's line, or the selection's lines, with the line above.",
      invoke: {:command, :move_up}
    },
    %Entry{
      name: "move-down",
      aliases: ["move-line-down"],
      description: "Swap the cursor's line, or the selection's lines, with the line below.",
      invoke: {:command, :move_down}
    },
    %Entry{
      name: "move-left",
      description: "Move the selected text one character left.",
      invoke: {:command, :move_left}
    },
    %Entry{
      name: "move-right",
      description: "Move the selected text one character right.",
      invoke: {:command, :move_right}
    },
    %Entry{
      name: "move-word-back",
      description: "Swap the selected text with the word before it.",
      invoke: {:command, :move_word_back}
    },
    %Entry{
      name: "move-word-forward",
      description: "Swap the selected text with the word after it.",
      invoke: {:command, :move_word_forward}
    },
    %Entry{
      name: "move-to-line-start",
      description: "Move the selected text to the start of its line, after the indent.",
      invoke: {:command, :move_line_start}
    },
    %Entry{
      name: "move-to-line-end",
      description: "Move the selected text to the end of its line.",
      invoke: {:command, :move_line_end}
    },
    %Entry{
      name: "delete-back",
      description: "Delete the character before the cursor (or the selection).",
      invoke: {:command, :delete_back}
    },
    %Entry{
      name: "delete-forward",
      description: "Delete the character under the cursor (or the selection).",
      invoke: {:command, :delete_forward}
    },
    %Entry{
      name: "quit",
      aliases: ["exit"],
      description: "Leave the editor.",
      invoke: {:action, :quit}
    }
  ]

  @doc """
  How `entry` is typed, with its other names: `usage` (or the name) and the aliases.

      iex> Geex.Command.Catalog.all() |> Enum.find(&(&1.name == "rename")) |> Geex.Command.Catalog.typed()
      "rename [PATH], mv"
      iex> Geex.Command.Catalog.all() |> Enum.find(&(&1.name == "save")) |> Geex.Command.Catalog.typed()
      "save"
  """
  @spec typed(Entry.t()) :: String.t()
  def typed(%Entry{} = entry), do: Enum.join([entry.usage || entry.name | entry.aliases], ", ")

  @doc """
  The commands `entry` runs, by which its keys are found (`Geex.Loop.Bindings`, ADR-0047): its
  action or command, or the ones it lists (`tab` is `{:tab, 0}` … `{:tab, 8}`); none for a verb
  that needs what you type.

      iex> Geex.Command.Catalog.all() |> Enum.find(&(&1.name == "undo")) |> Geex.Command.Catalog.commands()
      [:undo]
      iex> Geex.Command.Catalog.all() |> Enum.find(&(&1.name == "word-back")) |> Geex.Command.Catalog.commands()
      [:word_back]
  """
  @spec commands(Entry.t()) :: [term()]
  def commands(%Entry{binds: binds}) when is_list(binds), do: binds
  def commands(%Entry{invoke: {kind, command}}) when kind in [:action, :command], do: [command]
  def commands(%Entry{}), do: []

  @doc "Every catalog command, in its canonical (declaration) order."
  @spec all() :: [Entry.t()]
  def all, do: @entries

  # Where a query or a name breaks into words: spaces, and a name's hyphens.
  @word_break ~r/[\s-]+/

  @doc """
  The catalog filtered + ranked against `query` (ADR-0048), in three bands:

  1. the commands whose **name matches well**: each word of the query starts a word of the name
     or an alias, in order (`line e` → `line-end`; a typed space matches a hyphen);
  2. the commands `keyed?` says the query's key runs (`enter` → `line-break`; the caller knows
     the bindings, the catalog doesn't);
  3. every other match (`Geex.Fuzzy`): a name match above a description-only one.

  Within a band the fuzzy score orders, ties keeping canonical order (stable sort); a command
  shows once, in its highest band. An empty/blank query returns every command in canonical order.

      iex> Geex.Command.Catalog.search("line e") |> hd() |> Map.fetch!(:name)
      "line-end"
      iex> Geex.Command.Catalog.search("enter", &(&1.name == "line-break")) |> hd() |> Map.fetch!(:name)
      "line-break"
      iex> Geex.Command.Catalog.search("delete", &(&1.name == "delete-forward")) |> hd() |> Map.fetch!(:name)
      "delete"
  """
  @spec search(String.t(), (Entry.t() -> boolean())) :: [Entry.t()]

  def search(query, keyed? \\ fn _ -> false end) when is_binary(query) do
    case String.trim(query) do
      "" ->
        @entries

      q ->
        words = q |> String.downcase() |> String.split(@word_break, trim: true)

        @entries
        |> Enum.map(fn entry -> {entry, band(entry, words, keyed?), rank(entry, q)} end)
        |> Enum.reject(fn {_entry, band, r} -> band == 3 and is_nil(r) end)
        |> Enum.sort_by(fn {_entry, band, r} -> {band, -(r || 0)} end)
        |> Enum.map(fn {entry, _band, _r} -> entry end)
    end
  end

  defp band(%Entry{name: name, aliases: aliases} = entry, words, keyed?) do
    cond do
      Enum.any?([name | aliases], &word_starts?(name_words(&1), words)) -> 1
      keyed?.(entry) -> 2
      true -> 3
    end
  end

  # A name's words, split where it has a hyphen: `search-all` is `search` and `all`.
  defp name_words(name), do: name |> String.downcase() |> String.split(@word_break, trim: true)

  # Each query word starts a word of the name, in order: `sel al` in `select-all`.
  defp word_starts?(_name, []), do: true
  defp word_starts?([], _words), do: false

  defp word_starts?([n | name], [w | words] = all) do
    if String.starts_with?(n, w),
      do: word_starts?(name, words),
      else: word_starts?(name, all)
  end

  # Name matches live in a high band (+1000) so they always sort above description-only matches;
  # a description hit keeps its raw score. `nil` (neither matches) drops the entry.
  defp rank(%Entry{name: name, aliases: aliases, description: desc}, q) do
    # A space typed matches a name's hyphen: `search-all` scores as `search-all` does.
    q = String.replace(q, " ", "-")

    case [name | aliases] |> Enum.map(&Fuzzy.score(&1, q)) |> Enum.reject(&is_nil/1) do
      [] -> Fuzzy.score(desc, q)
      scores -> Enum.max(scores) + 1000
    end
  end

  @doc """
  An entry narrowed to one of its commands, to run rather than hand off: `tab N` found by a key
  bound to tab 5 is `tab 5`, which shows tab 5 (ADR-0048 §2). An entry for one command is itself.
  """
  @spec narrow(Entry.t(), term()) :: Entry.t()
  def narrow(%Entry{name: "tab"} = entry, {:tab, i} = command) do
    %{
      entry
      | name: "tab #{i + 1}",
        description: String.replace(entry.description, "tab N", "tab #{i + 1}"),
        invoke: {:action, command},
        binds: [command]
    }
  end

  def narrow(%Entry{} = entry, _command), do: entry
end
