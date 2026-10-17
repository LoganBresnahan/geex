defmodule Geex.Loop.TabBar do
  @moduledoc """
  Where things are on a file pane's tab bar ([ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md)
  §5, [ADR-0039](../../../doc/adr/0039-mouse.md)): each tab's label and its `×`, and the pane's
  own `×` at the right end. Pure, so drawing and a click read the same layout.

  A tab reads ` N name × `: its number (`Alt+N`), its file name (with ` [+]` for unsaved edits),
  and a `×` that closes it. When the pane can close (it isn't the only one), the bar's last three
  columns are ` × `, which closes the pane. Tabs that don't fit are cut from the left so the shown
  one stays visible.
  """

  alias Geex.Width

  @pane_close " × "

  @type t :: %{
          tabs: [%{i: non_neg_integer(), x: non_neg_integer(), label: String.t()}],
          close: non_neg_integer() | nil,
          w: non_neg_integer()
        }

  @doc """
  The bar for tabs named `names`, tab `at` shown, `w` columns wide; `closable?` when the pane
  has its own `×`. Each tab's `x` is from the bar's left edge.

      iex> bar = Geex.Loop.TabBar.layout(["a.txt", "b.txt [+]"], 0, 40, true)
      iex> Enum.map(bar.tabs, &{&1.i, &1.x, &1.label})
      [{0, 0, " 1 a.txt × "}, {1, 11, " 2 b.txt [+] × "}]
      iex> bar.close
      37
  """
  @spec layout([String.t()], non_neg_integer(), non_neg_integer(), boolean()) :: t()
  def layout(names, at, w, closable?) do
    room = if closable?, do: max(w - Width.string(@pane_close), 0), else: w

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
      w: room
    }
  end

  @doc "What the bar's column `x` is: a tab, a tab's `×`, the pane's `×`, or nothing."
  @spec hit(t(), integer()) ::
          {:tab, non_neg_integer()} | {:close_tab, non_neg_integer()} | :close_pane | nil
  def hit(%{close: close}, x) when is_integer(close) and x >= close, do: :close_pane

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

  @doc "The pane's `×`, as drawn in the bar's last three columns."
  @spec pane_close() :: String.t()
  def pane_close, do: @pane_close

  # Drop tabs from the left while the shown one would end past the room.
  defp drop_until_fits([{i, label} | rest], at, shown_end, room) when shown_end > room and i < at,
    do: drop_until_fits(rest, at, shown_end - Width.string(label), room)

  defp drop_until_fits(labels, _at, _shown_end, _room), do: labels
end
