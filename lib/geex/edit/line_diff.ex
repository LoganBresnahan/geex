defmodule Geex.Edit.LineDiff do
  @moduledoc """
  Line-level diff of two texts, as minimal `replace` spans (ADR-0032 step a).

  Reconcile used to adopt an out-of-band write as one whole-buffer `replace`. On the
  primary agent path that makes every agent edit one opaque step, so this turns a write
  into **one span per changed hunk**: undo then walks back hunk by hunk, and attribution
  and display can address the lines that actually changed.

  Pure: `hunks/2` runs `List.myers_difference/2` over the two texts' lines (split on
  `"\\n"`, the `Geex.Buffer.Doc` line model), and `spans/2` turns the hunks into
  `{range, text}` pairs for `Geex.Buffer.Doc.replace/3` — **ordered bottom-up**, so each
  span is valid against the document as it stands after the spans before it (a later
  hunk never moves the lines above it). Columns are graphemes, like every `Doc` column.
  """

  alias Geex.Buffer.Doc

  @typedoc "A changed run: at old line `line`, `removed` old lines become the `added` lines."
  @type hunk :: %{line: non_neg_integer(), removed: non_neg_integer(), added: [String.t()]}

  @typedoc "A `Doc.replace/3` range and its replacement text."
  @type span :: {{{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}}, String.t()}

  @doc """
  The changed hunks turning `old` into `new`, top to bottom, in `old`'s line coordinates.

      iex> Geex.Edit.LineDiff.hunks("a\\nb\\nc", "a\\nB\\nc")
      [%{line: 1, removed: 1, added: ["B"]}]
  """
  @spec hunks(String.t(), String.t()) :: [hunk()]
  def hunks(old, new) when is_binary(old) and is_binary(new) do
    old
    |> String.split("\n")
    |> List.myers_difference(String.split(new, "\n"))
    |> collect(0, nil, [])
  end

  defp collect([], _at, cur, acc), do: Enum.reverse(flush(cur, acc))

  defp collect([{:eq, lines} | rest], at, cur, acc),
    do: collect(rest, at + length(lines), nil, flush(cur, acc))

  defp collect([{:del, lines} | rest], at, cur, acc) do
    cur = cur || %{line: at, removed: 0, added: []}
    collect(rest, at + length(lines), %{cur | removed: cur.removed + length(lines)}, acc)
  end

  defp collect([{:ins, lines} | rest], at, cur, acc) do
    cur = cur || %{line: at, removed: 0, added: []}
    collect(rest, at, %{cur | added: cur.added ++ lines}, acc)
  end

  defp flush(nil, acc), do: acc
  defp flush(hunk, acc), do: [hunk | acc]

  @doc """
  The `Doc.replace/3` spans that turn `old` into `new`, one per hunk, **bottom-up**.

  Returns `{:ok, spans}` only after checking that applying them to `old` reproduces `new`
  byte for byte; otherwise `:error`, and the caller falls back to a whole-text replace.
  Equal texts give `{:ok, []}`.
  """
  @spec spans(String.t(), String.t()) :: {:ok, [span()]} | :error
  def spans(old, new) when is_binary(old) and is_binary(new) do
    old_lines = String.split(old, "\n")
    spans = old |> hunks(new) |> Enum.reverse() |> Enum.map(&span(&1, old_lines))

    if apply_spans(old, spans) == {:ok, new}, do: {:ok, spans}, else: :error
  end

  @doc "Apply bottom-up `spans` to `text` with `Doc.replace/3`."
  @spec apply_spans(String.t(), [span()]) :: {:ok, String.t()} | {:error, term()}
  def apply_spans(text, spans) do
    Enum.reduce_while(spans, {:ok, Doc.new(text)}, fn {range, replacement}, {:ok, doc} ->
      case Doc.replace(doc, range, replacement) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, doc} -> {:ok, Doc.text(doc)}
      error -> error
    end
  end

  # A hunk as a range over whole lines. Changed lines are replaced in place; a pure
  # insert or delete has to take one adjacent newline with it, and which one depends on
  # whether the hunk touches the end of the document.
  defp span(%{line: a, removed: n, added: added}, old_lines) when n > 0 and added != [] do
    last = a + n - 1
    {{{a, 0}, {last, width(old_lines, last)}}, Enum.join(added, "\n")}
  end

  defp span(%{line: a, removed: 0, added: added}, old_lines) do
    if a < length(old_lines) do
      {{{a, 0}, {a, 0}}, Enum.join(added, "\n") <> "\n"}
    else
      last = length(old_lines) - 1
      eol = {last, width(old_lines, last)}
      {{eol, eol}, "\n" <> Enum.join(added, "\n")}
    end
  end

  defp span(%{line: a, removed: n, added: []}, old_lines) do
    count = length(old_lines)

    cond do
      a + n < count ->
        {{{a, 0}, {a + n, 0}}, ""}

      a > 0 ->
        {{{a - 1, width(old_lines, a - 1)}, {a + n - 1, width(old_lines, a + n - 1)}}, ""}

      true ->
        # Every old line removed and nothing added can't come out of a diff (`new` always
        # has at least one line, so something is inserted); kept total for safety.
        {{{0, 0}, {count - 1, width(old_lines, count - 1)}}, ""}
    end
  end

  defp width(lines, row), do: lines |> Enum.at(row) |> String.length()
end
