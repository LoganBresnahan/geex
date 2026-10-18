defmodule Geex.Loop.PanesTest do
  # Keys while a panel has focus (ADR-0034), through the loop's own handle_info/2 with a state
  # built by new_state/2: no terminal needed. Found live by the coordinator: Alt+M / Alt+P from
  # the edits pane crashed the loop. Sets the global Session's start, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Loop, Minibuffer, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_panes_#{Geex.Fixtures.uniq()}")
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
    test "Alt+M and Alt+I open the minibuffer and the palette from the #{pane} pane" do
      for {event, mode} <- [{{:alt, ?m}, :command}, {{:alt, ?i}, :palette}] do
        state = key(focused_on(unquote(pane)), event)
        assert %Minibuffer{mode: ^mode} = state.minibuffer
        assert state.focus == unquote(pane)
      end
    end

    test "Alt+O, Alt+T, Alt+L and Alt+P work from the #{pane} pane (ADR-0037)" do
      state = focused_on(unquote(pane))

      assert %Minibuffer{mode: :files} = key(state, {:alt, ?o}).minibuffer

      assert key(state, {:alt, ?t}).tree_shown == not state.tree_shown
      assert key(state, {:alt, ?l}).edits_shown == not state.edits_shown
      assert key(state, {:alt, ?p}).focus != unquote(pane)
    end

    test "other keys from the #{pane} pane don't reach a buffer; Esc goes back" do
      state = focused_on(unquote(pane))
      assert key(state, {:char, "x"}) == state
      assert key(state, {:key, :esc}).focus == :editor
    end
  end

  test "Alt+P cycles tree · editor · edits" do
    state = Loop.new_state(120, 30)
    state = key(state, {:alt, ?p})
    assert state.focus == :edits
    state = key(state, {:alt, ?p}) |> tree_read()
    assert state.focus == :tree
    assert state.tree.rows |> Enum.map(& &1.path) == ["lib"]
    assert key(state, {:alt, ?p}).focus == :editor
  end

  test "in the tree, Enter opens a directory; Left on a file goes up to it, then closes it",
       %{dir: _dir} do
    state = key(Loop.new_state(120, 30), {:alt, ?p}) |> key({:alt, ?p}) |> tree_read()
    state = key(state, {:key, :enter})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib", "lib/a.ex"]

    state = key(state, {:key, :down})
    assert state.tree.sel == 1
    state = key(state, {:key, :left})
    assert state.tree.sel == 0
    state = key(state, {:key, :left})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib"]
  end

  test "in the tree, Alt+A and Alt+D act as Left and Right; Alt+W and Alt+S as Up and Down" do
    state = key(Loop.new_state(120, 30), {:alt, ?p}) |> key({:alt, ?p}) |> tree_read()
    state = key(state, {:alt, ?d})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib", "lib/a.ex"]

    state = key(state, {:alt, ?s})
    assert state.tree.sel == 1
    state = key(state, {:alt, ?a})
    assert state.tree.sel == 0
    state = key(state, {:alt, ?A})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib"]
  end

  test "`open PATH` from the tree opens the file and gives the editor the keys", %{dir: dir} do
    File.write!(Path.join(dir, "b.txt"), "b\n")
    state = key(focused_on(:tree), {:alt, ?m})

    state =
      Enum.reduce(
        String.graphemes("open " <> Path.join(dir, "b.txt")),
        state,
        &key(&2, {:char, &1})
      )

    state = key(state, {:key, :enter})

    assert state.focus == :editor
    assert {:ok, %{path: path}} = Session.snapshot()
    assert path == Path.join(dir, "b.txt")
    assert {:ok, _} = Session.close_active()
  end

  test "Alt+K closes the file, as the `close` verb does" do
    state = key(Loop.new_state(120, 30), {:alt, ?k})
    assert state.notice == "closed a.ex"
  end

  test "the tree is read in a process of its own: the loop doesn't wait, one read at a time" do
    state = key(Loop.new_state(120, 30), {:alt, ?p}) |> key({:alt, ?p})
    assert {pid, _ref} = state.tree.reading
    assert state.tree.rows == []

    # Back to the editor and into the tree again while the read runs: no second read.
    again = state |> key({:key, :esc}) |> key({:alt, ?p}) |> key({:alt, ?p})
    assert again.tree.reading == state.tree.reading

    # An answer from another process (a superseded read) changes nothing.
    assert Loop.handle_info({:geex_tree, self(), %{"x" => :file}}, state) == {:noreply, state}

    state = tree_read(state)
    assert state.tree.reading == nil
    assert state.tree.index == %{"lib" => %{"a.ex" => :file}}
    refute_received {:DOWN, _, :process, ^pid, _}
  end

  test "files coming and going read the tree again, once more if a read was running; the highlight keeps its file",
       %{dir: dir} do
    # Not read yet: nothing to refresh.
    fresh = Loop.new_state(120, 30)
    assert Loop.handle_info({:geex_tree_changed, dir}, fresh) == {:noreply, fresh}

    state = key(fresh, {:alt, ?p}) |> key({:alt, ?p}) |> tree_read()
    state = %{state | tree: %{state.tree | open: MapSet.new(["lib"])}}
    state = put_in(state.tree.rows, Geex.Tree.rows(state.tree.index, state.tree.open))
    # The highlight on lib/a.ex, the second row.
    state = put_in(state.tree.sel, 1)

    File.write!(Path.join(dir, "lib/0.ex"), "")
    {:noreply, state} = Loop.handle_info({:geex_tree_changed, dir}, state)
    assert {_pid, _ref} = state.tree.reading

    # Another change while it reads: one more read after it answers.
    {:noreply, state} = Loop.handle_info({:geex_tree_changed, dir}, state)
    assert state.tree.again
    first = state.tree.reading
    state = tree_read(state)
    assert {_, _} = state.tree.reading
    assert state.tree.reading != first
    refute state.tree.again

    state = tree_read(state)
    assert Enum.map(state.tree.rows, & &1.path) == ["lib", "lib/0.ex", "lib/a.ex"]
    assert Enum.at(state.tree.rows, state.tree.sel).path == "lib/a.ex"
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

  # Ctrl-C and Ctrl-Q reach geex now that the tty's signal and flow-control keys are off
  # (BUG-3), so each quit key has to quit wherever the keys go. The minibuffer took only Ctrl-X.
  test "Ctrl-X, Ctrl-Q and Ctrl-C quit from the editor, both panes and the minibuffer" do
    # Stand in for the binary's entry process, as cli_test does: with nothing registered,
    # `Geex.stop/0` would stop this test run.
    Process.register(self(), Geex.CLI)
    on_exit(fn -> if Process.whereis(Geex.CLI), do: Process.unregister(Geex.CLI) end)

    minibuffer = %{Loop.new_state(120, 30) | minibuffer: Minibuffer.open(:command)}

    for state <- [Loop.new_state(120, 30), focused_on(:edits), focused_on(:tree), minibuffer],
        c <- [?x, ?q, ?c] do
      key(state, {:ctrl, c})
      assert_receive :geex_quit, 100, "Ctrl-#{<<c>>} didn't quit from #{inspect(state.focus)}"
    end
  end
end
