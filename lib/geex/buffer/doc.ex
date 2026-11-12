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
  The **byte** offset of the caret at grapheme position `{row, col}` — the number of
  bytes in `text/1` that precede it. The dual of the grapheme `{row, col}` the cursor
  and commands use; tree-sitter / `Geex.Highlight.Span` are byte-oriented, so this is
  the bridge for mapping an edit to the byte span it touched.

  `row`/`col` are clamped to the document, and a `\\n` counts as one byte between lines.
  """
  @spec byte_offset(t(), pos()) :: non_neg_integer()
  def byte_offset(%__MODULE__{lines: lines}, {row, col}) do
    row = row |> max(0) |> min(length(lines) - 1)
    prefix = lines |> Enum.take(row) |> Enum.reduce(0, fn l, acc -> acc + byte_size(l) + 1 end)

    {pre, _post} = lines |> Enum.at(row, "") |> split_col(max(col, 0))
    prefix + byte_size(pre)
  end

  @doc """
  Insert `text` at `{row, col}`. `text` may contain newlines, which split the
  line. Returns `{:ok, doc}` or `{:error, :row_out_of_range | :col_out_of_range}`.
  """
  @spec insert(t(), pos(), String.t()) :: {:ok, t()} | {:error, atom()}
  def insert(%__MODULE__{lines: lines} = doc, {row, col}, text)
      when is_integer(row) and is_integer(col) and is_binary(text) do
    with {:ok, line} <- fetch_line(lines, row),
         {:ok, pre, post} <- split_at_col(line, col) do
      new_lines = splice(String.split(text, "\n"), pre, post)

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
    with {:ok, line} <- fetch_line(lines, row),
         {:ok, pre, rest} <- split_at_col(line, col) do
      {_gone, kept} = split_col(rest, count)
      new_line = pre <> kept
      {:ok, %__MODULE__{doc | lines: List.replace_at(lines, row, new_line)}}
    else
      {:error, _} = e -> e
      false -> {:error, :col_out_of_range}
    end
  end

  @doc """
  Replace the (grapheme-indexed, 0-based) range `{{r1, c1}, {r2, c2}}` with `text`,
  which may be empty or contain newlines. The general range edit: an empty range is a
  point insert, an empty `text` is a (multi-line) delete, otherwise an edit. Start must
  not be after end. Returns `{:ok, doc}` or `{:error, :range_reversed |
  :row_out_of_range | :col_out_of_range}`.
  """
  @spec replace(t(), {pos(), pos()}, String.t()) :: {:ok, t()} | {:error, atom()}
  def replace(%__MODULE__{lines: lines} = doc, {{r1, c1} = from, {r2, c2} = to}, text)
      when is_integer(r1) and is_integer(c1) and is_integer(r2) and is_integer(c2) and
             is_binary(text) do
    with :ok <- ordered(from, to),
         {:ok, start_line} <- fetch_line(lines, r1),
         {:ok, end_line} <- fetch_line(lines, r2),
         {:ok, prefix, _} <- split_at_col(start_line, c1),
         {:ok, _, suffix} <- split_at_col(end_line, c2) do
      middle = splice(String.split(text, "\n"), prefix, suffix)
      replaced = Enum.take(lines, r1) ++ middle ++ Enum.drop(lines, r2 + 1)
      {:ok, %__MODULE__{doc | lines: replaced}}
    else
      {:error, _} = e -> e
      false -> {:error, :col_out_of_range}
    end
  end

  @doc """
  The text in the (grapheme-indexed, 0-based) **half-open** range `{{r1, c1}, {r2, c2}}`
  — the read-only sibling of `replace/3` (same range model, so `slice` then `replace`
  with `""` is a cut). The grapheme at the start caret is included, the one at the end is
  not; an empty range yields `""`. Returns `{:ok, text}` or the same `{:error, …}` as
  `replace/3`. This is what `copy`/`cut` read ([ADR-0029](../../../doc/adr/0029-selection-primitive.md)).
  """
  @spec slice(t(), {pos(), pos()}) :: {:ok, String.t()} | {:error, atom()}
  def slice(%__MODULE__{lines: lines}, {{r1, c1} = from, {r2, c2} = to})
      when is_integer(r1) and is_integer(c1) and is_integer(r2) and is_integer(c2) do
    with :ok <- ordered(from, to),
         {:ok, start_line} <- fetch_line(lines, r1),
         {:ok, end_line} <- fetch_line(lines, r2),
         {:ok, _, first} <- split_at_col(start_line, c1),
         {:ok, last, _} <- split_at_col(end_line, c2) do
      text =
        if r1 == r2 do
          first |> split_col(c2 - c1) |> elem(0)
        else
          middle = Enum.slice(lines, r1 + 1, r2 - r1 - 1)
          Enum.join([first | middle] ++ [last], "\n")
        end

      {:ok, text}
    else
      {:error, _} = e -> e
      false -> {:error, :col_out_of_range}
    end
  end

  # --- helpers ---

  defp ordered(from, to) when from <= to, do: :ok
  defp ordered(_from, _to), do: {:error, :range_reversed}

  defp fetch_line(lines, row) do
    case Enum.at(lines, row) do
      nil -> {:error, :row_out_of_range}
      line when is_binary(line) -> {:ok, line}
    end
  end

  # `line`'s first `col` graphemes and the rest, `{:ok, pre, post}`, or
  # `{:error, :col_out_of_range}` when `col` is negative or past the line's end.
  defp split_at_col(_line, col) when col < 0, do: {:error, :col_out_of_range}

  defp split_at_col(line, col) do
    {pre, post} = split_col(line, col)

    if post != "" or Geex.Text.length(pre) == col,
      do: {:ok, pre, post},
      else: {:error, :col_out_of_range}
  end

  # The first `col` graphemes of `line` (all of it when shorter) and the rest, without splitting
  # the whole of a long line into graphemes (BUG-13): an ASCII prefix is cut by its bytes (the
  # byte at `col` ASCII too, so no combining mark there belongs to the grapheme before it), any
  # other walked by `String.split_at/2`.
  defp split_col(line, col) do
    if col <= byte_size(line) and ascii_prefix?(line, col + 1),
      do: {binary_part(line, 0, col), binary_part(line, col, byte_size(line) - col)},
      else: Geex.Text.split_at(line, col)
  end

  defp ascii_prefix?(line, k), do: Geex.Ascii.prefix?(line, k)

  # Splice inserted parts between the `pre` and `post` halves of the split line.
  defp splice([only], pre, post), do: [pre <> only <> post]

  defp splice([first | rest], pre, post) do
    {mids, [last]} = Enum.split(rest, length(rest) - 1)
    [pre <> first | mids] ++ [last <> post]
  end
end
