defmodule Geex.Loop.Verbs do
  @moduledoc """
  The **typed-verb parser** for the minibuffer's `:command` mode — the typed twin of
  `Geex.Loop.Keymap` ([ADR-0028](../../../doc/adr/0028-editor-shell-and-minibuffer.md)
  parity: every keyboard capability is also a typed command). Pure: one input string →
  one parsed verb; the loop applies it through the **same action vocabulary** the
  keymap resolves chords into, so `copy` and `Alt+C` converge on one code path.

  Grammar (case-insensitive, whitespace-trimmed):

    * `42` / `line 42` — go to line ([ADR-0030](../../../doc/adr/0030-view-action-tool-category.md)
      `line` view action; the bare number is sugar). 1-based; `0` = the last line.
    * `copy` / `cut` / `paste` — the clipboard verbs (= `Alt+C`/`X`/`V`, ADR-0015).
    * `undo` / `redo` — the history operations (= `Alt+Z`/`Alt+Shift+Z`, ADR-0031).
    * `revert` / `revert-call` — take back the agent's (or outside) change under the cursor,
      one hunk (= `Alt+U`) or its whole tool call, keeping later edits (ADR-0033 §7).
    * `highlight` / `select` — start a selection at the cursor (= `Alt+H`, ADR-0029);
      `highlight all` / `select all` — select the whole buffer (= `Alt+B`).
    * `save` — write the active buffer to disk (= `Ctrl-O`; an operation, ADR-0019).
    * `fast-forward` — take in the file's change on disk (= `Alt+J`, ADR-0034, ADR-0037).
    * `edits` / `tree` — show or hide the edits pane / the file tree (= `Alt+L` / `Alt+T`;
      `Alt+P` moves between the panes). ADR-0034, ADR-0037.
    * `open PATH` — show a file, opening it if needed; a relative `PATH` is from the current
      file's directory, and keeps its case. `open` alone or `find` — the file finder (= `Alt+O`,
      ADR-0037). `buffers` — pick an open buffer. `close` — close this buffer (= `Alt+K`;
      refused while it has unsaved edits). ADR-0034.
    * `split` / `vsplit` — split the pane top and bottom / side by side (= `Alt+-` / `Alt+=`);
      `tab next` / `tab prev` / `tab N` — switch the pane's tab (= `Alt+.` / `Alt+,` /
      `Alt+N`). ADR-0038.
    * `mouse` — turn the mouse off, so the terminal selects and copies text itself, or back on
      (ADR-0039).
    * `quit` / `exit` — leave the editor (= `Ctrl-X`).
    * `no` — the typed twin of `Alt+N`: clears a live selection (a plain cancel when
      nothing is selected). An empty line just cancels.

  Anything else is `:unknown` (a no-op today). The command **catalog**
  ([`Geex.Command.Catalog`](../command/catalog.ex)) now backs the **palette** (ADR-0028 §3, built); the
  remaining consolidation — having *this* parser resolve against that catalog instead of the
  hardcoded clauses below — lands with the grid-agent-parity work, when the action-verbs become
  catalog/tool entries in their own right. Until then this table is the typed-mode v1.
  """

  alias Geex.Coord

  @type verb ::
          {:line, non_neg_integer()}
          | {:action, atom() | {:tab, non_neg_integer()}}
          | {:open, String.t()}
          | :cancel
          | :unknown

  @type grid ::
          {:goto, Coord.t()}
          | {:copy, Coord.Range.t()}
          | {:cut, Coord.Range.t()}
          | :cancel
          | :unknown

  @doc "Parse one minibuffer input line into a verb. Pure."
  @spec parse(String.t()) :: verb()
  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)

    # `open PATH` before the rest is lowercased: a path keeps its case.
    case String.split(trimmed, ~r/\s+/, parts: 2) do
      [verb, path] -> if String.downcase(verb) == "open", do: {:open, path}, else: :lower
      _ -> :lower
    end
    |> case do
      :lower -> trimmed |> String.downcase() |> do_parse()
      open -> open
    end
  end

  @doc """
  Parse a `:grid`-mode line (ADR-0027): `copy`/`cut` over a coordinate **range**, `goto`
  (or a bare coordinate) over a single **coordinate**. The coordinates are *display columns*
  here (the ruler is up) — the loop casts `x` to a grapheme before resolving. `no`/empty
  cancels; a malformed line or the wrong shape for the verb (a coord where a range is needed)
  is `:unknown`. Pure — `Geex.Coord.parse/1` does the syntactic work.
  """
  @spec parse_grid(String.t()) :: grid()
  def parse_grid(input) when is_binary(input) do
    input |> String.trim() |> String.downcase() |> do_parse_grid()
  end

  defp do_parse_grid(""), do: :cancel
  defp do_parse_grid("no"), do: :cancel
  defp do_parse_grid("copy " <> rest), do: grid_range(rest, :copy)
  defp do_parse_grid("cut " <> rest), do: grid_range(rest, :cut)
  defp do_parse_grid("goto " <> rest), do: grid_coord(rest, :goto)
  # A bare coordinate (no verb) jumps the cursor there.
  defp do_parse_grid(rest), do: grid_coord(rest, :goto)

  defp grid_range(rest, verb) do
    case Coord.parse(rest) do
      {:ok, %Coord.Range{} = range} -> {verb, range}
      _ -> :unknown
    end
  end

  defp grid_coord(rest, verb) do
    case Coord.parse(rest) do
      {:ok, %Coord{} = coord} -> {verb, coord}
      _ -> :unknown
    end
  end

  defp do_parse(""), do: :cancel
  # `no` is the true Alt+N twin: it *clears* a live selection (then the minibuffer closes
  # either way). With nothing selected it degrades to a plain cancel — same visible result.
  defp do_parse("no"), do: {:action, :select_clear}

  defp do_parse("line " <> rest), do: parse_line(String.trim(rest))

  defp do_parse("copy"), do: {:action, :copy}
  defp do_parse("cut"), do: {:action, :cut}
  defp do_parse("paste"), do: {:action, :paste}
  defp do_parse("undo"), do: {:action, :undo}
  defp do_parse("redo"), do: {:action, :redo}
  defp do_parse("revert"), do: {:action, :revert_hunk}
  defp do_parse("revert-call"), do: {:action, :revert_call}
  defp do_parse("highlight"), do: {:action, :select_start}
  defp do_parse("select"), do: {:action, :select_start}
  defp do_parse("highlight all"), do: {:action, :select_all}
  defp do_parse("select all"), do: {:action, :select_all}
  defp do_parse("save"), do: {:action, :save}
  defp do_parse("fast-forward"), do: {:action, :fast_forward}
  defp do_parse("buffers"), do: {:action, :buffers}
  defp do_parse("close"), do: {:action, :close}
  defp do_parse("edits"), do: {:action, :toggle_edits}
  defp do_parse("tree"), do: {:action, :toggle_tree}
  defp do_parse("split"), do: {:action, :split_rows}
  defp do_parse("vsplit"), do: {:action, :split_cols}
  defp do_parse("tab next"), do: {:action, :tab_next}
  defp do_parse("tab prev"), do: {:action, :tab_prev}
  defp do_parse("tab " <> n), do: parse_tab(String.trim(n))
  # `open` with no path, or `find`: the file finder (= `Alt+O`, ADR-0037).
  defp do_parse("open"), do: {:action, :find_file}
  defp do_parse("find"), do: {:action, :find_file}
  defp do_parse("mouse"), do: {:action, :toggle_mouse}
  defp do_parse("quit"), do: {:action, :quit}
  defp do_parse("exit"), do: {:action, :quit}

  # A bare number is go-to-line sugar (the original v1 minibuffer behaviour, kept).
  defp do_parse(input), do: parse_line(input)

  # Unsigned digit strings only: `Integer.parse` would also accept `-3`/`+5`/`-0`, and a
  # *signed* go-to-line is at best ambiguous (`-0` would silently mean "last line") — so a
  # sign is rejected, not interpreted.
  defp parse_line(<<c, _::binary>> = input) when c in ?0..?9 do
    case Integer.parse(input) do
      {n, ""} -> {:line, n}
      _ -> :unknown
    end
  end

  defp parse_line(_input), do: :unknown

  # `tab N`, 1-based as the tab bar numbers them.
  defp parse_tab(n) do
    case Integer.parse(n) do
      {i, ""} when i >= 1 -> {:action, {:tab, i - 1}}
      _ -> :unknown
    end
  end
end
