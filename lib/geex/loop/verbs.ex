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
    * `highlight` / `select` — start a selection at the cursor (= `Alt+H`, ADR-0029);
      `highlight all` / `select all` — select the whole buffer (= `Alt+B`).
    * `save` — write the active buffer to disk (= `Ctrl-O`; an operation, ADR-0019).
    * `quit` / `exit` — leave the editor (= `Ctrl-X`).
    * `no` — the typed twin of `Alt+N`: clears a live selection (a plain cancel when
      nothing is selected). An empty line just cancels.

  Anything else is `:unknown` (a no-op today; once the command **catalog** backs the
  palette, unknown verbs will resolve against it instead of a hardcoded table — this
  table is the v1 the catalog replaces).
  """

  @type verb ::
          {:line, non_neg_integer()}
          | {:action, atom()}
          | :cancel
          | :unknown

  @doc "Parse one minibuffer input line into a verb. Pure."
  @spec parse(String.t()) :: verb()
  def parse(input) when is_binary(input) do
    input |> String.trim() |> String.downcase() |> do_parse()
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
  defp do_parse("highlight"), do: {:action, :select_start}
  defp do_parse("select"), do: {:action, :select_start}
  defp do_parse("highlight all"), do: {:action, :select_all}
  defp do_parse("select all"), do: {:action, :select_all}
  defp do_parse("save"), do: {:action, :save}
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
end
