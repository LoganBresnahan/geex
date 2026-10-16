defmodule Geex.Loop.PanesTest do
  # Keys while a panel has focus (ADR-0034), through the loop's own handle_info/2 with a state
  # built by new_state/2: no terminal needed. Found live by the coordinator: Alt+M / Alt+P from
  # the edits pane crashed the loop. Sets the global Session's start, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Loop, Minibuffer, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_panes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), "a\n")
    Session.set_start(dir)
    # the editor's keys need an active buffer
    {:ok, buf} = Session.open_file(Path.join(dir, "lib/a.ex"))

    on_exit(fn ->
      Session.set_active_buffer(nil)
      DynamicSupervisor.terminate_child(Geex.BufferSupervisor, buf)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp focused_on(pane), do: %{Loop.new_state(120, 30) | focus: pane}

  # The tree's files are read in a process of their own (ADR-0034 §5); deliver its answer.
  defp tree_read(state) do
    assert_receive {:geex_tree, _pid, _index} = answer, 5_000
    {:noreply, state} = Loop.handle_info(answer, state)
    state
  end

  for pane <- [:edits, :tree] do
    test "Alt+M and Alt+P open the minibuffer and the palette from the #{pane} pane" do
      for {event, mode} <- [{{:alt, ?m}, :command}, {{:alt, ?p}, :palette}] do
        state = key(focused_on(unquote(pane)), event)
        assert %Minibuffer{mode: ^mode} = state.minibuffer
        assert state.focus == unquote(pane)
      end
    end

    test "other keys from the #{pane} pane don't reach a buffer; Esc goes back" do
      state = focused_on(unquote(pane))
      assert key(state, {:char, "x"}) == state
      assert key(state, {:key, :esc}).focus == :editor
    end
  end

  test "Alt+O cycles tree · editor · edits" do
    state = Loop.new_state(120, 30)
    state = key(state, {:alt, ?o})
    assert state.focus == :edits
    state = key(state, {:alt, ?o}) |> tree_read()
    assert state.focus == :tree
    assert state.tree.rows |> Enum.map(& &1.path) == ["lib"]
    assert key(state, {:alt, ?o}).focus == :editor
  end

  test "in the tree, Enter opens a directory; Left on a file goes up to it, then closes it",
       %{dir: _dir} do
    state = key(Loop.new_state(120, 30), {:alt, ?o}) |> key({:alt, ?o}) |> tree_read()
    state = key(state, {:key, :enter})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib", "lib/a.ex"]

    state = key(state, {:key, :down})
    assert state.tree.sel == 1
    state = key(state, {:key, :left})
    assert state.tree.sel == 0
    state = key(state, {:key, :left})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib"]
  end

  test "the tree is read in a process of its own: the loop doesn't wait, one read at a time" do
    state = key(Loop.new_state(120, 30), {:alt, ?o}) |> key({:alt, ?o})
    assert {pid, _ref} = state.tree.reading
    assert state.tree.rows == []

    # Back to the editor and into the tree again while the read runs: no second read.
    again = state |> key({:key, :esc}) |> key({:alt, ?o}) |> key({:alt, ?o})
    assert again.tree.reading == state.tree.reading

    # An answer from another process (a superseded read) changes nothing.
    assert Loop.handle_info({:geex_tree, self(), %{"x" => :file}}, state) == {:noreply, state}

    state = tree_read(state)
    assert state.tree.reading == nil
    assert state.tree.index == %{"lib" => %{"a.ex" => :file}}
    refute_received {:DOWN, _, :process, ^pid, _}
  end

  @tag :capture_log
  test "a reader that dies before answering: a notice, and no read again until asked" do
    {pid, ref} = spawn_monitor(fn -> exit(:boom) end)
    state = put_in(Loop.new_state(120, 30).tree.reading, {pid, ref})
    assert_receive {:DOWN, ^ref, :process, ^pid, :boom} = down

    {:noreply, state} = Loop.handle_info(down, state)
    assert state.notice =~ "the file tree couldn't be read"
    assert state.tree.reading == nil
    # an index, so the next frame doesn't start the same read again
    assert state.tree.index == %{}
  end
end
