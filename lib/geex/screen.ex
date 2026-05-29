defmodule Geex.Screen do
  @moduledoc """
  A virtual 2D cell grid.

  Pure data: `%Screen{w, h, cells}` where `cells` is a map keyed by
  `{x, y}` tuples (0-indexed, origin top-left). Out-of-bounds writes
  are silently dropped — components don't need to clip; the screen
  enforces its own edges.

  Primitives are minimal and composable: `set_cell/4` is the single
  write; `draw_text/5` and `fill_rect/6` build on it. Add new ones
  here only when they're shared across multiple components.

  Reads default to `Geex.Cell.blank/0` for unset coordinates, so a
  freshly-allocated screen presents as a uniform field of blanks even
  though `cells` is empty.

  The choice of a sparse map (vs. tuple-of-tuples or `:array`) keeps
  the API straightforward and resize cheap; if profiling later shows
  the hash-map overhead is a bottleneck the backing store can change
  behind the same public functions.
  """

  alias Geex.Cell

  defstruct w: 0, h: 0, cells: %{}

  @type t :: %__MODULE__{
          w: non_neg_integer(),
          h: non_neg_integer(),
          cells: %{optional({non_neg_integer(), non_neg_integer()}) => Cell.t()}
        }

  @doc "A blank screen of the given dimensions."
  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(w, h) when w >= 0 and h >= 0, do: %__MODULE__{w: w, h: h, cells: %{}}

  @doc """
  Resize to `{w, h}`, dropping any cells that fall outside the new
  bounds. Cells inside the new bounds are preserved.
  """
  @spec resize(t(), non_neg_integer(), non_neg_integer()) :: t()
  def resize(%__MODULE__{} = s, w, h) when w >= 0 and h >= 0 do
    cells =
      for {{x, y} = coord, cell} <- s.cells, x < w, y < h, into: %{} do
        {coord, cell}
      end

    %{s | w: w, h: h, cells: cells}
  end

  @doc """
  Read the cell at `{x, y}`. Returns `Geex.Cell.blank/0` for unset or
  out-of-bounds coordinates — there is no `nil` cell.
  """
  @spec get_cell(t(), integer(), integer()) :: Cell.t()
  def get_cell(%__MODULE__{} = s, x, y) do
    if in_bounds?(s, x, y) do
      Map.get(s.cells, {x, y}, Cell.blank())
    else
      Cell.blank()
    end
  end

  @doc """
  Write a cell at `{x, y}`. Out-of-bounds writes are silently dropped.
  Writing a blank cell removes the entry from `cells`, keeping the
  sparse representation tight.
  """
  @spec set_cell(t(), integer(), integer(), Cell.t()) :: t()
  def set_cell(%__MODULE__{} = s, x, y, %Cell{} = cell) do
    cond do
      not in_bounds?(s, x, y) -> s
      cell == Cell.blank() -> %{s | cells: Map.delete(s.cells, {x, y})}
      true -> %{s | cells: Map.put(s.cells, {x, y}, cell)}
    end
  end

  @doc """
  Draw `text` starting at `{x, y}`, advancing one column per grapheme.
  Style fields default to a plain cell; pass a partial cell to apply
  colours/attrs uniformly across the run.

  Stops at the right edge of the screen (no wrapping). Newlines in the
  text are not interpreted — pass per-line strings.
  """
  @spec draw_text(t(), integer(), integer(), String.t(), Cell.t()) :: t()
  def draw_text(%__MODULE__{} = s, x, y, text, style \\ Cell.blank()) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(s, fn {g, i}, acc ->
      set_cell(acc, x + i, y, %{style | char: g})
    end)
  end

  @doc """
  Fill the rectangle `{x, y, w, h}` with `cell`. Coordinates outside
  the screen are clipped.
  """
  @spec fill_rect(t(), integer(), integer(), non_neg_integer(), non_neg_integer(), Cell.t()) ::
          t()
  def fill_rect(%__MODULE__{} = s, x, y, w, h, %Cell{} = cell) do
    Enum.reduce(y..(y + h - 1)//1, s, fn row, acc ->
      Enum.reduce(x..(x + w - 1)//1, acc, fn col, acc2 ->
        set_cell(acc2, col, row, cell)
      end)
    end)
  end

  @doc "Clear the screen — every cell becomes blank."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = s), do: %{s | cells: %{}}

  @doc false
  @spec in_bounds?(t(), integer(), integer()) :: boolean()
  def in_bounds?(%__MODULE__{w: w, h: h}, x, y),
    do: x >= 0 and y >= 0 and x < w and y < h
end
