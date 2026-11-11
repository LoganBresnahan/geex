defmodule Geex.Loop.NamedKeysTest do
  # ADR-0047 through the loop's own handle_info/2, no terminal: every key runs a named command,
  # a command means what it means where it runs, a typed name does what its key does, and the
  # bindings are a value, so a moved key follows into every view. Uses the global Session, so
  # not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Minibuffer, Session}
  alias Geex.Loop.{Bindings, Output}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_named_keys_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/b.ex"), "b\n")
    File.write!(Path.join(dir, "a.txt"), "hello world\nline 2\n")
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

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp keys(state, events), do: Enum.reduce(events, state, &key(&2, &1))
  defp type(state, text), do: keys(state, Enum.map(String.graphemes(text), &{:char, &1}))
  defp text(buf), do: Buffer.get_text(buf)
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  # Type a command after Alt+M and run it.
  defp run(state, command), do: state |> key({:alt, ?m}) |> type(command) |> key({:key, :enter})

  describe "a typed command does what its key does (§6)" do
    test "the motions", %{state: state} do
      state = run(state, "word forward")
      assert cursor() == {0, 6}
      state = run(state, "line end")
      assert cursor() == {0, 11}
      state = run(state, "down")
      assert cursor() == {1, 6}
      state = run(state, "line start")
      assert cursor() == {1, 0}
      _ = run(state, "up")
      assert cursor() == {0, 0}
    end

    test "the editor's own keys: `newline` is Enter, `delete back` is Backspace", %{
      state: state,
      buf: buf
    } do
      Session.set_cursor({0, 5})
      state = run(state, "newline")
      assert text(buf) == "hello\n world\nline 2\n"
      assert cursor() == {1, 0}
      assert length(Buffer.history(buf)) == 1

      _ = run(state, "delete back")
      assert text(buf) == "hello world\nline 2\n"
      assert cursor() == {0, 5}
    end

    test "the surfaces that had only a key: `settings`, `palette`, `resize left`", %{
      state: state
    } do
      assert %Loop.Settings{} = run(state, "settings").settings
      assert %Minibuffer{mode: :palette} = run(state, "palette").minibuffer
      assert %Minibuffer{mode: :grid} = run(state, "grid").minibuffer

      state = %{state | tree_shown: true, tree_w: 30}
      assert run(state, "resize left").tree_w == 26
    end

    # The maintainer's word, 2026-11-11: typed commands act on the file you were last in, as the
    # older typed verbs do; only those whose keys work from anywhere follow the focus.
    test "with the tree focused, a typed command acts on the editor's file; focus stays", %{
      state: state,
      buf: buf
    } do
      tree = %{state | tree_shown: true, tree_w: 30, focus: :tree}
      tree = put_in(tree.tree.rows, [%{path: "a.txt", dir?: false}, %{path: "lib", dir?: true}])
      tree = put_in(tree.tree.sel, 1)

      Session.set_cursor({0, 5})
      tree = run(tree, "newline")
      assert text(buf) == "hello\n world\nline 2\n"
      assert {tree.focus, tree.tree.sel} == {:tree, 1}

      tree = run(tree, "up")
      assert cursor() == {0, 0}
      assert tree.tree.sel == 1

      # `resize left` is one that follows the focus: the tree's edge moves, as Alt+← does there.
      assert run(tree, "resize left").tree_w == 26
      assert run(tree, "pane next").focus != :tree
    end

    test "`stop` with nothing running does nothing", %{state: state, buf: buf} do
      state = run(state, "stop")
      assert state.shell == nil
      assert text(buf) == "hello world\nline 2\n"
    end

    test "picked from the palette, a command runs the same", %{state: state} do
      state = state |> key({:alt, ?i}) |> type("line end") |> key({:key, :enter})
      assert state.minibuffer.mode == :inactive
      assert cursor() == {0, 11}
    end
  end

  describe "a command means what it means where it runs (§4)" do
    test "in the command line, Alt+A and Alt+D move the cursor, as ← and → do", %{state: state} do
      state = state |> key({:alt, ?m}) |> type("abc") |> keys([{:alt, ?a}, {:alt, ?a}])
      state = type(state, "X") |> key({:alt, ?d}) |> type("Y")
      assert Minibuffer.value(state.minibuffer) == "aXbYc"
    end

    test "in the command line, Alt+W brings back what was entered, as ↑ does", %{state: state} do
      state = run(state, "2")
      assert cursor() == {1, 0}
      state = state |> key({:alt, ?m}) |> key({:alt, ?w})
      assert Minibuffer.value(state.minibuffer) == "2"
      state = key(state, {:alt, ?s})
      assert Minibuffer.value(state.minibuffer) == ""
    end

    test "in the output pane, Alt+R and Alt+F go to the top and the bottom, as Home and End do",
         %{state: state} do
      out = Output.new("ls", :show, 0) |> Output.add(~w(a b c d e), "")
      state = %{state | output: out, focus: :output}
      state = key(state, {:alt, ?r})
      assert state.output.sel == 0
      state = key(state, {:alt, ?f})
      assert state.output.sel == Output.size(out) - 1
      assert key(state, {:key, :home}).output.sel == 0
    end
  end

  describe "the bindings are a value (§7)" do
    # `up` moved from Alt+W to Alt+I (the palette's key, so the palette goes to Alt+Shift+I).
    defp moved(state) do
      keys =
        Bindings.defaults()
        |> Map.delete({:alt, ?w})
        |> Map.put({:alt, ?i}, :up)
        |> Map.put({:alt, ?I}, :palette)

      %{state | keys: keys}
    end

    test "a moved key runs its command in the editor; the old key does nothing", %{
      state: state,
      buf: buf
    } do
      # The column kept for up and down is the loop's: set it with the cursor.
      state = %{moved(state) | goal: 2}
      Session.set_cursor({1, 2})
      state = key(state, {:alt, ?w})
      assert cursor() == {1, 2}
      assert text(buf) == "hello world\nline 2\n"
      _ = key(state, {:alt, ?i})
      assert cursor() == {0, 2}
    end

    test "and in a picker, the tree and the settings view", %{state: state} do
      state = moved(state)

      picker = state |> key({:alt, ?I}) |> keys([{:alt, ?s}, {:alt, ?s}])
      assert picker.minibuffer.mode == :palette
      assert picker.minibuffer.sel == 2
      assert key(picker, {:alt, ?i}).minibuffer.sel == 1
      assert key(picker, {:alt, ?w}).minibuffer.sel == 2

      tree = %{state | tree_shown: true, focus: :tree}
      tree = put_in(tree.tree.rows, [%{path: "a.txt", dir?: false}, %{path: "lib", dir?: true}])
      tree = put_in(tree.tree.sel, 1)
      assert key(tree, {:alt, ?i}).tree.sel == 0
      assert key(tree, {:alt, ?w}).tree.sel == 1

      settings = key(state, {:alt, ?y}) |> key({:alt, ?d}) |> keys([{:alt, ?s}, {:alt, ?s}])
      assert key(settings, {:alt, ?i}).settings.sel == settings.settings.sel - 1
    end

    test "the settings view's footer names the keys the bindings give", %{state: state} do
      footer = fn keys ->
        view = %{Loop.Settings.open() | tab: :keys}
        screen = Loop.Settings.draw(view, [], state.theme.palette, {120, 10}, keys)
        Enum.map_join(0..119, &Geex.Screen.get_cell(screen, &1, 9).char) |> String.trim()
      end

      assert footer.(Bindings.defaults()) =~ "← → or Alt+A Alt+D tabs · Esc or Alt+Y closes"

      keys = Bindings.defaults() |> Map.delete({:alt, ?y}) |> Map.put({:ctrl, ?e}, :settings)
      keys = Map.drop(keys, [{:alt, ?a}, {:alt, ?d}])
      assert footer.(keys) =~ "← → tabs · Esc or Ctrl-E closes"
    end

    test "a chord bound to `indent` indents as Tab does: the tab size, the file's kind", %{
      state: state,
      buf: buf
    } do
      state = %{state | keys: Map.put(state.keys, {:ctrl, ?t}, :indent), tab_size: 4}
      _ = key(state, {:ctrl, ?t})
      assert text(buf) == "    hello world\nline 2\n"
    end

    test "the palette finds a command by its key, whole, first", %{state: state} do
      # Alt+E is `word forward`; Enter runs the top row.
      state = state |> key({:alt, ?i}) |> type("alt+e") |> key({:key, :enter})
      assert cursor() == {0, 6}

      # Alt+S is `down`, not the Alt+Shift+… keys that start the same.
      _ = state |> key({:alt, ?i}) |> type("Alt+S") |> key({:key, :enter})
      assert cursor() == {1, 6}
    end

    test "the key help and the Commands tab show the moved key", %{state: state} do
      state = moved(state) |> key({:alt, ?y})
      ctx = %{keys: state.keys}
      rows = Loop.Settings.rows(%{state.settings | tab: :commands, query: "up"}, ctx)
      assert %{cells: ["up", "Alt+I ↑", _]} = Enum.find(rows, &(hd(&1.cells) == "up"))
    end
  end
end
