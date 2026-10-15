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
    state = key(state, {:alt, ?o})
    assert state.focus == :tree
    assert state.tree.rows |> Enum.map(& &1.path) == ["lib"]
    assert key(state, {:alt, ?o}).focus == :editor
  end

  test "in the tree, Enter opens a directory; Left on a file goes up to it, then closes it",
       %{dir: _dir} do
    state = key(Loop.new_state(120, 30), {:alt, ?o}) |> key({:alt, ?o})
    state = key(state, {:key, :enter})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib", "lib/a.ex"]

    state = key(state, {:key, :down})
    assert state.tree.sel == 1
    state = key(state, {:key, :left})
    assert state.tree.sel == 0
    state = key(state, {:key, :left})
    assert Enum.map(state.tree.rows, & &1.path) == ["lib"]
  end
end
