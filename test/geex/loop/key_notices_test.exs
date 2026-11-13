defmodule Geex.Loop.KeyNoticesTest do
  # The notices that name a key in their text (ADR-0049 §5) name the key the default bindings
  # give that command, so a moved default can't leave one behind. Until remapping (roadmap 20.3)
  # reads them from the bindings, this pins each. Uses the global Session and Renderer: not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Screen, Session}
  alias Geex.Loop.{Bindings, FileOps, Output}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_key_notices_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "hello world\n")
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    {:ok, pid} = Session.open_file(Path.join(dir, "a.txt"))
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    %{dir: dir, buf: pid, state: state}
  end

  # The first chord the defaults bind to `command`, as the help writes it.
  defp key(command), do: Bindings.label(hd(Bindings.keys(Bindings.defaults(), command)))

  defp send_io(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp run(state, command) do
    state = send_io(state, {:cmd, :minibuffer})
    state = Enum.reduce(String.graphemes(command), state, &send_io(&2, {:char, &1}))
    send_io(state, {:key, :enter})
  end

  defp screen_text(state) do
    {:noreply, _state} = Loop.handle_info(:repaint, state)
    screen = Geex.Renderer.current()

    Enum.map_join(0..(screen.h - 1), "\n", fn y ->
      Enum.map_join(0..(screen.w - 1), &Screen.get_cell(screen, &1, y).char)
    end)
  end

  test "piping with no selection names the key that starts one", %{state: state} do
    state = run(state, "|tr a-z A-Z")
    assert state.notice == "| needs a selection to pipe (#{key(:select_start)} starts one)"
  end

  test "the next pane with only one names the keys that show the others", %{state: state} do
    state = send_io(state, {:cmd, :next_pane})

    assert state.notice ==
             "no other pane: the tree and edits pane are hidden " <>
               "(#{key(:toggle_tree)}, #{key(:toggle_edits)})"
  end

  test "Alt+N with nothing to search for names the key that searches", %{state: state} do
    state = send_io(state, {:cmd, :next_match})
    assert state.notice == "nothing to search for (#{key(:search)} searches)"
  end

  test "a buffer behind its file names the fast-forward key", %{state: state, dir: dir, buf: buf} do
    File.write!(Path.join(dir, "a.txt"), "new\n")
    :behind = Buffer.disk_changed(buf, "new\n")
    assert screen_text(state) =~ "behind disk (#{key(:fast_forward)})"
  end

  test "a pane with no file names the key that opens one", %{state: state} do
    state = send_io(state, {:cmd, :close})
    assert screen_text(state) =~ "no file (#{key(:find_file)} opens one)"
  end

  test "the preview's read-only notice names the key that closes it", %{dir: dir} do
    md = Path.join(dir, "n.md")
    File.write!(md, "# hi\n")
    {:ok, pid} = Session.open_file(md)
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    state = state |> Loop.toggle_preview() |> send_io({:cmd, :next_pane}) |> send_io({:char, "x"})
    assert state.notice == "the preview is read-only (#{key(:toggle_preview)} closes it)"
  end

  test "the edits and output panes' titles name the key that moves into them", %{state: state} do
    hint = " #{key(:next_pane)} "
    edits = %{state | edits_shown: true}
    assert screen_text(edits) =~ "── edits" and screen_text(edits) =~ hint

    output = %{edits | output: Output.new("echo hi", :show, 0)}
    rows = String.split(screen_text(output), "\n")
    assert Enum.any?(rows, &(&1 =~ "echo hi" and &1 =~ hint))
    assert Enum.any?(String.split(screen_text(edits), "\n"), &(&1 =~ "── edits" and &1 =~ hint))
  end

  test "deleting a file never saved names the key that closes it", %{dir: dir} do
    full = Path.join(dir, "fresh.txt")
    {:ok, _pid} = Session.open_file(full)

    assert {:done, notice} = FileOps.step({:delete, full}, dir)

    assert notice ==
             "not deleted: fresh.txt isn't on disk (it was never saved: close it with #{key(:close)})"
  end
end
