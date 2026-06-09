defmodule Geex.Coord do
  @moduledoc """
  A **grid coordinate** and its resolution to a buffer span
  ([ADR-0027](../../doc/adr/0027-grid-command-addressing.md)).

  A coordinate is two **1-based** integers, `x` then `y`: `x5 y7` = column 5, line 7.
  Pure and view-free — `x` is a **grapheme** index within the logical line and `y` is a
  **logical** (`\\n`-split) line, the same axes `Geex.Buffer.Doc` and the cursor use, so the
  addresser and the editor share one model and a width-table change can only ever mis-*render*
  a line, never mis-*address* an edit (ADR-0027 §2).

  The human picking surface enters coordinates in **display columns** (what the ruler shows);
  the transport casts those to grapheme `x` ([`Geex.Width.col_at_display/2`](`Geex.Width`)) before
  calling `to_span/2` / `to_caret/2` — so this module only ever sees grapheme coordinates.

  Ranges are **inclusive** at both ends (`x5 y7 - x12 y9` includes the `x12` grapheme), `-`
  for a linear range (`:` blocks / `,` lists deferred). `to_span/2` converts the inclusive
  *notation* into the **half-open** caret span `Geex.Buffer.Doc.slice/2` / `replace/3` take
  (the same convention `Geex.Selection` produces) — the two surfaces converge there.
  """

  alias Geex.Buffer.Doc

  @enforce_keys [:x, :y]
  defstruct [:x, :y]

  @type t :: %__MODULE__{x: pos_integer(), y: pos_integer()}
  @type pos :: {non_neg_integer(), non_neg_integer()}

  defmodule Range do
    @moduledoc "A linear coordinate range, `from`–`to` inclusive (ADR-0027 §7)."
    @enforce_keys [:from, :to]
    defstruct [:from, :to, kind: :linear]
    @type t :: %__MODULE__{from: Geex.Coord.t(), to: Geex.Coord.t(), kind: :linear}
  end

  @doc """
  Parse the coordinate surface: `"x5 y7"` → a `Coord`, `"x5 y7 - x12 y9"` → a `Range`.
  Case-insensitive, whitespace-tolerant. `x`/`y` are 1-based, so `0` or a sign is rejected.
  A **reversed** range (`to` before `from` in document order) and an **empty** range
  (`from == to`) are errors at parse (ADR-0027 §7). Returns `{:error, reason}` otherwise.
  """
  @spec parse(String.t()) :: {:ok, t() | Range.t()} | {:error, atom()}
  def parse(input) when is_binary(input) do
    case input |> String.trim() |> String.downcase() |> String.split("-", parts: 2) do
      [one] -> parse_coord(one)
      [a, b] -> parse_range(a, b)
    end
  end

  defp parse_range(a, b) do
    with {:ok, from} <- parse_coord(a),
         {:ok, to} <- parse_coord(b) do
      cond do
        from == to -> {:error, :empty_range}
        before?(from, to) -> {:ok, %Range{from: from, to: to}}
        true -> {:error, :reversed}
      end
    end
  end

  defp parse_coord(s) do
    case Regex.run(~r/^\s*x(\d+)\s+y(\d+)\s*$/, s) do
      [_, xs, ys] ->
        x = String.to_integer(xs)
        y = String.to_integer(ys)
        if x >= 1 and y >= 1, do: {:ok, %__MODULE__{x: x, y: y}}, else: {:error, :bad_coord}

      _ ->
        {:error, :bad_coord}
    end
  end

  # Document order is {line, col} = {y, x}.
  defp before?(%__MODULE__{x: x1, y: y1}, %__MODULE__{x: x2, y: y2}), do: {y1, x1} < {y2, x2}

  @doc """
  Resolve a single coordinate to a **grapheme caret** `{line, col}` (0-based) in `doc`, for a
  cursor jump (`goto`). `x` past the line end **clamps** to the line end (ADR-0027 §7); `y`
  past EOF is a hard `{:error, :line_out_of_range}`.
  """
  @spec to_caret(t(), Doc.t()) :: {:ok, pos()} | {:error, :line_out_of_range}
  def to_caret(%__MODULE__{x: x, y: y}, %Doc{lines: lines}) do
    if y > length(lines) do
      {:error, :line_out_of_range}
    else
      {:ok, {y - 1, min(x - 1, line_len(lines, y - 1))}}
    end
  end

  @doc """
  Resolve a `Range` to an **ordered, half-open** grapheme caret span `{from, to}` in `doc` —
  ready for `Doc.slice/2` / `Doc.replace/3`. The inclusive `to` grapheme becomes the caret
  *after* it; `x` past a line end clamps to that line's end; `y` past EOF is
  `{:error, :line_out_of_range}`. (The range was already ordered + non-empty at parse.)
  """
  @spec to_span(Range.t(), Doc.t()) :: {:ok, {pos(), pos()}} | {:error, :line_out_of_range}
  def to_span(%Range{from: %__MODULE__{x: x1, y: y1}, to: %__MODULE__{x: x2, y: y2}}, %Doc{
        lines: lines
      }) do
    n = length(lines)

    if y1 > n or y2 > n do
      {:error, :line_out_of_range}
    else
      from = {y1 - 1, min(x1 - 1, line_len(lines, y1 - 1))}
      # Inclusive end: the x2-th grapheme (0-based x2-1) is included, so the half-open caret
      # sits at x2 — clamped to the line end ("to end of line" when x2 overruns).
      to = {y2 - 1, min(x2, line_len(lines, y2 - 1))}
      {:ok, {from, to}}
    end
  end

  defp line_len(lines, row), do: lines |> Enum.at(row, "") |> String.length()
end
