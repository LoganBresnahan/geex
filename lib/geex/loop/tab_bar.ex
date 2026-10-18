defmodule Geex.Loop.TabBar do
  @moduledoc """
  Where things are on a file pane's tab bar ([ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md)
  §5, [ADR-0039](../../../doc/adr/0039-mouse.md)): each tab's label and its `×`, and the pane's
  own `×` at the right end. Pure, so drawing and a click read the same layout.

  A tab reads ` N name × `: its number (`Alt+N`), its file name (with ` [+]` for unsaved edits),
  and a `×` that closes it. When the pane can close (it isn't the only one), the bar's last three
  columns are ` × `, which closes the pane. When the bar is the top of a stacked split's lower
  half, it keeps two columns for the split's handle (`handle(:rows)`), just before the pane's `×` ([ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md)
  §6), so the split can be dragged however many tabs there are. Tabs that don't fit are cut from
  the left so the shown one stays visible.
  """

  alias Geex.Width

  @pane_close " × "

  # The handles' glyphs (ADR-0038 §6): one per direction an edge moves, the same grip turned, 4
  # dots along the edge and 2 across. Each braille cell is one column in any font (not East
  # Asian ambiguous width). Swap them here.
  @handle_cols "⣿"
  @handle_rows "⠛⠛"

  @type t :: %{
          tabs: [%{i: non_neg_integer(), x: non_neg_integer(), label: String.t()}],
          close: non_neg_integer() | nil,
          handle: non_neg_integer() | nil,
          w: non_neg_integer()
        }

  @doc """
  The bar for tabs named `names`, tab `at` shown, `w` columns wide; `closable?` when the pane
  has its own `×`; `handle?` when it keeps a split's handle. Each tab's `x` is from the bar's left
  edge.

      iex> bar = Geex.Loop.TabBar.layout(["a.txt", "b.txt [+]"], 0, 40, true)
      iex> Enum.map(bar.tabs, &{&1.i, &1.x, &1.label})
      [{0, 0, " 1 a.txt × "}, {1, 11, " 2 b.txt [+] × "}]
      iex> {bar.close, bar.handle}
      {37, nil}
      iex> Geex.Loop.TabBar.layout(["a.txt"], 0, 40, true, true).handle
      35
  """
  @spec layout([String.t()], non_neg_integer(), non_neg_integer(), boolean(), boolean()) :: t()
  def layout(names, at, w, closable?, handle? \\ false) do
    room = if closable?, do: max(w - Width.string(@pane_close), 0), else: w
    handle = if handle? and room >= 2, do: room - 2
    room = if handle, do: handle, else: room

    labels =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, i} -> {i, " #{i + 1} " <> name <> " × "} end)

    shown_end = labels |> Enum.take(at + 1) |> Enum.map(&Width.string(elem(&1, 1))) |> Enum.sum()
    labels = drop_until_fits(labels, at, shown_end, room)

    {tabs, _x} =
      Enum.map_reduce(labels, 0, fn {i, label}, x ->
        {%{i: i, x: x, label: label}, x + Width.string(label)}
      end)

    %{
      tabs: Enum.filter(tabs, &(&1.x < room)),
      close: if(closable? and w >= Width.string(@pane_close), do: w - 3),
      handle: handle,
      w: room
    }
  end

  @doc """
  What the bar's column `x` is: a tab, a tab's `×`, the pane's `×`, the split's handle (and the
  space after it), or nothing.
  """
  @spec hit(t(), integer()) ::
          {:tab, non_neg_integer()}
          | {:close_tab, non_neg_integer()}
          | :close_pane
          | :handle
          | nil
  def hit(%{close: close}, x) when is_integer(close) and x >= close, do: :close_pane
  def hit(%{handle: h}, x) when is_integer(h) and x in h..(h + 1)//1, do: :handle

  def hit(%{tabs: tabs, w: room}, x) when x < room do
    Enum.find_value(tabs, fn %{i: i, x: tx, label: label} ->
      lw = Width.string(label)

      cond do
        x < tx or x >= tx + lw -> nil
        # The `×` and the space after it.
        x >= tx + lw - 2 -> {:close_tab, i}
        true -> {:tab, i}
      end
    end)
  end

  def hit(_bar, _x), do: nil

  @doc """
  A handle's glyph, by the way its edge moves: `:cols` for an edge dragged left and right (a
  side-by-side divider, the tree's edge), `:rows` for one dragged up and down (a stacked split's
  bar, the edits pane's title). The `:rows` glyph is two columns: the handle and the space after
  it, the hit area a bar keeps.

      iex> {Geex.Loop.TabBar.handle(:cols), Geex.Loop.TabBar.handle(:rows)}
      {"⣿", "⠛⠛"}
  """
  @spec handle(:cols | :rows) :: String.t()
  def handle(:cols), do: @handle_cols
  def handle(:rows), do: @handle_rows

  @doc "The pane's `×`, as drawn in the bar's last three columns."
  @spec pane_close() :: String.t()
  def pane_close, do: @pane_close

  # Drop tabs from the left while the shown one would end past the room.
  defp drop_until_fits([{i, label} | rest], at, shown_end, room) when shown_end > room and i < at,
    do: drop_until_fits(rest, at, shown_end - Width.string(label), room)

  defp drop_until_fits(labels, _at, _shown_end, _room), do: labels
end
