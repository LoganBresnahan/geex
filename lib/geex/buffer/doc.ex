defmodule Geex.Buffer.Doc do
  @moduledoc """
  The pure text model of a buffer: lines of text, and pure operations over them.

  This is the **replay-able unit** (ADR-0002, mcp-ai-integration.md §15c). It has
  no process, no I/O — `insert/3` and `delete/3` are pure functions returning a new
  `Doc`. A `Geex.Buffer` process will hold a `Doc` plus an undo history of the
  commands applied to it; replaying that command list through `Geex.Dispatch`
  reproduces the `Doc` exactly. Keeping the data model pure is what makes the
  command system testable without the terminal (§15a).

  Coordinates are `{row, col}`, both 0-based, `col` counted in **graphemes** (so
  UTF-8 is handled correctly, matching `Geex.Input.Parser`'s grapheme handling).
  v0.1 edits are single-line for `delete`; multi-line `insert` is supported
  (inserted text may contain newlines). Multi-line delete lands with range
  commands.
  """

  defstruct lines: [""]

  @type t :: %__MODULE__{lines: [String.t()]}
  @type pos :: {non_neg_integer(), non_neg_integer()}

  @doc "Build a Doc from text, splitting on newlines. Empty text is one empty line."
  @spec new(String.t()) :: t()
  def new(text \\ "") when is_binary(text), do: %__MODULE__{lines: String.split(text, "\n")}

  @doc "Render the Doc back to a single string."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{lines: lines}), do: Enum.join(lines, "\n")

  @doc "Number of lines."
  @spec line_count(t()) :: non_neg_integer()
  def line_count(%__MODULE__{lines: lines}), do: length(lines)

  @doc "The line at `row`, or `nil` if out of range."
  @spec line(t(), non_neg_integer()) :: String.t() | nil
  def line(%__MODULE__{lines: lines}, row), do: Enum.at(lines, row)

  @doc """
  Insert `text` at `{row, col}`. `text` may contain newlines, which split the
  line. Returns `{:ok, doc}` or `{:error, :row_out_of_range | :col_out_of_range}`.
  """
  @spec insert(t(), pos(), String.t()) :: {:ok, t()} | {:error, atom()}
  def insert(%__MODULE__{lines: lines} = doc, {row, col}, text)
      when is_integer(row) and is_integer(col) and is_binary(text) do
    with {:ok, graphemes} <- fetch_graphemes(lines, row),
         true <- col >= 0 and col <= length(graphemes) do
      {pre, post} = Enum.split(graphemes, col)
      new_lines = splice(String.split(text, "\n"), Enum.join(pre), Enum.join(post))

      replaced =
        lines
        |> List.replace_at(row, new_lines)
        |> List.flatten()

      {:ok, %__MODULE__{doc | lines: replaced}}
    else
      {:error, _} = e -> e
      false -> {:error, :col_out_of_range}
    end
  end

  @doc """
  Delete up to `count` graphemes starting at `{row, col}` within one line
  (clamped to the line end). Returns `{:ok, doc}` or `{:error, reason}`.
  """
  @spec delete(t(), pos(), non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def delete(%__MODULE__{lines: lines} = doc, {row, col}, count)
      when is_integer(row) and is_integer(col) and is_integer(count) and count >= 0 do
    with {:ok, graphemes} <- fetch_graphemes(lines, row),
         true <- col >= 0 and col <= length(graphemes) do
      {pre, rest} = Enum.split(graphemes, col)
      new_line = Enum.join(pre ++ Enum.drop(rest, count))
      {:ok, %__MODULE__{doc | lines: List.replace_at(lines, row, new_line)}}
    else
      {:error, _} = e -> e
      false -> {:error, :col_out_of_range}
    end
  end

  # --- helpers ---

  defp fetch_graphemes(lines, row) do
    case Enum.at(lines, row) do
      nil -> {:error, :row_out_of_range}
      line when is_binary(line) -> {:ok, String.graphemes(line)}
    end
  end

  # Splice inserted parts between the `pre` and `post` halves of the split line.
  defp splice([only], pre, post), do: [pre <> only <> post]

  defp splice([first | rest], pre, post) do
    {mids, [last]} = Enum.split(rest, length(rest) - 1)
    [pre <> first | mids] ++ [last <> post]
  end
end
