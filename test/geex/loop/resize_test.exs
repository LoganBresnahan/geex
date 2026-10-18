defmodule Geex.Loop.ResizeTest do
  # Resizing with the mouse (ADR-0039 step 3, ADR-0038's amendment): the split handles, the tree's
  # edge and the edits pane's title row, through the loop's own handle_info/2 with no terminal.
  # Uses the global Session and Renderer, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Layout, Loop, Screen, Session}
  alias Geex.Loop.Panes

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_resize_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    for f <- ["a.txt", "b.txt"], do: File.write!(Path.join(dir, f), "#{f}\nline 2\n")
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp send_io(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp mouse(action, x, y), do: {:mouse, %{action: action, button: :left, x: x, y: y, mods: []}}

  # Press at `from`, drag to `to`, let go.
  defp drag(state, {x0, y0}, {x1, y1}) do
    %{state | click: nil}
    |> send_io(mouse(:press, x0, y0))
    |> send_io(mouse(:drag, x1, y1))
    |> send_io(mouse(:release, x1, y1))
  end

  defp double(state, {x, y}) do
    %{state | click: nil}
    |> send_io(mouse(:press, x, y))
    |> send_io(mouse(:release, x, y))
    |> send_io(mouse(:press, x, y))
    |> send_io(mouse(:release, x, y))
  end

  defp frame(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    %Screen{} = screen = Geex.Renderer.current()

    rows =
      for y <- 0..(screen.h - 1),
          do: Enum.map_join(0..(screen.w - 1), &Screen.get_cell(screen, &1, y).char)

    {state, rows}
  end

  defp panes(state) do
    l = Layout.resolve(state.w, state.h, %{tree: false, edits: false})
    for {id, r} <- Layout.split(l.editor, state.panes.split), do: {id, {r.w, r.h}}
  end

  # 120 × 30, tree and edits hidden: the editor is columns 0–119, rows 0–28.
  defp start(dir) do
    state = %{Loop.new_state(120, 30) | tree_shown: false, edits_shown: false}
    {:ok, pid} = Session.open_file(Path.join(dir, "a.txt"))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    state
  end

  test "dragging a side-by-side divider moves it; the ratio survives a terminal resize",
       %{dir: dir} do
    state = start(dir) |> send_io({:alt, ?=})
    # Even: 59 | divider at 59 | 60.
    assert panes(state) == [{1, {59, 29}}, {2, {60, 29}}]

    state = drag(state, {59, 10}, {39, 10})
    assert panes(state) == [{1, {39, 29}}, {2, {80, 29}}]
    assert state.resizing == nil

    # Half as wide: about the same third.
    {:noreply, state} = Loop.handle_info({:geex_io, {:resize, 30, 60}}, state)
    assert [{1, {19, 29}}, {2, {40, 29}}] = panes(state)
  end

  test "a split is kept to the least pane size; a double-click puts it back to even",
       %{dir: dir} do
    state = start(dir) |> send_io({:alt, ?=})
    state = drag(state, {59, 10}, {2, 10})
    assert [{1, {12, 29}}, _] = panes(state)
    state = drag(state, {12, 10}, {119, 10})
    assert [_, {2, {12, 29}}] = panes(state)

    state = double(state, {107, 10})
    assert panes(state) == [{1, {59, 29}}, {2, {60, 29}}]
  end

  test "a stacked split's handle is the lower tab bar's blank part; its tabs still click",
       %{dir: dir} do
    state = start(dir) |> send_io({:alt, ?-})
    # Even: rows 0–13 and 14–28; pane 2's tab bar is row 14.
    assert panes(state) == [{1, {120, 14}}, {2, {120, 15}}]
    state = drag(state, {60, 14}, {60, 20})
    assert panes(state) == [{1, {120, 20}}, {2, {120, 9}}]

    # Its tab: a click shows it, and resizes nothing.
    state = send_io(state, {:alt, ?p})
    assert state.panes.pane == 1
    state = drag(state, {3, 20}, {3, 25})
    assert state.panes.pane == 2
    assert panes(state) == [{1, {120, 20}}, {2, {120, 9}}]
  end

  test "a nested split's handle moves only its own boundary", %{dir: dir} do
    # 1 | (2 / 3): the inner boundary is pane 3's tab bar, row 14, columns 60–119.
    state = start(dir) |> send_io({:alt, ?=}) |> send_io({:alt, ?-})
    assert panes(state) == [{1, {59, 29}}, {2, {60, 14}}, {3, {60, 15}}]
    state = drag(state, {90, 14}, {90, 8})
    assert panes(state) == [{1, {59, 29}}, {2, {60, 8}}, {3, {60, 21}}]
    # The outer divider is untouched; the ratios ride on the split.
    assert {:cols, {:pane, 1}, {:rows, {:pane, 2}, {:pane, 3}, r}, 0.5} = state.panes.split
    assert r < 0.5
  end

  test "the handles are drawn", %{dir: dir} do
    state = start(dir) |> send_io({:alt, ?=}) |> send_io({:alt, ?-})
    {_state, rows} = frame(state)
    # The divider's middle, and on the stacked split's row, the blank cell nearest its middle.
    assert String.at(Enum.at(rows, 14), 59) == "⠿"
    assert String.at(Enum.at(rows, 14), 60 + 55) == "⠿"
  end

  describe "the tree and the edits pane" do
    # 120 × 30 with both shown: the tree is columns 0–29 (its edge at 29), the edits pane rows
    # 20–28 (its title on row 20).
    defp start_panels(dir) do
      %{start(dir) | tree_shown: true, edits_shown: true}
    end

    defp sizes(state) do
      l =
        Layout.resolve(state.w, state.h, %{
          tree: true,
          edits: true,
          tree_w: state.tree_w,
          edits_h: state.edits_h
        })

      {l.tree.w, l.edits.h}
    end

    test "dragging the tree's edge resizes it; a double-click puts it back", %{dir: dir} do
      state = start_panels(dir)
      assert sizes(state) == {30, 9}
      state = drag(state, {29, 10}, {49, 10})
      assert {state.tree_w, sizes(state)} == {50, {50, 9}}
      # Kept to leave the editor 40 columns.
      state = drag(state, {49, 10}, {115, 10})
      assert state.tree_w == 80
      state = double(state, {79, 3})
      assert {state.tree_w, sizes(state)} == {nil, {30, 9}}
    end

    test "dragging the edits pane's title resizes it, and focuses it", %{dir: dir} do
      state = start_panels(dir)
      state = drag(state, {60, 20}, {60, 10})
      assert {state.edits_h, state.focus} == {19, :edits}
      state = drag(state, {60, 10}, {60, 28})
      assert state.edits_h == 2
      state = double(state, {60, 27})
      assert state.edits_h == nil
    end

    test "both handles are drawn", %{dir: dir} do
      state = start_panels(dir)
      {_state, rows} = frame(state)
      # The tree's edge, half way down its 29 rows; the edits pane's centre (columns 30–119).
      assert String.at(Enum.at(rows, 14), 29) == "⠿"
      assert String.at(Enum.at(rows, 20), 74) == "⠿"

      # Focused, its longer hint doesn't move the handle.
      {_state, rows} = frame(%{state | focus: :edits})
      assert String.at(Enum.at(rows, 20), 74) == "⠿"
    end

    test "a click on the edits title focuses it and leaves the handle under the pointer",
         %{dir: dir} do
      state = start_panels(dir)
      {state, before} = frame(state)
      assert String.at(Enum.at(before, 20), 74) == "⠿"
      state = state |> send_io(mouse(:press, 74, 20)) |> send_io(mouse(:release, 74, 20))
      assert state.focus == :edits
      {_state, rows} = frame(state)
      assert String.at(Enum.at(rows, 20), 74) == "⠿"
      assert Enum.at(rows, 20) =~ "Enter opens"
    end

    test "in a narrow edits pane the handle stays between the name and the hint" do
      state = %{Loop.new_state(60, 30) | tree_shown: true, edits_shown: true, focus: :edits}
      {_state, rows} = frame(state)
      title = Enum.at(rows, Layout.resolve(60, 30, %{tree: true, edits: true}).edits.y)
      [before, _after] = String.split(title, "⠿")
      assert before =~ "── edits "
      refute before =~ "Enter"
    end
  end

  # The step 3 review's findings.
  describe "review fixes" do
    test "short of room, neither half of a dragged split collapses to nothing" do
      node = {:rows, {:pane, 1}, {:pane, 2}, 0.1}

      for h <- 2..12 do
        [{1, a}, {2, b}] = Layout.split(%Geex.Rect{x: 0, y: 0, w: 40, h: h}, node)
        assert a.h > 0 and b.h > 0, "h #{h}: #{a.h} + #{b.h}"
      end

      # And dragging there gives a ratio below 1.
      r = %Geex.Rect{x: 0, y: 0, w: 40, h: 6}
      assert Layout.ratio_at(r, node, 99) < 1
    end

    test "a dragged tree or edits pane leaves the editor what its splits need" do
      four =
        {:cols, {:pane, 1}, {:cols, {:pane, 2}, {:cols, {:pane, 3}, {:pane, 4}, 0.5}, 0.5}, 0.5}

      l = Layout.resolve(100, 30, %{tree: true, tree_w: 90, least: Layout.least(four)})
      assert l.editor.w == 51
      assert Enum.all?(Layout.split(l.editor, four), fn {_id, r} -> r.w >= 12 end)

      two = {:rows, {:pane, 1}, {:pane, 2}, 0.5}
      l = Layout.resolve(100, 30, %{edits: true, edits_h: 99, least: Layout.least(two)})
      assert l.editor.h == 8
    end

    test "a drag ends if a pane closes under it and its path names another split", %{dir: dir} do
      # 1 | (2 / 3), the inner handle held; pane 1 closes: the root path [:b] is gone.
      state = start(dir) |> send_io({:alt, ?=}) |> send_io({:alt, ?-})
      state = %{state | click: nil} |> send_io(mouse(:press, 90, 14))
      assert state.resizing
      state = %{state | panes: Panes.close_pane(state.panes, 1)}
      split = state.panes.split
      state = send_io(state, mouse(:drag, 90, 8))
      assert state.resizing == nil
      assert state.panes.split == split
    end
  end

  describe "the loop review's fixes" do
    test "a stacked split's handle stays on a full tab bar, drawn where a press takes it",
         %{dir: dir} do
      for i <- 1..12, do: File.write!(Path.join(dir, "f#{i}.txt"), "")
      state = start(dir) |> send_io({:alt, ?-})

      state =
        Enum.reduce(1..12, state, fn i, acc ->
          {:ok, pid} = Session.open_file(Path.join(dir, "f#{i}.txt"))
          {:noreply, acc} = Loop.handle_info({:geex_active_buffer, pid}, acc)
          acc
        end)

      state = send_io(state, {:alt, ?1})
      {state, rows} = frame(state)
      # Pane 2's bar is row 14; its handle is at 120 - 3 - 2.
      assert String.at(Enum.at(rows, 14), 115) == "⠿"
      state = drag(state, {115, 14}, {115, 20})
      assert panes(state) == [{1, {120, 20}}, {2, {120, 9}}]
    end

    test "a press where a handle was, after dragging it away, isn't a double-click",
         %{dir: dir} do
      state = start(dir) |> send_io({:alt, ?=})
      state = drag(%{state | click: nil}, {59, 1}, {55, 1})
      # Column 59 is text in the right pane now: one click there selects nothing.
      state = send_io(state, mouse(:press, 59, 1))
      assert state.selection == nil
    end

    test "a press on the tree's edge focuses the tree, as it did", %{dir: dir} do
      state = %{start(dir) | tree_shown: true, edits_shown: true}
      state = %{state | click: nil} |> send_io(mouse(:press, 29, 10))
      assert state.focus == :tree
    end
  end

  test "Panes.set_ratio/3 sets one split's ratio, and a closed pane keeps the others'" do
    {:ok, a} = Agent.start_link(fn -> nil end)
    ps = Panes.new() |> Panes.show(a) |> elem(0) |> Panes.split(:cols) |> Panes.split(:rows)
    ps = Panes.set_ratio(ps, [], 0.3) |> Panes.set_ratio([:b], 0.7)
    assert ps.split == {:cols, {:pane, 1}, {:rows, {:pane, 2}, {:pane, 3}, 0.7}, 0.3}
    assert Panes.close_pane(ps, 2).split == {:cols, {:pane, 1}, {:pane, 3}, 0.3}
  end
end
