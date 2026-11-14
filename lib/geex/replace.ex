defmodule Geex.Replace do
  @moduledoc """
  Replacing a search's matches in a text (`replace` and `replace-all`, 2026-11-13, ADR-0053's
  amendment). Pure: the loop runs it off the key loop on a buffer's text (ADR-0035) and
  dispatches what it answers through the one shared path.

  **The matches are the search's own** (`Geex.Search.matches/2`): each line's leftmost
  non-overlapping occurrences, smart case, never across a line end, a CRLF line's `"\\r"` no
  part of one, a byte that isn't UTF-8 one grapheme. Every match is replaced by the same text;
  the replacement is not searched again.

  **One command per text**, so a file's whole replacement is one undo step and one history
  entry: a `Replace` from the start of the first line with a match to the end of the last, its
  text those lines with every match replaced (a CRLF line keeps its `"\\r"`). The line count
  never changes (the replacement is one line), so `Geex.Blame` marks only the lines that held a
  match, as it does for a save's trim (ADR-0054). The command carries the human's provenance.
  """

  alias Geex.{Search, Text}
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.Replace, as: ReplaceCommand

  @doc """
  The command replacing every match of `query` in `text` with `replacement`, and how many
  matches it replaces; `:none` when there is none (or `query` is empty).

      iex> {:ok, cmd, 3} = Geex.Replace.plan("foo bar\\nbaz\\nfoo foo", "foo", "x")
      iex> {cmd.start_line, cmd.start_col, cmd.end_line, cmd.end_col, cmd.text}
      {0, 0, 2, 7, "x bar\\nbaz\\nx x"}
      iex> Geex.Replace.plan("abc", "z", "y")
      :none
      iex> {:ok, cmd, 1} = Geex.Replace.plan("a\\r\\nFoo\\r\\n", "foo", "bar")
      iex> {cmd.start_line, cmd.end_col, cmd.text}
      {1, 4, "bar\\r"}
  """
  @spec plan(binary(), String.t(), String.t()) :: {:ok, struct(), pos_integer()} | :none
  def plan(text, query, replacement) when is_binary(text) and is_binary(replacement) do
    case Search.matches(text, query) do
      <<>> ->
        :none

      packed ->
        by_line =
          packed |> Search.to_list() |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

        lines = :binary.split(text, "\n", [:global])
        {first, last} = Enum.min_max(Map.keys(by_line))

        new_text =
          lines
          |> Enum.slice(first..last)
          |> Enum.with_index(first)
          |> Enum.map_join("\n", fn {line, i} ->
            case by_line do
              %{^i => spans} -> replace_spans(line, spans, replacement)
              _ -> line
            end
          end)

        {:ok, cmd} =
          ReplaceCommand.parse(%{
            start_line: first,
            start_col: 0,
            end_line: last,
            end_col: Text.length(Enum.at(lines, last)),
            text: new_text
          })

        {:ok, Command.put_meta(cmd, Meta.human()), Search.count(packed)}
    end
  end

  # `line` with each `{start, stop}` grapheme span (in order, not overlapping) replaced.
  defp replace_spans(line, spans, replacement) do
    graphemes = Text.graphemes(line)

    {parts, rest_at} =
      Enum.reduce(spans, {[], 0}, fn {s, e}, {acc, at} ->
        {[replacement, Enum.slice(graphemes, at, s - at) | acc], e}
      end)

    [Enum.drop(graphemes, rest_at) | parts]
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
