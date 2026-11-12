defmodule Geex.Loop.EditingKeysTest do
  # ADR-0052 through the loop's own handle_info/2, no terminal: duplicate, select a character, a
  # word or a line, the matching bracket, comment, and moving lines and selected text, each one
  # recorded edit. Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Selection, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_editing_keys_#{Geex.Fixtures.uniq()}")
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

  defp run(state, command) do
    state = key(state, {:alt, ?m})
    state = Enum.reduce(String.graphemes(command), state, &key(&2, {:char, &1}))
    key(state, {:key, :enter})
  end

  defp sel(%{selection: %Selection{anchor: a, active: b}}), do: {a, b}
  defp sel(_state), do: nil

  describe "Alt+2 duplicates (§1)" do
    test "the cursor's line, below; the cursor goes to the copy; one undo each", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "one\ntwo\n", {0, 2})
      state = key(state, {:alt, ?2})
      assert Buffer.get_text(buf) == "one\none\ntwo\n"
      assert cursor() == {1, 2}

      state = key(state, {:alt, ?2})
      assert Buffer.get_text(buf) == "one\none\none\ntwo\n"
      assert cursor() == {2, 2}
      assert length(Buffer.history(buf)) == 2

      _ = key(state, {:alt, ?z})
      assert Buffer.get_text(buf) == "one\none\ntwo\n"
    end

    test "a selection's lines, the selection moved onto the copy", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "a\nb\nc\n")
      state = keys(state, [{:alt, ?9}, {:alt, ?9}])
      assert sel(state) == {{0, 0}, {2, 0}}
      state = key(state, {:alt, ?2})
      assert Buffer.get_text(buf) == "a\nb\na\nb\nc\n"
      assert sel(state) == {{2, 0}, {4, 0}}
    end
  end

  describe "Alt+7, Alt+8, Alt+9 select (§2, §3)" do
    test "a character, then one more", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "abc\n", {0, 1})
      state = key(state, {:alt, ?7})
      assert sel(state) == {{0, 1}, {0, 2}}
      state = key(state, {:alt, ?7})
      assert sel(state) == {{0, 1}, {0, 3}}
      assert cursor() == {0, 3}
    end

    test "a word (space to space), then the next; typing replaces it", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "foo(bar, baz) end\n", {0, 5})
      state = key(state, {:alt, ?8})
      assert sel(state) == {{0, 0}, {0, 8}}
      state = key(state, {:alt, ?8})
      assert sel(state) == {{0, 0}, {0, 13}}
      _ = key(state, {:char, "x"})
      assert Buffer.get_text(buf) == "x end\n"
    end

    test "the whole line wherever the cursor is, then the next; Tab indents them", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "a\nb\nc\n", {0, 1})
      state = key(state, {:alt, ?9})
      assert sel(state) == {{0, 0}, {1, 0}}
      state = key(state, {:alt, ?9})
      assert sel(state) == {{0, 0}, {2, 0}}
      _ = key(state, {:key, :tab})
      assert Buffer.get_text(buf) == "  a\n  b\nc\n"
    end

    test "after Alt+S with no motion, Alt+8 selects the word at the cursor", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "ab cd\n", {0, 4})
      state = keys(state, [{:alt, ?s}, {:alt, ?8}])
      assert sel(state) == {{0, 3}, {0, 5}}
    end
  end

  describe "Alt+\\ goes to the matching bracket (§4)" do
    test "on a bracket, to its pair; elsewhere, to the one around; a selection extends", %{
      dir: dir
    } do
      {state, buf} = open(dir, "a.txt", "f(a, [b]) {\n  x\n}\n", {0, 1})
      state = key(state, {:alt, ?\\})
      assert cursor() == {0, 8}
      state = key(state, {:alt, ?\\})
      assert cursor() == {0, 1}

      Session.set_cursor({1, 2})
      state = keys(state, [{:alt, ?s}, {:alt, ?\\}])
      assert cursor() == {0, 10}
      assert sel(state) == {{1, 2}, {0, 10}}
      assert Buffer.history(buf) == []
    end
  end

  describe "Alt+/ comments (§5)" do
    test "the cursor's line, as the file comments, and back", %{dir: dir} do
      {state, buf} = open(dir, "a.ex", "  x = 1\n", {0, 4})
      state = key(state, {:alt, ?/})
      assert Buffer.get_text(buf) == "  # x = 1\n"
      assert cursor() == {0, 6}
      _ = key(state, {:alt, ?/})
      assert Buffer.get_text(buf) == "  x = 1\n"
      assert cursor() == {0, 4}
    end

    test "a selection's lines at their smallest indent; blank lines alone; one undo", %{
      dir: dir
    } do
      {state, buf} = open(dir, "a.js", "if (a) {\n\n  b()\n}\n")
      state = keys(state, [{:alt, ?9}, {:alt, ?9}, {:alt, ?9}])
      state = key(state, {:alt, ?/})
      assert Buffer.get_text(buf) == "// if (a) {\n\n//   b()\n}\n"
      assert sel(state) == {{0, 0}, {3, 0}}
      assert length(Buffer.history(buf)) == 1
    end

    test "a file with no line comment says so and changes nothing", %{dir: dir} do
      {state, buf} = open(dir, "a.css", "a { }\n")
      state = key(state, {:alt, ?/})
      assert state.notice == "no line comment known for a.css"
      assert Buffer.history(buf) == []
    end

    test "typed as `comment`", %{dir: dir} do
      {state, buf} = open(dir, "a.py", "x\n")
      _ = run(state, "comment")
      assert Buffer.get_text(buf) == "# x\n"
    end
  end

  describe "Alt+Shift+I/K move lines (§6)" do
    test "the cursor's line, with or without a selection; one undo each", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "a\nb\nc\n", {0, 1})
      state = key(state, {:alt, ?K})
      assert Buffer.get_text(buf) == "b\na\nc\n"
      assert cursor() == {1, 1}
      state = key(state, {:alt, ?K})
      assert Buffer.get_text(buf) == "b\nc\na\n"
      # The empty line after the last line break isn't one to swap with.
      state = key(state, {:alt, ?K})
      assert Buffer.get_text(buf) == "b\nc\na\n"
      assert length(Buffer.history(buf)) == 2

      _ = key(state, {:alt, ?I})
      assert Buffer.get_text(buf) == "b\na\nc\n"
    end

    test "a selection of lines moves whole, and stays selected", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "a\nb\nc\nd\n")
      state = keys(state, [{:alt, ?9}, {:alt, ?9}])
      state = key(state, {:alt, ?K})
      assert Buffer.get_text(buf) == "c\na\nb\nd\n"
      assert sel(state) == {{1, 0}, {3, 0}}
      state = key(state, {:alt, ?I})
      assert Buffer.get_text(buf) == "a\nb\nc\nd\n"
      assert sel(state) == {{0, 0}, {2, 0}}
    end

    test "typed as `move down`", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "a\nb\n")
      _ = run(state, "move down")
      assert Buffer.get_text(buf) == "b\na\n"
    end
  end

  describe "Alt+Shift+J/L/U/O/H/; move selected text (§7)" do
    test "swapped with the word before; the selection stays on it", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "one two three\n", {0, 9})
      state = keys(state, [{:alt, ?8}])
      assert sel(state) == {{0, 8}, {0, 13}}
      state = key(state, {:alt, ?U})
      assert Buffer.get_text(buf) == "one three two\n"
      assert sel(state) == {{0, 4}, {0, 9}}
      state = key(state, {:alt, ?O})
      assert Buffer.get_text(buf) == "one two three\n"
      assert length(Buffer.history(buf)) == 2
      _ = state
    end

    test "a character at a time, and to the line's ends", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "  ab cd\n", {0, 5})
      state = keys(state, [{:alt, ?7}, {:alt, ?7}])
      state = key(state, {:alt, ?J})
      assert Buffer.get_text(buf) == "  abcd \n"
      state = key(state, {:alt, ?H})
      assert Buffer.get_text(buf) == "  cdab \n"
      assert sel(state) == {{0, 2}, {0, 4}}
      state = key(state, {:alt, ?:})
      assert Buffer.get_text(buf) == "  ab cd\n"
      state = key(state, {:alt, ?L})
      assert Buffer.get_text(buf) == "  ab cd\n"
      assert sel(state) == {{0, 5}, {0, 7}}
    end

    test "a backwards selection stays backwards, its cursor at the text's start", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "one two three\n", {0, 13})
      # Alt+S at the end, then a word back: the cursor before `three`, the anchor after it.
      state = keys(state, [{:alt, ?s}, {:alt, ?u}])
      assert sel(state) == {{0, 13}, {0, 8}}
      state = key(state, {:alt, ?U})
      assert Buffer.get_text(buf) == "one three two\n"
      assert sel(state) == {{0, 9}, {0, 4}}
      assert cursor() == {0, 4}
    end

    test "with no selection, or one across lines, they do nothing", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "ab cd\nef\n", {0, 1})

      state =
        keys(state, [{:alt, ?J}, {:alt, ?L}, {:alt, ?U}, {:alt, ?O}, {:alt, ?H}, {:alt, ?:}])

      assert cursor() == {0, 1}
      state = keys(state, [{:alt, ?s}, {:alt, ?k}])
      _ = keys(state, [{:alt, ?J}, {:alt, ?L}, {:alt, ?U}, {:alt, ?O}])
      assert Buffer.history(buf) == []
    end
  end

  describe "Caps Lock (§8)" do
    # Alt+Shift+K (Caps Lock with Alt+K), or another move key, does there what the plain key
    # does, and moves something.
    defp same_as_plain(state, what, c \\ ?k, moves? \\ true) do
      plain = key(state, {:alt, c})
      shifted = key(state, {:alt, c - 32})
      assert what.(shifted) == what.(plain)
      if moves?, do: assert(what.(plain) != what.(state))
    end

    test "in the output pane, the settings view and a preview, a move is its motion", %{dir: dir} do
      {state, buf} = open(dir, "a.md", Enum.map_join(1..60, &"line #{&1}\n"))
      before = Buffer.get_text(buf)

      out = Geex.Loop.Output.new("ls", :show, 0) |> Geex.Loop.Output.append("a\nb\nc\n")
      # The output pane's highlight starts on its last row: up moves it.
      same_as_plain(%{state | output: out, focus: :output}, & &1.output.sel, ?i)

      same_as_plain(key(state, {:alt, ?y}), & &1.settings)

      preview = state |> Loop.toggle_preview() |> key({:alt, ?>})
      assert Geex.Loop.Panes.preview?(Geex.Loop.Panes.current(preview.panes))
      # Its rendering comes later, so there may be nothing to scroll yet; a move it refused would
      # say the preview is read-only.
      same_as_plain(preview, &{&1.panes, &1.notice}, ?k, false)

      assert Buffer.get_text(buf) == before
    end

    test "in the edits pane, a move is its motion", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "x\n")

      for f <- ["b.txt", "c.txt"] do
        File.write!(Path.join(dir, f), "y\n")
        Geex.Edits.saved(Path.join(dir, f))
      end

      _ = Geex.Edits.rows()
      same_as_plain(%{state | edits_shown: true, focus: :edits, edits_sel: 0}, & &1.edits_sel)
    end

    test "in the command line, the move chords move its cursor as before", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "x\n")
      state = key(state, {:alt, ?m})
      state = Enum.reduce(String.graphemes("abc"), state, &key(&2, {:char, &1}))
      state = keys(state, [{:alt, ?J}, {:char, "Z"}])
      assert state.minibuffer.input == "abZc"
    end
  end
end
