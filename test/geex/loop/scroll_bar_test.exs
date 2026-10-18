defmodule Geex.Loop.ScrollBarTest do
  # The scroll bars take the mouse (ADR-0039 §7): a press on the track jumps there, the thumb
  # drags, both bars, through the loop's own handle_info/2 with no terminal. Uses the global
  # Session and Renderer, so not async.
  use ExUnit.Case, async: false

  doctest Geex.Loop.ScrollBar

  alias Geex.{Loop, Screen, Session}
  alias Geex.Loop.{Panes, ScrollBar}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_scroll_bar_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(0..99, "\n", &"line #{&1}"))
    File.write!(Path.join(dir, "wide.txt"), "short\n" <> String.duplicate("w", 300) <> "\nend")
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
  defp press(state, x, y), do: send_io(%{state | click: nil}, mouse(:press, x, y))

  defp frame(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    {state, Geex.Renderer.current()}
  end

  defp cursor, do: elem(Session.snapshot(), 1).cursor
  defp shown(state), do: Panes.shown(state.panes, state.panes.pane)

  # 120 × 30, tree and edits hidden: the pane is columns 0–119, rows 0–28. Its text rows are
  # 1–27 (27 of them) under the tab bar; the vertical bar is column 119 beside them, the
  # horizontal bar row 28.
  defp start(dir, name) do
    state = %{Loop.new_state(120, 30) | tree_shown: false, edits_shown: false}
    {:ok, pid} = Session.open_file(Path.join(dir, name))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    elem(frame(state), 0)
  end

  # Where the frame drew the vertical thumb: the rows of column 119 showing `┃`.
  defp drawn_thumb(%Screen{} = screen) do
    for y <- 1..27, Screen.get_cell(screen, 119, y).char == "┃", do: y
  end

  test "the bars the mouse finds are where the frame draws them", %{dir: dir} do
    state = start(dir, "long.txt")
    state = press(state, 119, 20)
    {state, screen} = frame(state)
    tab = shown(state)

    %{text: text} = Geex.Buffer.snapshot(tab.buffer)
    rect = %Geex.Rect{x: 0, y: 0, w: 120, h: 29}
    [v] = ScrollBar.layout(text, rect, {tab.scroll, tab.hscroll})
    assert {v.x, v.y, v.len, v.content} == {119, 1, 27, 100}
    {pos, len} = ScrollBar.thumb(v.len, v.content, v.offset)
    assert drawn_thumb(screen) == Enum.to_list((v.y + pos)..(v.y + pos + len - 1))
    for y <- 1..27, do: assert(Screen.get_cell(screen, 119, y).char in ["│", "┃"])
  end

  test "a press on the track jumps there, centring the thumb, and leaves the cursor",
       %{dir: dir} do
    state = start(dir, "long.txt")
    assert {shown(state).scroll, cursor()} == {0, {0, 0}}

    # The thumb is 7 rows (27 × 27 / 100); a press on row 20 puts its middle (its 4th row) there.
    state = press(state, 119, 20)
    assert state.scrolling.axis == :v
    {state, screen} = frame(state)
    assert hd(drawn_thumb(screen)) + 3 == 20
    assert shown(state).scroll > 40
    assert cursor() == {0, 0}

    # The release ends it: a later drag scrolls nothing.
    state = send_io(state, mouse(:release, 119, 20))
    assert state.scrolling == nil
    scroll = shown(state).scroll
    state = send_io(state, mouse(:drag, 119, 2))
    assert shown(state).scroll == scroll
  end

  test "the thumb drags: the text scrolls live, the grabbed row stays under the pointer",
       %{dir: dir} do
    state = start(dir, "long.txt")
    # At the top the thumb is rows 1–7; take it by its third row.
    state = press(state, 119, 3)
    assert shown(state).scroll == 0
    assert state.scrolling.grab == 2

    {state, _} =
      Enum.reduce(4..12, {state, nil}, fn y, {state, _} ->
        state = send_io(state, mouse(:drag, 119, y))
        {state, screen} = frame(state)
        assert hd(drawn_thumb(screen)) + 2 == y
        {state, screen}
      end)

    assert shown(state).scroll > 0

    # Past the ends: the last line at the bottom of the pane, then the top. The pointer may
    # wander off the bar sideways.
    state = send_io(state, mouse(:drag, 60, 29))
    assert shown(state).scroll == 100 - 27
    state = send_io(state, mouse(:drag, 60, 0))
    assert shown(state).scroll == 0
    state = send_io(state, mouse(:release, 60, 0))
    assert state.scrolling == nil
  end

  test "a key that moves the cursor brings it back into view", %{dir: dir} do
    state = start(dir, "long.txt")
    state = press(state, 119, 27) |> send_io(mouse(:release, 119, 27))
    assert shown(state).scroll == 73
    {state, _} = state |> send_io({:key, :down}) |> frame()
    assert cursor() == {1, 0}
    assert shown(state).scroll == 0
  end

  test "the horizontal bar: the track jumps, the thumb drags", %{dir: dir} do
    state = start(dir, "wide.txt")
    {state, screen} = frame(state)
    # The text columns start after the 4-column gutter; no vertical bar (3 lines).
    assert Screen.get_cell(screen, 4, 28).char == "━"
    assert Screen.get_cell(screen, 119, 28).char == "─"

    state = press(state, 119, 28)
    assert state.scrolling.axis == :h
    assert shown(state).hscroll == 300 - 116
    state = send_io(state, mouse(:drag, 0, 28))
    assert shown(state).hscroll == 0
    state = send_io(state, mouse(:release, 0, 28))
    assert {state.scrolling, cursor()} == {nil, {0, 0}}

    # The row has no bar under the gutter: a press there is a press on the text's last row.
    state = press(state, 1, 28)
    assert state.scrolling == nil
  end

  test "a press on another pane's bar focuses that pane and scrolls it", %{dir: dir} do
    state = start(dir, "long.txt") |> send_io({:alt, ?=})
    {state, _} = frame(state)
    # Side by side: pane 1 is columns 0–58 (its bar at 58), the divider 59, pane 2 columns
    # 60–119 (its bar at 119). Press the bar of the pane that isn't current.
    {other, x} = if state.panes.pane == 1, do: {2, 119}, else: {1, 58}
    state = press(state, x, 27)
    assert state.panes.pane == other
    assert shown(state).scroll == 73
  end

  test "a text with no bar: the last column is text, a press places the cursor", %{dir: dir} do
    File.write!(Path.join(dir, "short.txt"), "one\ntwo")
    state = start(dir, "short.txt")
    state = press(state, 119, 2)
    assert state.scrolling == nil
    assert cursor() == {1, 3}
  end
end
