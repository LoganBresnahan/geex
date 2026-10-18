defmodule Geex.Loop.MouseClickTest do
  # The mouse on everything else (ADR-0039 step 2): the tab bar and its close buttons, the tree,
  # the edits list, the pickers and the status line, through the loop's own handle_info/2 with no
  # terminal. Uses the global Session, Edits and Renderer, so not async.
  use ExUnit.Case, async: false

  doctest Geex.Loop.TabBar

  alias Geex.{Buffer, Edits, Loop, Renderer, Selection, Session}
  alias Geex.Loop.{Panes, TabBar}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_click_#{Geex.Fixtures.uniq()}")
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

    # The accent (ADR-0040 §7, amended 2026-10-18): the files open in a tab, in the tree; the
    # focused edits pane's highlighted entry.
    test "the tree shows open files in the accent, the current one bold; tabs closing follow",
         %{dir: dir} do
      {state, _a} = start_panels(dir)
      pal = state.theme.palette
      cell = fn y -> Geex.Screen.get_cell(Renderer.current(), 3, y) end

      # Rows 1–4: sub/, a.txt, b.txt, c.txt. a.txt is open and current.
      state = repaint(state)
      assert %{fg: accent, attrs: [:bold]} = cell.(2)
      assert accent == pal.accent
      assert {cell.(3).fg, cell.(4).fg} == {pal.fg, pal.fg}

      # b.txt opens as a tab: it is current; a.txt is open still, not bold.
      {state, _b} = open(state, dir, "b.txt")
      state = repaint(state)
      assert %{fg: ^accent, attrs: [:bold]} = cell.(3)
      assert %{fg: ^accent, attrs: []} = cell.(2)

      # Closing b.txt's tab (Alt+K) takes it out.
      state = send_io(%{state | focus: :editor}, {:alt, ?k}) |> repaint()
      assert cell.(3).fg == pal.fg
      assert %{fg: ^accent, attrs: [:bold]} = cell.(2)

      # Focused, the highlighted row (c.txt, row 4) is in the accent on the bar.
      _state = repaint(%{state | focus: :tree, tree: %{state.tree | sel: 3}})
      assert {cell.(4).fg, cell.(4).bg} == {accent, pal.active_line_bg}
      assert cell.(3).fg == pal.fg
    end

    test "the focused edits pane draws its highlighted entry in the accent", %{dir: dir} do
      {state, _a} = start_panels(dir)
      pal = state.theme.palette
      Edits.saved(Path.join(dir, "c.txt"))
      _ = Edits.rows()

      state = repaint(%{state | focus: :edits, edits_sel: 0})
      assert %{fg: fg, bg: bg} = Geex.Screen.get_cell(Renderer.current(), 32, 21)
      assert {fg, bg} == {pal.accent, pal.active_line_bg}

      # Not focused: the plain colour.
      _state = repaint(%{state | focus: :editor})
      assert Geex.Screen.get_cell(Renderer.current(), 32, 21).fg == pal.fg
    end

    # Earlier runs' rows (ADR-0034 §6, amended 2026-10-18). The global list's earlier rows come
    # from its file, which tests don't keep; they are put in its state here, and put back after.
    test "earlier rows sit under a divider the keys step over; a file gone since says so",
         %{dir: dir} do
      {state, a} = start_panels(dir)
      was = :sys.get_state(Edits).earlier
      on_exit(fn -> :sys.replace_state(Edits, &%{&1 | earlier: was}) end)

      earlier =
        for f <- ["b.txt", "gone.txt"],
            do: %{
              path: Path.join(dir, f),
              who: :you,
              at: ~N[2026-10-14 09:05:00],
              sha256: nil,
              tool_use: nil,
              earlier: true
            }

      :sys.replace_state(Edits, &%{&1 | earlier: earlier})
      Edits.saved(Path.join(dir, "c.txt"))
      _ = Edits.rows()
      state = repaint(state)

      # Rows 21–24: this run's c.txt, the divider, then the earlier rows, dated.
      screen = Geex.Renderer.current()
      text = fn y -> Enum.map_join(30..119, &Geex.Screen.get_cell(screen, &1, y).char) end
      assert text.(21) =~ ~r/c\.txt +you +\d\d:\d\d/
      assert text.(22) =~ "── earlier ──"
      assert text.(23) =~ ~r/b\.txt +you +Oct 14 09:05/

      # Down from c.txt steps over the divider to b.txt, Up back again.
      state = %{state | focus: :edits, edits_sel: 0}
      state = send_io(state, {:key, :down})
      assert state.edits_sel == 2
      state = send_io(state, {:key, :up})
      assert state.edits_sel == 0

      # A click on the divider does nothing.
      state = click(state, 40, 22) |> repaint()
      assert {state.edits_sel, active()} == {0, a}

      # Enter on gone.txt: it isn't there to open.
      state = %{state | focus: :edits, edits_sel: 3} |> send_io({:key, :enter})
      assert state.notice == "gone.txt no longer exists"
      assert active() == a

      # With no rows of this run's, focusing the pane starts past the divider.
      :sys.replace_state(Edits, &%{&1 | rows: []})

      state =
        Enum.reduce_while(1..4, %{state | focus: :editor}, fn _, acc ->
          acc = send_io(acc, {:alt, ?p})
          if acc.focus == :edits, do: {:halt, acc}, else: {:cont, acc}
        end)

      assert {state.focus, state.edits_sel} == {:edits, 1}
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
