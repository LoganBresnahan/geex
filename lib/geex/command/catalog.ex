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
  `line `).

  **Scope (ADR-0028 §3, decision "A").** v1 lists the **human command vocabulary that exists
  today** — the clipboard / history / selection verbs, `save`, `quit`, and `line`. It deliberately
  does **not** yet union the agent-only MCP tool descriptors (`tools/list`): the raw edit
  primitives (`insert`/`delete`/`replace`) are not human "commands" (you type to edit), and the
  file-path operations (`open`/`close`/`create`/…) need the **fuzzy finder** to supply a path —
  both arrive later. Exposing these verbs as agent-visible tools is the **grid-agent-parity** work
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
        "Take back the agent's (or outside) change under the cursor, keeping later edits (Alt+U).",
      invoke: {:action, :revert_hunk}
    },
    %Entry{
      name: "revert-call",
      description: "Take back the whole tool call that changed this line, keeping later edits.",
      invoke: {:action, :revert_call}
    },
    %Entry{
      name: "open",
      description: "Open a file (a path from this file's directory), or switch to it.",
      invoke: {:typed, "open"}
    },
    %Entry{
      name: "buffers",
      description: "Switch to another open buffer.",
      invoke: {:action, :buffers}
    },
    %Entry{
      name: "close",
      description: "Close this buffer (not while it has unsaved changes).",
      invoke: {:action, :close}
    },
    %Entry{
      name: "fast-forward",
      description: "Take in the file's change on disk, merging your unsaved edits (Alt+L).",
      invoke: {:action, :fast_forward}
    },
    %Entry{
      name: "highlight",
      description: "Start a selection at the cursor (extend it with motion).",
      invoke: {:action, :select_start}
    },
    %Entry{
      name: "select all",
      description: "Select the whole buffer.",
      invoke: {:action, :select_all}
    },
    %Entry{
      name: "line",
      description: "Go to a line by number (1-based; 0 = last line).",
      invoke: {:typed, "line"}
    },
    %Entry{
      name: "save",
      description: "Write the active buffer to disk.",
      invoke: {:action, :save}
    },
    %Entry{name: "quit", description: "Leave the editor.", invoke: {:action, :quit}}
  ]

  @doc "Every catalog command, in its canonical (declaration) order."
  @spec all() :: [Entry.t()]
  def all, do: @entries

  @doc """
  The catalog filtered + ranked against `query` (`Geex.Fuzzy`). An empty/blank query returns
  every command in canonical order. A **name** match always outranks a **description**-only match
  (so typing `cl` finds `clipboard`-described verbs but never above a verb literally named `cl…`);
  within a band, the fuzzy score orders them, ties keeping canonical order (stable sort).
  """
  @spec search(String.t()) :: [Entry.t()]
  def search(query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        @entries

      q ->
        @entries
        |> Enum.map(fn entry -> {entry, rank(entry, q)} end)
        |> Enum.reject(fn {_entry, r} -> is_nil(r) end)
        |> Enum.sort_by(fn {_entry, r} -> -r end)
        |> Enum.map(fn {entry, _r} -> entry end)
    end
  end

  # Name matches live in a high band (+1000) so they always sort above description-only matches;
  # a description hit keeps its raw score. `nil` (neither matches) drops the entry.
  defp rank(%Entry{name: name, description: desc}, q) do
    case Fuzzy.score(name, q) do
      nil -> Fuzzy.score(desc, q)
      score -> score + 1000
    end
  end
end
