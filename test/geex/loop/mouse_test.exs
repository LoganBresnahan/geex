defmodule Geex.Loop.MouseTest do
  # The mouse in the file panes (ADR-0039), through the loop's own handle_info/2 with no
  # terminal. Uses the global Session and Renderer, so not async.
  use ExUnit.Case, async: false

  doctest Geex.Loop.Mouse
  doctest Geex.TerminalIO

  alias Geex.{Clipboard, Loop, Selection, Session}
  alias Geex.Loop.{Mouse, Panes}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_mouse_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "ab字字cd\nfoo_bar baz\n")
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..100, "\n", &"line #{&1}"))
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

  # A press, as a single click: the last press is forgotten first, so two in a row in a test
  # aren't read as a double-click.
  defp click(state, x, y, mods \\ []),
    do: send_io(%{state | click: nil}, mouse(:press, :left, x, y, mods))

  defp mouse(action, button, x, y, mods \\ []),
    do: {:mouse, %{action: action, button: button, x: x, y: y, mods: mods}}

  defp repaint(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    state
  end

  defp open(state, path) do
    {:ok, pid} = Session.open_file(path)
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid}
  end

  defp cursor, do: elem(Session.snapshot(), 1).cursor
  defp active, do: elem(Session.active_buffer(), 1)

  # 100 × 24, tree and edits hidden: one pane over rows 0–22 (its tab bar on row 0, text on rows
  # 1–21), the status line on row 23.
  defp start(dir, name \\ "a.txt") do
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    open(state, Path.join(dir, name))
  end

  test "a click places the cursor: past the gutter, by display column, wide characters whole",
       %{dir: dir} do
    {state, _a} = start(dir)
    # Three lines: a 4-column gutter. "ab字字cd": 字 takes display columns 3–4 and 5–6.
    state = click(state, 4 + 2, 1)
    assert cursor() == {0, 2}
    state = click(state, 4 + 3, 1)
    assert cursor() == {0, 2}
    state = click(state, 4 + 4, 1)
    assert cursor() == {0, 3}
    # Past a line's end: its end. On the gutter: the line's start. Below the text: the end.
    state = click(state, 60, 2)
    assert cursor() == {1, 11}
    state = click(state, 1, 2)
    assert cursor() == {1, 0}
    _state = click(state, 30, 15)
    assert cursor() == {2, 0}
  end

  test "a click in another pane focuses it and places its cursor", %{dir: dir} do
    {state, a} = start(dir)
    # Side by side: pane 1 over columns 0–48, pane 2 over 50–99.
    state = send_io(state, {:alt, ?=})
    assert state.panes.pane == 2
    state = click(state, 4 + 1, 2)
    assert state.panes.pane == 1
    assert {active(), cursor()} == {a, {1, 1}}

    # From the tree or the edits pane, too: a click gives the editor focus.
    state = %{state | focus: :edits}
    state = click(state, 50 + 4 + 2, 1)
    assert {state.focus, state.panes.pane, cursor()} == {:editor, 2, {0, 2}}
  end

  test "a drag selects; Alt+C copies it; the release ends the drag", %{dir: dir} do
    {state, _a} = start(dir)
    state = click(state, 4 + 4, 2)
    state = send_io(state, mouse(:drag, :left, 4 + 7, 2))
    assert state.selection == Selection.new({1, 4}) |> Selection.extend({1, 7})
    assert cursor() == {1, 7}

    state = send_io(state, mouse(:release, :left, 4 + 7, 2))
    assert state.drag == nil
    # Moving the mouse with the button up selects nothing more.
    state = send_io(state, mouse(:drag, :left, 4 + 9, 2))
    assert Selection.range(state.selection) == {{1, 4}, {1, 7}}

    state = send_io(state, {:alt, ?c})
    assert Clipboard.top() == "bar"
    assert state.selection == nil
  end

  test "a drag back to where it started selects nothing", %{dir: dir} do
    {state, _a} = start(dir)
    state = click(state, 4 + 4, 2)
    state = send_io(state, mouse(:drag, :left, 4 + 6, 2))
    state = send_io(state, mouse(:drag, :left, 4 + 4, 2))
    assert state.selection == nil
  end

  test "Shift+click extends the selection, from the cursor or the selection's anchor",
       %{dir: dir} do
    {state, _a} = start(dir)
    state = click(state, 4 + 1, 1)
    state = click(state, 4 + 5, 2, [:shift])
    assert state.selection == Selection.new({0, 1}) |> Selection.extend({1, 5})
    state = click(state, 4 + 2, 2, [:shift])
    assert state.selection == Selection.new({0, 1}) |> Selection.extend({1, 2})
    assert cursor() == {1, 2}
    # A plain click drops it.
    state = click(state, 4, 1)
    assert state.selection == nil
  end

  test "a double-click selects the word", %{dir: dir} do
    {state, _a} = start(dir)
    state = click(state, 4 + 2, 2)
    state = send_io(state, mouse(:press, :left, 4 + 2, 2))
    assert Selection.range(state.selection) == {{1, 0}, {1, 7}}
    assert cursor() == {1, 7}

    # Not when the second press is elsewhere.
    state = click(state, 4 + 9, 2)
    state = send_io(state, mouse(:press, :left, 4 + 1, 2))
    assert state.selection == nil
  end

  test "the wheel scrolls the pane under the pointer and leaves its cursor", %{dir: dir} do
    {state, long} = start(dir, "long.txt")
    state = send_io(state, {:alt, ?=})
    state = repaint(state)
    # Pane 2 is current; wheel over pane 1.
    state = send_io(state, mouse(:wheel, :down, 10, 5))
    state = send_io(state, mouse(:wheel, :down, 10, 5))
    assert state.panes.pane == 2
    assert Panes.shown(state.panes, 1).scroll == 6
    assert Panes.shown(state.panes, 2).scroll == 0

    # The next frame keeps it, though the cursor ({0, 0}) is now out of view.
    state = repaint(state)
    assert Panes.shown(state.panes, 1).scroll == 6
    assert {active(), cursor()} == {long, {0, 0}}

    state = send_io(state, mouse(:wheel, :up, 10, 5))
    assert Panes.shown(state.panes, 1).scroll == 3
    # Not above the top, and not past the last line at the bottom.
    state = Enum.reduce(1..5, state, fn _, acc -> send_io(acc, mouse(:wheel, :up, 10, 5)) end)
    assert Panes.shown(state.panes, 1).scroll == 0
    state = Enum.reduce(1..50, state, fn _, acc -> send_io(acc, mouse(:wheel, :down, 10, 5)) end)
    assert Panes.shown(state.panes, 1).scroll == 100 - 21
  end

  test "after the wheel, moving the cursor brings it back into view", %{dir: dir} do
    {state, _long} = start(dir, "long.txt")
    state = repaint(state)
    state = Enum.reduce(1..10, state, fn _, acc -> send_io(acc, mouse(:wheel, :down, 10, 5)) end)
    state = repaint(state)
    assert Panes.current(state.panes).scroll == 30
    assert cursor() == {0, 0}

    state = send_io(state, {:key, :down}) |> repaint()
    assert cursor() == {1, 0}
    assert Panes.current(state.panes).scroll == 0
    assert Panes.current(state.panes).hold == nil
  end

  test "a click near the bottom doesn't scroll the text from under the pointer", %{dir: dir} do
    {state, _long} = start(dir, "long.txt")
    state = repaint(state)
    # The last text row (row 21) is line 21; scrolloff would scroll it to keep 3 lines below.
    state = click(state, 8, 21) |> repaint()
    assert cursor() == {20, 3}
    assert Panes.current(state.panes).scroll == 0
    # A drag there selects from the same line.
    state = send_io(state, mouse(:drag, :left, 10, 21)) |> repaint()
    assert Selection.range(state.selection) == {{20, 3}, {20, 5}}
    assert Panes.current(state.panes).scroll == 0
  end

  test "a drag held past the bottom edge scrolls a line at a time", %{dir: dir} do
    {state, _long} = start(dir, "long.txt")
    state = repaint(state)
    state = click(state, 5, 5)
    assert cursor() == {4, 0}
    # Onto the scroll-bar row, below the text.
    state = send_io(state, mouse(:drag, :left, 5, 22))
    assert cursor() == {20, 0}
    assert %{timer: ref} = state.drag
    assert is_reference(ref)

    {:noreply, state} = Loop.handle_info({:geex_drag_scroll, ref}, state)
    assert Panes.current(state.panes).scroll == 1
    assert cursor() == {21, 0}
    assert Selection.range(state.selection) == {{4, 0}, {21, 0}}

    # A stale tick does nothing; back inside, the ticks stop.
    {:noreply, ^state} = Loop.handle_info({:geex_drag_scroll, make_ref()}, state)
    state = send_io(state, mouse(:drag, :left, 5, 10))
    assert state.drag.timer == nil
    assert cursor() == {10, 0}
  end

  test "a drag held above the top edge scrolls up", %{dir: dir} do
    {state, _long} = start(dir, "long.txt")
    state = Enum.reduce(1..3, state, fn _, acc -> send_io(acc, mouse(:wheel, :down, 10, 5)) end)
    state = click(state, 5, 1)
    assert cursor() == {9, 0}
    # Onto the tab bar.
    state = send_io(state, mouse(:drag, :left, 5, 0))
    {:noreply, state} = Loop.handle_info({:geex_drag_scroll, state.drag.timer}, state)
    assert Panes.current(state.panes).scroll == 8
    assert cursor() == {8, 0}
  end

  test "the minibuffer takes no mouse; a release still ends a drag", %{dir: dir} do
    {state, _a} = start(dir)
    state = click(state, 4 + 4, 2)
    state = send_io(state, {:alt, ?m})
    state = send_io(state, mouse(:drag, :left, 4 + 7, 2))
    assert state.selection == nil
    state = send_io(state, mouse(:release, :left, 4 + 7, 2))
    assert state.drag == nil
  end

  test "the mouse verb turns the mouse off and on", %{dir: dir} do
    {state, _a} = start(dir)
    state = type(state, "mouse")
    assert state.mouse == false
    assert state.notice =~ "mouse off"
    state = type(state, "mouse")
    assert state.mouse == true
  end

  test "a copy also goes to the system clipboard, through the terminal (OSC 52)", %{dir: dir} do
    {state, _a} = start(dir)
    # Stand in for the terminal: what the loop writes arrives here.
    Process.register(self(), Geex.TerminalIO)

    try do
      state = click(state, 4 + 4, 2)
      state = send_io(state, mouse(:drag, :left, 4 + 7, 2))
      _state = send_io(state, {:alt, ?c})
      assert_received {:"$gen_cast", {:write, "\e]52;c;YmFy\a"}}
    after
      Process.unregister(Geex.TerminalIO)
    end
  end

  test "Mouse.text_pos/4 counts the horizontal scroll" do
    rect = %Geex.Rect{x: 0, y: 0, w: 20, h: 6}
    assert {{0, 12}, {0, 0}} = Mouse.text_pos("0123456789abcdef", rect, {0, 10}, {4 + 2, 1})
    # Right of the pane: the pointer is past its edge.
    assert {_pos, {1, 0}} = Mouse.text_pos("x", rect, {0, 0}, {25, 1})
    # Below the text rows (rows 1–4), on the scroll-bar row.
    assert {_pos, {0, 1}} = Mouse.text_pos("x", rect, {0, 0}, {5, 5})

    # Text taller than the rows has a scroll bar in the last column: a click there lands on the
    # last text column before it, not on text hidden under the bar.
    tall = Enum.map_join(1..10, "\n", fn _ -> String.duplicate("z", 40) end)
    assert {{0, 14}, {1, 0}} = Mouse.text_pos(tall, rect, {0, 0}, {19, 1})
    assert {{0, 14}, {1, 0}} = Mouse.text_pos(tall, rect, {0, 0}, {18, 1})
    assert {{0, 13}, {0, 0}} = Mouse.text_pos(tall, rect, {0, 0}, {17, 1})
  end

  # The step 1 review's findings (ADR-0039).
  describe "review fixes" do
    test "a drag onto the last column scrolls right, in a file with no vertical scroll bar",
         %{dir: dir} do
      File.write!(Path.join(dir, "wide.txt"), "x\n" <> String.duplicate("w", 202) <> "\ny")
      {state, _w} = start(dir, "wide.txt")
      state = repaint(state)
      state = click(state, 5, 2)
      state = send_io(state, mouse(:drag, :left, 99, 2))
      assert is_reference(state.drag.timer)
      {:noreply, state} = Loop.handle_info({:geex_drag_scroll, state.drag.timer}, state)
      assert Panes.current(state.panes).hscroll == 1
      assert cursor() == {1, 96}
    end

    test "a drag ends when its pane shows another buffer, or its text changes", %{dir: dir} do
      {state, _long} = start(dir, "long.txt")
      state = click(state, 10, 10)
      {state, _a} = open(state, Path.join(dir, "a.txt"))
      assert state.drag == nil
      state = send_io(state, mouse(:drag, :left, 6, 1))
      assert state.selection == nil

      state = click(state, 4 + 1, 1)
      {:noreply, state} = Loop.handle_info({:geex_buffer_change, active(), 2, nil}, state)
      assert state.drag == nil
    end

    test "after a split or a resize, a click's scroll gives way and the cursor shows",
         %{dir: dir} do
      {state, _long} = start(dir, "long.txt")
      state = repaint(state)
      state = click(state, 6, 20) |> repaint()
      assert cursor() == {19, 1}
      assert Panes.current(state.panes).scroll == 0

      # The new half has 9 text rows: line 19 is past them unless the scroll follows.
      state = send_io(state, {:alt, ?-}) |> repaint()
      %{scroll: scroll} = Panes.current(state.panes)
      assert scroll > 0 and 19 < scroll + 9

      state = click(state, 6, 21) |> repaint()
      {:noreply, state} = Loop.handle_info({:geex_io, {:resize, 12, 100}}, state)
      state = repaint(state)
      %{scroll: scroll} = Panes.current(state.panes)
      assert elem(cursor(), 0) in scroll..(scroll + 2)
    end

    test "after the wheel, a key that edits in place still brings the cursor into view",
         %{dir: dir} do
      {state, _long} = start(dir, "long.txt")
      state = repaint(state)

      state =
        Enum.reduce(1..10, state, fn _, acc -> send_io(acc, mouse(:wheel, :down, 10, 5)) end)

      state = send_io(state, {:key, :delete}) |> repaint()
      assert cursor() == {0, 0}
      assert Panes.current(state.panes).scroll == 0
    end

    test "a key ends a drag; a tick under the minibuffer does nothing", %{dir: dir} do
      {state, _long} = start(dir, "long.txt")
      state = repaint(state)
      state = click(state, 5, 5)
      state = send_io(state, mouse(:drag, :left, 5, 22))
      ref = state.drag.timer
      # The palette opened by a key: the drag is over, and its pending tick is stale.
      state = send_io(state, {:alt, ?i})
      assert state.drag == nil
      {:noreply, after_tick} = Loop.handle_info({:geex_drag_scroll, ref}, state)
      assert after_tick == state
      assert cursor() == {20, 0}
    end

    test "a double-click on a byte that isn't UTF-8 doesn't crash" do
      assert Mouse.word_at(<<"ab", 255, "cd">>, 2) == {2, 3}
    end

    test "Shift+wheel reaches the widest line's end, past the vertical scroll bar", %{dir: dir} do
      text = [String.duplicate("v", 209) | Enum.map(2..100, &"line #{&1}")] |> Enum.join("\n")
      File.write!(Path.join(dir, "both.txt"), text)
      {state, _b} = start(dir, "both.txt")

      state =
        Enum.reduce(1..40, state, fn _, acc ->
          send_io(acc, mouse(:wheel, :down, 10, 5, [:shift]))
        end)

      # 100 columns, a 5-column gutter, the bar: 94 text columns.
      assert Panes.current(state.panes).hscroll == 209 - 94
    end
  end

  defp type(state, text) do
    state = send_io(state, {:alt, ?m})
    state = Enum.reduce(String.graphemes(text), state, &send_io(&2, {:char, &1}))
    send_io(state, {:key, :enter})
  end
end
