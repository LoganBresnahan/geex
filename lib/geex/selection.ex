defmodule Geex.Selection do
  @moduledoc """
  A **selection**: a directional span of the buffer between an `anchor` and an
  `active` end, both `{line, col}` grapheme carets (the same coordinate space as
  the view cursor, [ADR-0014](../../doc/adr/0014-editor-state-and-dispatch-ownership.md)).

  This is the **pure primitive** under two surfaces that pick a region
  ([ADR-0029](../../doc/adr/0029-selection-primitive.md)):

    * **interactively** — highlight mode anchors at the cursor and `extend/2`s the
      `active` end as the user moves (the human surface);
    * **declaratively** — grid coordinates ([ADR-0027](../../doc/adr/0027-grid-command-addressing.md))
      resolve to the same span (the typed / agent surface).

  Both build *this* value, so copy/cut/paste and grid ops share one notion of
  "the region". The selection is **directional** (the `active` end may sit before
  or after the `anchor`), but its `range/1` is the two carets in **document order**.

  ## Caret / position semantics (not grapheme-inclusive)

  `range/1` returns ordered **carets** — positions *between* graphemes — so the
  span is **half-open** `[start, end)`: the grapheme at `start` is included, the
  one at `end` is not. This matches `Geex.Buffer.Doc.replace/3`'s existing range
  argument (a `{{r1,c1},{r2,c2}}` position pair, where an empty range is a point
  insert), so a selection feeds the edit primitives directly. It is **not** the
  grid notation's inclusive convention (`x5 - x12` includes `x12`); that lives in
  the eventual `Geex.Coord.to_span/2`, which converts inclusive *notation* into the
  same half-open *position* span. The two surfaces converge here.

  Pure and buffer-agnostic: it never reads a `Doc`. "Select all" is just a caller
  constructing a selection over the whole buffer (`new({0,0}) |> extend(last)`).
  """

  @type pos :: {non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{anchor: pos(), active: pos()}

  @enforce_keys [:anchor, :active]
  defstruct [:anchor, :active]

  @doc "A new, collapsed selection at `pos` (anchor == active — nothing selected yet)."
  @spec new(pos()) :: t()
  def new({line, col} = pos) when is_integer(line) and is_integer(col),
    do: %__MODULE__{anchor: pos, active: pos}

  @doc "Move the `active` end to `pos`, leaving the `anchor` fixed (interactive extend)."
  @spec extend(t(), pos()) :: t()
  def extend(%__MODULE__{} = sel, {line, col} = pos) when is_integer(line) and is_integer(col),
    do: %{sel | active: pos}

  @doc "The fixed end."
  @spec anchor(t()) :: pos()
  def anchor(%__MODULE__{anchor: a}), do: a

  @doc "The moving end (tracks the cursor)."
  @spec active(t()) :: pos()
  def active(%__MODULE__{active: b}), do: b

  @doc "True when nothing is selected (anchor == active)."
  @spec collapsed?(t()) :: boolean()
  def collapsed?(%__MODULE__{anchor: a, active: b}), do: a == b

  @doc """
  The selection as an ordered, half-open caret span `{start, end}` with
  `start <= end` in document order — ready for `Doc.replace/3` / a future
  `Doc.slice/2`. A collapsed selection yields `{p, p}` (an empty span).

  `{line, col}` tuples compare lexicographically, which *is* document order, so the
  ordering is a plain `<=`.
  """
  @spec range(t()) :: {pos(), pos()}
  def range(%__MODULE__{anchor: a, active: b}), do: if(a <= b, do: {a, b}, else: {b, a})

  @doc """
  Whether `pos` falls inside the selection — within the half-open span `[start, end)`.
  The grapheme at the `end` caret is *not* contained; a collapsed selection contains
  nothing. Useful for painting the selection highlight cell-by-cell.
  """
  @spec contains?(t(), pos()) :: boolean()
  def contains?(%__MODULE__{} = sel, pos) do
    {s, e} = range(sel)
    s <= pos and pos < e
  end
end
