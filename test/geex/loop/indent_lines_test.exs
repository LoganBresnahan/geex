defmodule Geex.Loop.IndentLinesTest do
  # ADR-0050 through the loop's own handle_info/2, no terminal: Tab indents a selection's lines,
  # Shift+Tab un-indents them (or the cursor's line), Alt+1 is the other kind, each one edit.
  # Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Selection, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_indent_lines_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # A file of `text` open in a fresh loop (tab size 2), the cursor at `cursor`.
  defp open(dir, name, text, cursor \\ {0, 0}) do
    path = Path.join(dir, name)
    File.write!(path, text)
    {:ok, pid} = Session.open_file(path)
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false, tab_size: 2}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    Session.set_cursor(cursor)
    {state, pid}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp keys(state, events), do: Enum.reduce(events, state, &key(&2, &1))
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  # Alt+S, then the motion keys given: a selection from the cursor.
  defp select(state, moves), do: keys(state, [{:alt, ?s} | moves])

  defp run(state, command) do
    state = key(state, {:alt, ?m})
    state = Enum.reduce(String.graphemes(command), state, &key(&2, {:char, &1}))
    key(state, {:key, :enter})
  end

  describe "Tab over a selection (§1)" do
    test "indents every line it touches, but an empty one; the selection stays; one undo", %{
      dir: dir
    } do
      {state, buf} = open(dir, "a.txt", "one\n\ntwo\nthree\n", {0, 1})
      # From {0, 1} down two lines (to column 0: a cursor set directly has no goal column) and
      # right one: {2, 1}.
      state = select(state, [{:alt, ?k}, {:alt, ?k}, {:alt, ?l}])
      assert %Selection{anchor: {0, 1}, active: {2, 1}} = state.selection
      state = key(state, {:key, :tab})

      assert Buffer.get_text(buf) == "  one\n\n  two\nthree\n"
      assert %Selection{anchor: {0, 3}, active: {2, 3}} = state.selection
      assert cursor() == {2, 3}
      assert length(Buffer.history(buf)) == 1

      # Again: another level, still selected.
      state = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "    one\n\n    two\nthree\n"
      assert %Selection{anchor: {0, 5}, active: {2, 5}} = state.selection

      _ = key(state, {:alt, ?z})
      assert Buffer.get_text(buf) == "  one\n\n  two\nthree\n"
    end

    test "blame marks the indented lines, not the blank one between (ADR-0032's amendment)", %{
      dir: dir
    } do
      {state, buf} = open(dir, "a.txt", "one\n\ntwo\n")
      state = select(state, [{:alt, ?k}, {:alt, ?k}, {:alt, ?l}])
      _ = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "  one\n\n  two\n"
      blame = :sys.get_state(buf).history.blame
      assert Enum.map(blame, &(&1 != nil)) == [true, false, true, false]
    end

    test "a last line reached only at column 0 is left out; whole lines stay whole", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "one\ntwo\nthree\n")
      state = select(state, [{:alt, ?k}, {:alt, ?k}])
      state = key(state, {:key, :tab})

      assert Buffer.get_text(buf) == "  one\n  two\nthree\n"
      assert %Selection{anchor: {0, 0}, active: {2, 0}} = state.selection
    end

    test "follows the file: tabs in a tab-indented one", %{dir: dir} do
      {state, buf} = open(dir, "t.go", "func f() {\n\tx := 1\n}\n")
      state = select(state, [{:alt, ?k}, {:alt, ?k}, {:alt, ?;}])
      _ = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "\tfunc f() {\n\t\tx := 1\n\t}\n"
    end

    test "a CRLF file keeps its line ends", %{dir: dir} do
      {state, buf} = open(dir, "w.txt", "a\r\nb\r\nc\r\n")
      state = select(state, [{:alt, ?k}, {:alt, ?l}])
      _ = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "  a\r\n  b\r\nc\r\n"
    end

    test "with no selection, Tab inserts at the cursor as before", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "ab\n", {0, 1})
      _ = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "a  b\n"
      assert cursor() == {0, 3}
    end
  end

  describe "Shift+Tab un-indents, always (§2)" do
    test "a selection's lines: a tab, or spaces back to the previous tab stop", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "\tone\n   two\n    three\nfour\n", {0, 2})
      # Down three lines to column 0 of `four`, which the selection doesn't take.
      state = select(state, [{:alt, ?k}, {:alt, ?k}, {:alt, ?k}])
      state = key(state, {:key, :shift_tab})

      assert Buffer.get_text(buf) == "one\n  two\n  three\nfour\n"
      assert %Selection{anchor: {0, 1}, active: {3, 0}} = state.selection
      assert length(Buffer.history(buf)) == 1
    end

    test "the cursor's line with no selection; the cursor moves with its text", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "    x\ny\n", {0, 5})
      state = key(state, {:key, :shift_tab})
      assert Buffer.get_text(buf) == "  x\ny\n"
      assert cursor() == {0, 3}

      # A cursor inside the indent goes to the line's start, not past it.
      Session.set_cursor({0, 1})
      _ = key(state, {:key, :shift_tab})
      assert Buffer.get_text(buf) == "x\ny\n"
      assert cursor() == {0, 0}
    end

    test "nothing to take changes nothing and records nothing", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "x\ny\n", {0, 1})
      state = key(state, {:key, :shift_tab})
      state = select(state, [{:alt, ?k}])
      _ = key(state, {:key, :shift_tab})

      assert Buffer.get_text(buf) == "x\ny\n"
      assert Buffer.history(buf) == []
    end

    test "typed, `unindent` and `indent` do what their keys do", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "  x\n", {0, 3})
      state = run(state, "unindent")
      assert Buffer.get_text(buf) == "x\n"
      _ = run(state, "outdent")
      assert Buffer.get_text(buf) == "x\n"
    end
  end

  describe "the edges (mod-verify's review)" do
    test "a backwards selection, its anchor after its end", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "one\ntwo\nthree\n", {2, 2})
      state = select(state, [{:alt, ?i}, {:alt, ?i}])
      assert %Selection{anchor: {2, 2}, active: {0, _}} = state.selection
      state = key(state, {:key, :tab})

      assert Buffer.get_text(buf) == "  one\n  two\n  three\n"
      assert %Selection{anchor: {2, 4}} = state.selection
    end

    test "a last changed line holding é and an emoji", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "a\n  é 👍🏽\n")
      state = select(state, [{:alt, ?k}, {:alt, ?l}])
      state = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "  a\n    é 👍🏽\n"
      _ = key(state, {:key, :shift_tab})
      assert Buffer.get_text(buf) == "a\n  é 👍🏽\n"
    end

    test "un-indenting follows the tab size", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "      x\n", {0, 7})
      state = key(%{state | tab_size: 4}, {:key, :shift_tab})
      assert Buffer.get_text(buf) == "    x\n"
      _ = key(state, {:key, :shift_tab})
      assert Buffer.get_text(buf) == "x\n"
    end

    test "a blank line, only whitespace, gains none", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "a\n   \nb\n")
      state = select(state, [{:alt, ?k}, {:alt, ?k}, {:alt, ?l}])
      _ = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "  a\n   \n  b\n"
    end

    test "Tab then Shift+Tab gives a blank line back: neither touches it", %{dir: dir} do
      text = "def f():\n    a\n    \n    b\n"
      {state, buf} = open(dir, "a.py", text)
      state = key(state, {:cmd, :select_all})
      state = key(state, {:key, :tab})
      _ = key(state, {:key, :shift_tab})
      assert Buffer.get_text(buf) == text
    end

    test "the goal column follows the cursor", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "    abc\nxxxxxxxxxx\n", {0, 6})
      state = key(state, {:key, :shift_tab})
      assert cursor() == {0, 4}
      _ = key(state, {:alt, ?k})
      assert cursor() == {1, 4}
    end

    test "a collapsed selection is no selection: Tab inserts at the cursor", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "ab\ncd\n", {0, 1})
      state = key(state, {:alt, ?s})
      _ = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "a  b\ncd\n"
    end

    test "a Shift+Tab that changes nothing keeps the closer typed for you", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "\n")
      state = keys(state, Enum.map(String.graphemes("alpha("), &{:char, &1}))
      assert Buffer.get_text(buf) == "alpha()\n"
      state = key(state, {:key, :shift_tab})
      _ = key(state, {:char, ")"})
      assert Buffer.get_text(buf) == "alpha()\n"
    end
  end

  describe "Alt+1 is the other kind (§5)" do
    test "a tab at the cursor where Tab gives spaces; over a selection, its lines", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "ab\ncd\n", {0, 1})
      state = key(state, {:alt, ?1})
      assert Buffer.get_text(buf) == "a\tb\ncd\n"
      assert cursor() == {0, 2}

      Session.set_cursor({0, 0})
      state = select(state, [{:alt, ?k}, {:alt, ?l}])
      _ = key(state, {:alt, ?1})
      assert Buffer.get_text(buf) == "\ta\tb\n\tcd\n"
    end

    test "spaces where Tab gives a tab, whatever decided that", %{dir: dir} do
      for {name, text, with} <- [
            {"u.go", "", :file},
            {"Makefile", "", :file},
            {"t.c", "\tx\n", :file},
            {"v.py", "", :tabs}
          ] do
        {state, buf} = open(dir, name, text)
        state = if with == :tabs, do: %{state | indent_with: :tabs}, else: state
        _ = key(%{state | tab_size: 4}, {:alt, ?1})
        assert Buffer.get_text(buf) == "    " <> text, name
        assert cursor() == {0, 4}
      end
    end

    test "typed as `indent other`", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "ab\n", {0, 1})
      _ = run(state, "indent other")
      assert Buffer.get_text(buf) == "a\tb\n"
    end
  end
end
