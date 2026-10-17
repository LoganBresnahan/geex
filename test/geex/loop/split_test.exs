defmodule Geex.Loop.SplitTest do
  # Split panes and tabs (ADR-0038) through the loop's own handle_info/2, with no terminal; the
  # frame the loop draws is read back from `Geex.Renderer` (it runs under test, writing to no
  # terminal). Uses the global Session and Renderer, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Screen, Session}
  alias Geex.Loop.Panes

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_split_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    for f <- ["a.txt", "b.txt", "c.txt"], do: File.write!(Path.join(dir, f), "#{f}\nline 2\n")
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  # Open `name` the way Alt+O's Enter does, and deliver Session's event to the loop.
  defp open(state, dir, name) do
    {:ok, pid} = Session.open_file(Path.join(dir, name))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid}
  end

  defp active, do: elem(Session.active_buffer(), 1)
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  # Repaint, and read the frame back as rows of text.
  defp frame(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    %Screen{} = screen = Geex.Renderer.current()

    rows =
      for y <- 0..(screen.h - 1) do
        Enum.map_join(0..(screen.w - 1), &Screen.get_cell(screen, &1, y).char)
      end

    {state, rows}
  end

  defp start(dir) do
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    open(state, dir, "a.txt")
  end

  test "Alt+= splits side by side: the new pane shows the same buffer and is current", %{dir: dir} do
    {state, a} = start(dir)
    Session.set_cursor({1, 2})
    state = key(state, {:alt, ?=})

    assert state.panes.split == {:cols, {:pane, 1}, {:pane, 2}}
    assert state.panes.pane == 2
    assert active() == a
    assert cursor() == {1, 2}

    {_state, rows} = frame(state)
    assert hd(rows) =~ ~r/^ 1 a\.txt +│ 1 a\.txt/
    assert Enum.at(rows, 1) =~ ~r/a\.txt.*│.*a\.txt/
  end

  test "each pane keeps its own cursor on the same buffer", %{dir: dir} do
    {state, a} = start(dir)
    state = key(state, {:alt, ?-})
    Session.set_cursor({1, 3})

    # Alt+P back to the first pane: its cursor, not the second's.
    state = key(state, {:alt, ?p})
    assert state.panes.pane == 1
    assert {active(), cursor()} == {a, {0, 0}}

    state = key(state, {:alt, ?p})
    assert state.panes.pane == 2
    assert cursor() == {1, 3}
  end

  test "a file opens as a tab in the current pane; Alt+, Alt+. and Alt+N switch", %{dir: dir} do
    {state, a} = start(dir)
    state = key(state, {:alt, ?=})
    {state, b} = open(state, dir, "b.txt")
    {state, c} = open(state, dir, "c.txt")

    assert Enum.map(state.panes.panes[2].tabs, & &1.buffer) == [a, b, c]
    assert Enum.map(state.panes.panes[1].tabs, & &1.buffer) == [a]

    assert active() == c
    state = key(state, {:alt, ?,})
    assert active() == b
    state = key(state, {:alt, ?.}) |> key({:alt, ?.})
    assert active() == a
    state = key(state, {:alt, ?3})
    assert active() == c
    # A tab past the end changes nothing.
    assert key(state, {:alt, ?9}).panes == state.panes

    # Opening a file the pane already has switches to its tab.
    {state, ^a} = open(state, dir, "a.txt")
    assert length(state.panes.panes[2].tabs) == 3
    assert Panes.current(state.panes).buffer == a

    {_state, rows} = frame(state)
    assert hd(rows) =~ ~r/│ 1 a\.txt  2 b\.txt  3 c\.txt/
  end

  test "Alt+K closes a tab; the buffer stays open while another pane has it", %{dir: dir} do
    {state, a} = start(dir)
    state = key(state, {:alt, ?=})
    {state, b} = open(state, dir, "b.txt")

    # b is only here: closing its tab closes the buffer.
    state = key(state, {:alt, ?k})
    assert state.notice == "closed b.txt"
    refute Process.alive?(b)
    assert active() == a

    # a is in both panes: closing this pane's last tab closes the pane, not the buffer.
    state = key(state, {:alt, ?k})
    assert state.notice =~ "still open in another pane"
    assert state.panes.split == {:pane, 1}
    assert Process.alive?(a)
    assert active() == a
  end

  test "Alt+K refuses a buffer with unsaved edits that no other tab holds", %{dir: dir} do
    {state, _a} = start(dir)
    {state, b} = open(state, dir, "b.txt")
    state = key(state, {:char, "x"})

    state = key(state, {:alt, ?k})
    assert state.notice =~ "not closed: unsaved changes"
    assert Process.alive?(b)
    assert length(state.panes.panes[1].tabs) == 2
  end

  test "the only pane's last tab closes to the buffer before it", %{dir: dir} do
    {state, a} = start(dir)
    {state, b} = open(state, dir, "b.txt")
    state = key(state, {:alt, ?1})
    assert active() == a

    state = key(state, {:alt, ?k})
    assert state.notice == "closed a.txt"
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, active()}, state)
    assert active() == b
    assert Enum.map(state.panes.panes[1].tabs, & &1.buffer) == [b]
  end

  test "a buffer that ends leaves its tabs; an emptied pane closes", %{dir: dir} do
    {state, _a} = start(dir)
    state = key(state, {:alt, ?-})
    {state, b} = open(state, dir, "b.txt")
    state = key(state, {:alt, ?1})
    ref = Process.monitor(b)
    {:ok, _} = Session.close_file(Path.join(dir, "b.txt"))
    assert_receive {:DOWN, ^ref, :process, ^b, _}

    down = {:DOWN, state.watched[b].ref, :process, b, :shutdown}
    {:noreply, state} = Loop.handle_info(down, state)
    assert Panes.buffers(state.panes) |> MapSet.member?(b) == false
    refute Map.has_key?(state.watched, b)
  end

  test "a stale active-buffer event doesn't bring back a tab you switched from", %{dir: dir} do
    {state, a} = start(dir)
    {state, b} = open(state, dir, "b.txt")
    # Two quick switches: to a, then back to b. Session's event for a arrives late.
    state = key(state, {:alt, ?1}) |> key({:alt, ?2})
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, a}, state)
    assert Panes.current(state.panes).buffer == b
    assert active() == b
  end

  test "an agent's edit shows in every pane that has the file", %{dir: dir} do
    {state, a} = start(dir)
    state = key(state, {:alt, ?=})
    {state, _b} = open(state, dir, "b.txt")
    state = key(state, {:alt, ?p})
    assert state.panes.pane == 1
    state = key(state, {:alt, ?p}) |> open(dir, "a.txt") |> elem(0)

    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "AGENT "})
    {:ok, _} = Buffer.dispatch(a, Geex.Command.put_meta(cmd, Geex.Command.Meta.llm("m")))
    assert_receive {:geex_buffer_change, ^a, _, _}

    {_state, rows} = frame(state)
    assert Enum.at(rows, 1) =~ ~r/AGENT a\.txt.*│.*AGENT a\.txt/
  end

  test "a split that would leave a pane too small is refused; a tiny pane isn't drawn",
       %{dir: dir} do
    {state, _a} = start(dir)
    state = %{state | w: 40, h: 12}
    state = key(state, {:alt, ?=})
    assert state.panes.split == {:cols, {:pane, 1}, {:pane, 2}}
    state = key(state, {:alt, ?=})
    assert state.notice == "no room to split this pane"
    assert state.panes.split == {:cols, {:pane, 1}, {:pane, 2}}

    # Shrunk after splitting: the frame still draws, and a pane too small to draw is filled
    # with the background, not left as whatever the terminal showed before.
    {_state, rows} = frame(%{state | w: 6, h: 5})
    assert length(rows) == 5
    screen = Geex.Renderer.current()
    # 6 columns: the left half is 2 wide (skipped), then the divider, then a 3-wide pane.
    assert Screen.get_cell(screen, 0, 1).bg == state.theme.palette.bg
  end

  test "an open shows its tab at once, so the next key acts on it", %{dir: dir} do
    {state, a} = start(dir)
    state = key(state, {:alt, ?m})
    state = Enum.reduce(String.graphemes("open b.txt"), state, &key(&2, {:char, &1}))
    # Enter, then Alt+K, both handled before Session's event for b arrives.
    state = state |> key({:key, :enter}) |> key({:alt, ?k})

    assert state.notice == "closed b.txt"
    assert Process.alive?(a)
    assert active() == a
  end

  test "`geex a b c` shows the files as tabs in that order, the first shown", %{dir: dir} do
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    pids = for f <- ["a.txt", "b.txt", "c.txt"], do: elem(Session.open_file(Path.join(dir, f)), 1)
    # One of the opens' own events got there first.
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, List.last(pids)}, state)

    {:noreply, state} = Loop.handle_info({:geex_open_tabs, pids}, state)
    assert Enum.map(state.panes.panes[1].tabs, & &1.buffer) == pids
    assert active() == hd(pids)
  end

  test "a notice from a buffer in another tab names its file", %{dir: dir} do
    {state, a} = start(dir)
    {state, b} = open(state, dir, "b.txt")

    {:noreply, state} = Loop.handle_info({:geex_buffer_notice, a, "1 conflict"}, state)
    assert state.notice == "a.txt: 1 conflict"
    {:noreply, state} = Loop.handle_info({:geex_buffer_notice, b, "1 conflict"}, state)
    assert state.notice == "1 conflict"
  end

  test "the verbs and the palette entries split and switch tabs too", %{dir: dir} do
    {state, _a} = start(dir)

    type = fn state, text ->
      state = key(state, {:alt, ?m})
      state = Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))
      key(state, {:key, :enter})
    end

    state = type.(state, "vsplit")
    assert state.panes.split == {:cols, {:pane, 1}, {:pane, 2}}
    state = type.(state, "split")
    assert state.panes.split == {:cols, {:pane, 1}, {:rows, {:pane, 2}, {:pane, 3}}}

    {state, b} = open(state, dir, "b.txt")
    state = type.(state, "tab 1")
    refute active() == b
    _state = type.(state, "tab next")
    assert active() == b

    names = Enum.map(Geex.Command.Catalog.all(), & &1.name)
    assert Enum.all?(["split", "vsplit", "tab next", "tab prev"], &(&1 in names))
  end
end
