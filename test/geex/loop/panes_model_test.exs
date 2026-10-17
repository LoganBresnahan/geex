defmodule Geex.Loop.PanesModelTest do
  # The pure panes-and-tabs model behind split panes (ADR-0038).
  use ExUnit.Case, async: true

  alias Geex.Loop.Panes

  # Stand-in buffer pids: the model only compares them.
  setup do
    [a, b, c] = for _ <- 1..3, do: spawn(fn -> :ok end)
    %{a: a, b: b, c: c}
  end

  defp shown_buffers(ps), do: for(id <- Panes.ids(ps), t = Panes.shown(ps, id), do: t.buffer)

  test "show opens a tab at the end, or switches to the existing one", %{a: a, b: b} do
    {ps, :new} = Panes.show(Panes.new(), a, {3, 1})
    {ps, :new} = Panes.show(ps, b)
    assert Panes.current(ps).buffer == b
    {ps, :existing} = Panes.show(ps, a)
    assert %{buffer: ^a, cursor: {3, 1}} = Panes.current(ps)
    assert length(ps.panes[1].tabs) == 2
  end

  test "step wraps; select ignores out-of-range", %{a: a, b: b, c: c} do
    ps = Enum.reduce([a, b, c], Panes.new(), fn buf, acc -> acc |> Panes.show(buf) |> elem(0) end)
    assert Panes.current(Panes.step(ps, 1)).buffer == a
    assert Panes.current(Panes.step(ps, -1)).buffer == b
    assert Panes.select(ps, 7) == ps
    assert Panes.current(Panes.select(ps, 0)).buffer == a
  end

  test "split copies the tab into a new current pane, in reading order", %{a: a, b: b} do
    {ps, _} = Panes.show(Panes.new(), a, {5, 0})
    ps = Panes.split(ps, :cols)
    assert ps.split == {:cols, {:pane, 1}, {:pane, 2}, 0.5}
    assert ps.pane == 2
    assert %{buffer: ^a, cursor: {5, 0}} = Panes.current(ps)

    ps = ps |> Panes.focus(1) |> Panes.split(:rows)
    assert Panes.ids(ps) == [1, 3, 2]
    {ps, _} = Panes.show(ps, b)
    assert shown_buffers(ps) == [a, b, a]
  end

  test "closing a pane's last tab closes the pane; its sibling takes over", %{a: a, b: b} do
    {ps, _} = Panes.show(Panes.new(), a)
    ps = Panes.split(ps, :cols)
    {ps, _} = Panes.show(ps, b)
    ps = Panes.close_tab(ps)
    assert Panes.current(ps).buffer == a
    assert ps.pane == 2

    ps = Panes.close_tab(ps)
    assert ps.split == {:pane, 1}
    assert ps.pane == 1
  end

  test "the only pane stays when its last tab closes", %{a: a} do
    {ps, _} = Panes.show(Panes.new(), a)
    ps = Panes.close_tab(ps)
    assert ps.panes == %{1 => %{tabs: [], at: 0}}
    assert Panes.current(ps) == nil
  end

  test "a buffer that ends leaves every pane; emptied panes close", %{a: a, b: b} do
    {ps, _} = Panes.show(Panes.new(), a)
    {ps, _} = Panes.show(ps, b)
    ps = Panes.split(ps, :rows)
    ps = Panes.drop_buffer(ps, b)
    assert ps.split == {:pane, 1}
    assert Panes.current(ps).buffer == a
    assert Panes.buffers(ps) == MapSet.new([a])
  end

  test "a buffer that ends while shown leaves the pane on the tab before it", %{a: a, b: b, c: c} do
    ps = Enum.reduce([a, b, c], Panes.new(), fn buf, acc -> acc |> Panes.show(buf) |> elem(0) end)
    ps = Panes.select(ps, 1)
    assert Panes.current(Panes.drop_buffer(ps, b)).buffer == a
    assert Panes.current(Panes.drop_buffer(ps, a)).buffer == b
    assert Panes.current(Panes.drop_buffer(ps, c)).buffer == b
  end

  test "a pane with no tabs isn't split" do
    assert Panes.split(Panes.new(), :cols) == Panes.new()
  end

  test "elsewhere? sees the same buffer in another tab or pane", %{a: a, b: b} do
    {ps, _} = Panes.show(Panes.new(), a)
    refute Panes.elsewhere?(ps, a)
    ps = Panes.split(ps, :cols)
    assert Panes.elsewhere?(ps, a)
    {ps, _} = Panes.show(ps, b)
    refute Panes.elsewhere?(ps, b)
  end
end
