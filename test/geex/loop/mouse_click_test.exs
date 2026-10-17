defmodule Geex.Loop.MouseClickTest do
  # The mouse on everything else (ADR-0039 step 2): the tab bar and its close buttons, the tree,
  # the edits list, the pickers and the status line, through the loop's own handle_info/2 with no
  # terminal. Uses the global Session, Edits and Renderer, so not async.
  use ExUnit.Case, async: false

  doctest Geex.Loop.TabBar

  alias Geex.{Buffer, Edits, Loop, Selection, Session}
  alias Geex.Loop.{Panes, TabBar}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_click_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub"))
    for f <- ["a.txt", "b.txt", "c.txt"], do: File.write!(Path.join(dir, f), "#{f}\nline 2\n")
    File.write!(Path.join(dir, "sub/s.txt"), "s\n")
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

  defp click(state, x, y, mods \\ []),
    do: send_io(%{state | click: nil}, mouse(:press, :left, x, y, mods))

  defp wheel(state, dir, x, y), do: send_io(state, mouse(:wheel, dir, x, y))

  defp mouse(action, button, x, y, mods \\ []),
    do: {:mouse, %{action: action, button: button, x: x, y: y, mods: mods}}

  defp repaint(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    state
  end

  defp open(state, dir, name) do
    {:ok, pid} = Session.open_file(Path.join(dir, name))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid}
  end

  defp active, do: elem(Session.active_buffer(), 1)
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  # 120 × 30, tree and edits hidden: the editor is columns 0–119, rows 0–28.
  defp start(dir) do
    state = %{Loop.new_state(120, 30) | tree_shown: false, edits_shown: false}
    open(state, dir, "a.txt")
  end

  # The screen column of tab `i`'s label and of its `×`, for pane `id` at column `x0`, `w` wide.
  defp tab_x(state, id, x0, w, i) do
    names =
      for t <- state.panes.panes[id].tabs do
        %{path: path, dirty: dirty} = Buffer.status(t.buffer)
        Path.basename(path) <> if(dirty, do: " [+]", else: "")
      end

    bar = TabBar.layout(names, state.panes.panes[id].at, w, map_size(state.panes.panes) > 1)
    %{x: x, label: label} = Enum.find(bar.tabs, &(&1.i == i))
    {x0 + x + 1, x0 + x + String.length(label) - 2}
  end

  describe "the tab bar" do
    test "a click on a tab shows it; on its × closes it", %{dir: dir} do
      {state, a} = start(dir)
      {state, b} = open(state, dir, "b.txt")
      {state, _c} = open(state, dir, "c.txt")

      {label_x, _} = tab_x(state, 1, 0, 120, 0)
      state = click(state, label_x, 0)
      assert active() == a

      {_, close_x} = tab_x(state, 1, 0, 120, 1)
      state = click(state, close_x, 0)
      assert Enum.map(state.panes.panes[1].tabs, & &1.buffer) |> length() == 2
      refute Process.alive?(b)
      assert state.notice =~ "closed b.txt"
    end

    test "a tab's × is refused while its buffer has unsaved edits", %{dir: dir} do
      {state, _a} = start(dir)
      {state, b} = open(state, dir, "b.txt")
      state = send_io(state, {:char, "!"})
      {_, close_x} = tab_x(state, 1, 0, 120, 1)
      state = click(state, close_x, 0)
      assert Process.alive?(b)
      assert state.notice =~ "unsaved"
    end

    test "the pane's × closes the pane; a buffer still in another pane stays open", %{dir: dir} do
      {state, a} = start(dir)
      # Side by side: pane 1 is columns 0–58, pane 2 columns 60–119, its × at 117–119.
      state = send_io(state, {:alt, ?=})
      {state, b} = open(state, dir, "b.txt")
      assert state.panes.pane == 2

      state = click(state, 118, 0)
      assert Panes.ids(state.panes) == [1]
      assert state.panes.pane == 1
      assert active() == a
      # b was only in pane 2, so it closed with it; a is still open in pane 1.
      refute Process.alive?(b)
      assert Process.alive?(a)
      assert state.notice == "closed the pane"
    end

    test "the pane's × is refused while it holds the only copy of unsaved edits", %{dir: dir} do
      {state, _a} = start(dir)
      state = send_io(state, {:alt, ?=})
      {state, b} = open(state, dir, "b.txt")
      state = send_io(state, {:char, "!"})
      state = click(state, 118, 0)
      assert Panes.ids(state.panes) == [1, 2]
      assert Process.alive?(b)
      assert state.notice =~ "pane not closed: b.txt has unsaved changes"
    end

    test "the only pane has no ×", %{dir: dir} do
      {state, a} = start(dir)
      state = click(state, 118, 0)
      assert Panes.ids(state.panes) == [1]
      assert Process.alive?(a)
      assert TabBar.layout(["a.txt"], 0, 120, false).close == nil
    end
  end

  describe "the tree and the edits list" do
    # 120 × 30 with both shown: the tree is columns 0–29 (its divider at 29), rows 0–28; the
    # editor columns 30–119, rows 0–19; the edits pane rows 20–28.
    defp start_panels(dir) do
      state = %{Loop.new_state(120, 30) | tree_shown: true, edits_shown: true}
      {state, a} = open(state, dir, "a.txt")
      state = repaint(state)
      # The tree's reader answers the loop; here, the test process.
      assert_receive {:geex_tree, _pid, _files} = msg, 2000
      {:noreply, state} = Loop.handle_info(msg, state)
      {state, a}
    end

    test "a click opens a file, and opens and closes a folder", %{dir: dir} do
      {state, _a} = start_panels(dir)
      assert Enum.map(state.tree.rows, & &1.name) == ["sub", "a.txt", "b.txt", "c.txt"]

      # Row 1 is `sub/`: a click opens it, another closes it.
      state = click(state, 3, 1)
      assert state.focus == :tree
      assert Enum.map(state.tree.rows, & &1.name) == ["sub", "s.txt", "a.txt", "b.txt", "c.txt"]
      state = click(state, 3, 1)
      assert length(state.tree.rows) == 4

      # Row 3 is b.txt: a click opens it as a tab, and the editor has focus.
      state = click(state, 5, 3)
      assert Path.basename(Buffer.status(active()).path) == "b.txt"
      assert state.focus == :editor
    end

    test "the wheel scrolls the tree; a key brings the highlight back", %{dir: dir} do
      for i <- 1..60, do: File.write!(Path.join(dir, "f#{i}.txt"), "")
      {state, _a} = start_panels(dir)
      state = wheel(state, :down, 5, 5) |> wheel(:down, 5, 5) |> repaint()
      assert state.tree.top == 6
      assert state.tree.sel == 0

      state = %{state | focus: :tree}
      state = send_io(state, {:key, :down}) |> repaint()
      assert state.tree.sel == 1
      assert state.tree.top == 1
    end

    test "a click on an edits entry opens it, as Enter does", %{dir: dir} do
      {state, _a} = start_panels(dir)
      Edits.saved(Path.join(dir, "c.txt"))
      _ = Edits.rows()
      state = repaint(state)

      # The first entry is on the row under the edits pane's title.
      state = click(state, 40, 21)
      assert Path.basename(Buffer.status(active()).path) == "c.txt"
      assert state.focus == :editor
    end
  end

  test "a click on the status line's \"behind disk\" fast-forwards", %{dir: dir} do
    {state, a} = start(dir)
    File.write!(Path.join(dir, "a.txt"), "new\n")
    :behind = Buffer.disk_changed(a, "new\n")

    # " a.txt  behind disk (Alt+J)": the mark starts at column 8.
    state = click(state, 3, 29)
    assert Buffer.status(a).behind
    _state = click(state, 9, 29)
    assert Buffer.get_text(a) == "new\n"
    refute Buffer.status(a).behind
  end

  describe "the pickers" do
    test "the wheel moves the highlight; a click on a row runs it", %{dir: dir} do
      {state, _a} = start(dir)
      state = send_io(state, {:alt, ?i})
      state = Enum.reduce(String.graphemes("vsplit"), state, &send_io(&2, {:char, &1}))
      assert state.minibuffer.sel == 0

      # The popup's rows end just above the input row (29): one match, on row 28.
      state = click(state, 3, 28)
      assert state.minibuffer.mode == :inactive
      assert state.panes.split == {:cols, {:pane, 1}, {:pane, 2}, 0.5}
    end

    test "a click in the buffer picker shows that buffer; the wheel steps", %{dir: dir} do
      {state, a} = start(dir)
      {state, _b} = open(state, dir, "b.txt")
      {state, _c} = open(state, dir, "c.txt")
      state = send_io(state, {:alt, ?m})
      state = Enum.reduce(String.graphemes("buffers"), state, &send_io(&2, {:char, &1}))
      state = send_io(state, {:key, :enter})
      assert state.minibuffer.mode == :buffers
      # Three rows (26–28), most recent first: c, b, a; the previous one (b) highlighted.
      assert state.minibuffer.sel == 1
      state = wheel(state, :down, 3, 27)
      assert state.minibuffer.sel == 2
      state = wheel(state, :down, 3, 27)
      assert state.minibuffer.sel == 2

      state = click(state, 3, 28)
      assert state.minibuffer.mode == :inactive
      assert active() == a
    end

    test "a click off the list closes the picker", %{dir: dir} do
      {state, _a} = start(dir)
      state = send_io(state, {:alt, ?i})
      state = click(state, 3, 2)
      assert state.minibuffer.mode == :inactive
    end
  end

  # The step 2 review's findings.
  describe "review fixes" do
    test "a pane too small to draw takes no click, so its × can't close it", %{dir: dir} do
      {state, _a} = start(dir)
      state = send_io(state, {:alt, ?-})
      state = send_io(state, {:alt, ?p}) |> Map.put(:tree_shown, false)
      {state, b} = open(state, dir, "b.txt")
      assert state.panes.pane == 1
      # 120 × 6: the editor is rows 0–4, pane 1 is two rows high.
      {:noreply, state} = Loop.handle_info({:geex_io, {:resize, 6, 120}}, state)
      state = click(state, 118, 0)
      assert Panes.ids(state.panes) == [1, 2]
      assert Process.alive?(b)
    end

    test "a dirty tab's × is refused without switching to it", %{dir: dir} do
      {state, a} = start(dir)
      {state, b} = open(state, dir, "b.txt")
      state = send_io(state, {:char, "!"})
      state = send_io(state, {:alt, ?1})
      assert active() == a
      {_, close_x} = tab_x(state, 1, 0, 120, 1)
      state = click(state, close_x, 0)
      assert active() == a
      assert Process.alive?(b)
      assert state.notice =~ "not closed: b.txt has unsaved changes"
    end

    test "a pane's × on another pane leaves the current pane current", %{dir: dir} do
      {state, _a} = start(dir)
      # 1 | (2 / 3), then back to pane 1.
      state = send_io(state, {:alt, ?=}) |> send_io({:alt, ?-})
      assert Panes.ids(state.panes) == [1, 2, 3]
      state = send_io(state, {:alt, ?p})
      assert state.panes.pane == 1
      # Pane 3 is columns 60–119, rows 14–28: its × at 117–119 on row 14.
      state = click(state, 118, 14)
      assert Panes.ids(state.panes) == [1, 2]
      assert state.panes.pane == 1
    end

    test "a click on the tab already shown keeps the selection", %{dir: dir} do
      {state, _a} = start(dir)
      state = send_io(state, {:alt, ?b})
      assert state.selection
      {label_x, _} = tab_x(state, 1, 0, 120, 0)
      state = click(state, label_x, 0)
      assert state.selection
    end

    test "a double-click on a folder leaves it open", %{dir: dir} do
      {state, _a} = start_panels(dir)
      state = click(state, 3, 1)
      state = send_io(state, mouse(:press, :left, 3, 1))
      assert Enum.map(state.tree.rows, & &1.name) == ["sub", "s.txt", "a.txt", "b.txt", "c.txt"]
    end

    test "a key, or focusing the list, shows its highlighted row again", %{dir: dir} do
      for i <- 1..60, do: File.write!(Path.join(dir, "f#{i}.txt"), "")
      {state, _a} = start_panels(dir)
      state = wheel(state, :down, 5, 5) |> repaint()
      assert state.tree.top == 3
      # Up on the first row moves nothing, but brings the list back to it.
      state = %{state | focus: :tree}
      state = send_io(state, {:key, :up}) |> repaint()
      assert {state.tree.sel, state.tree.top} == {0, 0}

      # Shift+wheel (sideways) doesn't scroll the list, nor hold it.
      state = send_io(state, mouse(:wheel, :down, 5, 5, [:shift])) |> repaint()
      assert {state.tree.top, state.tree.hold} == {0, nil}

      for i <- 1..12, do: Edits.saved(Path.join(dir, "f#{i}.txt"))
      _ = Edits.rows()
      state = repaint(state)
      state = wheel(state, :down, 40, 24) |> repaint()
      assert state.edits_view.top == 3
      state = send_io(state, {:alt, ?p}) |> send_io({:alt, ?p})
      assert state.focus == :edits
      state = repaint(state)
      assert state.edits_view.top == 0
    end

    test "a click on the edits list opens the entry drawn there", %{dir: dir} do
      {state, _a} = start_panels(dir)
      Edits.saved(Path.join(dir, "c.txt"))
      _ = Edits.rows()
      state = repaint(state)
      # A newer edit arrives before the next frame: the click still means c.txt.
      Edits.saved(Path.join(dir, "b.txt"))
      _ = Edits.rows()
      state = click(state, 40, 21)
      assert Path.basename(Buffer.status(active()).path) == "c.txt"
      assert state.focus == :editor
    end
  end

  test "Alt+click extends the selection, as Shift+click does", %{dir: dir} do
    {state, _a} = start(dir)
    # One pane, 120 wide: a 4-column gutter.
    state = click(state, 4 + 1, 1)
    state = click(state, 4 + 3, 2, [:alt])
    assert state.selection == Selection.new({0, 1}) |> Selection.extend({1, 3})
    assert cursor() == {1, 3}
  end
end
