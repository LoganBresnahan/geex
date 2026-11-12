defmodule Geex.Loop.AssistTest do
  # The typing assists (roadmap item 19, ADR-0045) through the loop's own handle_info/2, with no
  # terminal: pairs closed as you type them, and the indent kept on Enter. Uses the global
  # Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_assist_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir, state: %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}}
  end

  defp open(state, dir, name, text, cursor \\ {0, 0}) do
    path = Path.join(dir, name)
    File.write!(path, text)
    {:ok, pid} = Session.open_file(path)
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    Session.set_cursor(cursor)
    {state, pid}
  end

  # A key as the live loop gets it: the key, then the buffer's change notifications it caused
  # (the review of item 19: a test that never delivers them can't see what they undo).
  defp key(state, event), do: state |> deliver(event) |> flush()

  defp deliver(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp flush(state) do
    receive do
      {:geex_buffer_change, _, _, _} = m ->
        {:noreply, state} = Loop.handle_info(m, state)
        flush(state)
    after
      0 -> state
    end
  end

  # Keys that arrive together (one read, or a busy loop): all of them, then the notifications.
  defp burst(state, keys), do: keys |> Enum.reduce(state, &deliver(&2, &1)) |> flush()

  defp type(state, text), do: Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))
  defp text(buf), do: Buffer.get_text(buf)
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  describe "closing pairs" do
    test "an opener comes with its closer; the closer typed steps over it; one Alt+Z", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "a.ex", "f", {0, 1})
      state = type(state, "(")
      assert {text(buf), cursor()} == {"f()", {0, 2}}
      state = type(state, "x)")
      assert {text(buf), cursor()} == {"f(x)", {0, 4}}

      state = key(state, {:alt, ?z}) |> key({:alt, ?z})
      assert text(buf) == "f"
      _ = state
    end

    test "before a word, just the opener; quotes after a letter, alone", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "b.txt", "word", {0, 0})
      state = type(state, "[")
      assert text(buf) == "[word"

      Session.set_cursor({0, 5})
      type(state, " don't")
      assert text(buf) == "[word don't"
    end

    test "quotes pair at a line's end; three backticks make a fence", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "c.md", "", {0, 0})
      state = type(state, "\"")
      assert {text(buf), cursor()} == {"\"\"", {0, 1}}
      state = type(state, "\"")
      assert {text(buf), cursor()} == {"\"\"", {0, 2}}

      state = key(state, {:key, :enter})
      type(state, "```")
      assert text(buf) == "\"\"\n```"
    end

    test "Backspace between an empty pair deletes both", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "d.js", "x = ", {0, 4})
      state = type(state, "{")
      assert text(buf) == "x = {}"
      key(state, {:key, :backspace})
      assert {text(buf), cursor()} == {"x = ", {0, 4}}
    end

    test "an opener or a quote over a selection wraps it, keeping it selected", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "e.txt", "say hello now", {0, 4})
      state = Enum.reduce([{:alt, ?s} | List.duplicate({:alt, ?l}, 5)], state, &key(&2, &1))
      state = type(state, "\"")
      assert text(buf) == "say \"hello\" now"

      assert {state.selection.anchor, state.selection.active, cursor()} ==
               {{0, 5}, {0, 10}, {0, 10}}

      # Another wrap round the same selection.
      type(state, "(")
      assert text(buf) == "say \"(hello)\" now"
    end

    test "off, each key types only itself", %{state: state, dir: dir} do
      {state, buf} = open(%{state | auto_close: false}, dir, "f.txt", "", {0, 0})
      state |> type("(\"") |> key({:key, :backspace})
      assert text(buf) == "("
    end
  end

  describe "keeping the indent" do
    test "Enter keeps the line's indent; one more after an opener; a pair opens up", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "g.ex", "  x", {0, 3})
      state = key(state, {:key, :enter})
      assert {text(buf), cursor()} == {"  x\n  ", {1, 2}}

      state = type(state, "f(")
      assert text(buf) == "  x\n  f()"
      key(state, {:key, :enter})
      assert text(buf) == "  x\n  f(\n    \n  )"
      assert cursor() == {2, 4}
    end

    test "Enter on a line of only indent clears it; Backspace takes a level", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "h.py", "def f():", {0, 8})
      state = key(state, {:key, :enter})
      assert text(buf) == "def f():\n  "
      state = key(state, {:key, :enter})
      assert {text(buf), cursor()} == {"def f():\n\n  ", {2, 2}}

      state = %{state | tab_size: 4}
      Session.set_cursor({2, 2})
      state = type(state, "  ")
      assert text(buf) == "def f():\n\n    "
      key(state, {:key, :backspace})
      assert {text(buf), cursor()} == {"def f():\n\n", {2, 0}}
    end

    test "a tab-indented file gets a tab", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "i.go", "func f() {\n\tx := 1\n}", {1, 7})
      key(state, {:key, :enter})
      assert {text(buf), cursor()} == {"func f() {\n\tx := 1\n\t\n}", {2, 1}}
    end

    test "off, Enter is a bare line break, and Backspace one space", %{state: state, dir: dir} do
      {state, buf} = open(%{state | auto_indent: false}, dir, "j.ex", "  x", {0, 3})
      state = key(state, {:key, :enter})
      assert text(buf) == "  x\n"
      Session.set_cursor({0, 2})
      key(state, {:key, :backspace})
      assert text(buf) == " x\n"
    end
  end

  # Found while dogfooding item 19: a terminal paste typed key by key got the assists (doubled
  # indents, an extra `}`). A bracketed paste is inserted as it is, as one edit.
  describe "a paste" do
    test "goes in as it is: no closer added, no indent added, line breaks as \\n", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "p.js", "", {0, 0})
      state = key(state, {:paste, "if (x) {\r  y(\"a\");\r}\r"})
      assert text(buf) == "if (x) {\n  y(\"a\");\n}\n"
      assert cursor() == {3, 0}
      assert length(Buffer.history(buf)) == 1

      key(state, {:alt, ?z})
      assert text(buf) == ""
    end

    test "replaces a selection; into the minibuffer, its first line", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "q.txt", "abc", {0, 0})
      state = Enum.reduce([{:alt, ?s}, {:alt, ?l}], state, &key(&2, &1))
      state = key(state, {:paste, "XY"})
      assert text(buf) == "XYbc"

      state = state |> key({:alt, ?m}) |> key({:paste, "line 9\nmore"})
      assert Geex.Minibuffer.value(state.minibuffer) == "line 9"
    end
  end

  # The review of item 19, each finding as it was run.
  describe "the review's cases" do
    test "#2: a closer already in the file is typed, never stepped over", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "r1.js", "foo(bar)", {0, 4})
      state = type(state, "baz(")
      assert text(buf) == "foo(baz(bar)"
      state = Enum.reduce(1..3, state, fn _, acc -> key(acc, {:key, :right}) end)
      type(state, ")")
      assert text(buf) == "foo(baz(bar))"

      {state, buf} = open(state, dir, "r2.js", "[\"b\"]", {0, 1})
      type(state, "\"a\", ")
      assert text(buf) == "[\"a\", \"b\"]"
    end

    test "#1: a quote that closes a string isn't paired", %{state: state, dir: dir} do
      {state, py} = open(state, dir, "r3.py", "", {0, 0})
      state = type(state, "print(f\"{x}\")")
      assert text(py) == "print(f\"{x}\")"

      {state, js} = open(state, dir, "r4.js", "", {0, 0})
      type(state, "css`color: red;`")
      assert text(js) == "css`color: red;`"
    end

    test "#5: with Alt+S's selection live, a closer is typed, not stepped over", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "r5.ex", "f(a)", {0, 3})
      state = state |> key({:alt, ?s}) |> type(")")
      assert state.selection == nil
      # Typed where the cursor was, before the `)` already there.
      type(state, ";")
      assert text(buf) == "f(a);)"
    end

    test "#3: in a CRLF file the CR is the line's end and breaks are CRLF", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "r6.js", "foo\r\nbar", {0, 3})
      state = type(state, "(")
      assert text(buf) == "foo()\r\nbar"
      state = key(state, {:key, :enter})
      assert text(buf) == "foo(\r\n  \r\n)\r\nbar"

      {state, buf} = open(state, dir, "r7.txt", "a\r\nb\r\n", {0, 1})
      key(state, {:paste, "X\nY\n"})
      assert text(buf) == "aX\r\nY\r\n\r\nb\r\n"
    end

    test "#4: wrapping lines an agent wrote leaves the line between theirs", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "r8.txt", "l0\nl1\nl2\nl3\nl4\n", {0, 0})

      {:ok, agent_edit} =
        Geex.Commands.Replace.parse(%{
          start_line: 1,
          start_col: 0,
          end_line: 3,
          end_col: 2,
          text: "A1\nA2\nA3"
        })

      {:ok, _} =
        Buffer.dispatch(buf, Geex.Command.put_meta(agent_edit, Geex.Command.Meta.new(:external)))

      agent = Enum.at(Buffer.snapshot(buf).blame, 2)

      Session.set_cursor({3, 2})
      state = %{state | selection: Geex.Selection.new({1, 0}) |> Geex.Selection.extend({3, 2})}
      state = type(state, "(")
      assert text(buf) == "l0\n(A1\nA2\nA3)\nl4\n"
      assert Enum.at(Buffer.snapshot(buf).blame, 2) == agent
      assert {state.selection.anchor, state.selection.active} == {{1, 1}, {3, 2}}
    end

    test "#8: `:` opens a block in Python, not in notes", %{state: state, dir: dir} do
      {state, md} = open(%{state | tab_size: 4}, dir, "notes.md", "Ingredients:", {0, 12})
      state = key(state, {:key, :enter})
      assert text(md) == "Ingredients:\n"

      {state, py} = open(state, dir, "s.py", "def f():", {0, 8})
      key(state, {:key, :enter})
      assert text(py) == "def f():\n    "
    end

    test "#6a: a long paste into the minibuffer is one insert, cut to 4096", %{
      state: state,
      dir: dir
    } do
      {state, _buf} = open(state, dir, "m.txt", "", {0, 0})
      state = key(state, {:alt, ?m})
      {us, state} = :timer.tc(fn -> key(state, {:paste, String.duplicate("a", 20_000)}) end)
      assert String.length(Geex.Minibuffer.value(state.minibuffer)) == 4096
      assert us < 500_000
    end

    test "#10f, #10g: control bytes are dropped; a pasted combining mark doesn't move the cursor",
         %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "r9.txt", "", {0, 0})
      state = key(state, {:paste, "\e[31mred\e[0m\u0000"})
      assert text(buf) == "[31mred[0m"

      {state, buf} = open(state, dir, "r10.txt", "eabc", {0, 1})
      state |> key({:paste, "́"}) |> type("x")
      assert text(buf) == "éxabc"
    end

    test "data and Makefiles: no indent copied in a .tsv; a Makefile.am gets tabs", %{
      state: state,
      dir: dir
    } do
      {state, tsv} = open(state, dir, "d.tsv", "\tb\tc", {0, 4})
      state = key(state, {:key, :enter})
      assert text(tsv) == "\tb\tc\n"

      {state, am} = open(state, dir, "Makefile.am", "", {0, 0})
      key(state, {:key, :tab})
      assert text(am) == "\t"
    end

    test "Backspace on a pair typed by hand takes only the opener", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "r11.ex", "f()", {0, 2})
      key(state, {:key, :backspace})
      assert text(buf) == "f)"
    end

    test "the settings search takes a paste's first line" do
      view = %{Geex.Loop.Settings.open() | tab: :commands}
      {view, :none} = Geex.Loop.Settings.key(view, {:paste, "exit\nmore"}, [], 30)
      assert view.query == "exit"
    end
  end

  # The re-verify of item 19, each with the notifications delivered.
  describe "the re-verify's cases" do
    test "#1: keys that arrive together keep the pair geex closed", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "v1.ex", "f", {0, 1})
      state = burst(state, [{:char, "("}, {:char, "x"}])
      type(state, ")")
      assert text(buf) == "f(x)"
    end

    test "#2: a wrap keeps its selection, so a second wraps again", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "v2.txt", "say hello now", {0, 4})
      state = Enum.reduce([{:alt, ?s} | List.duplicate({:alt, ?l}, 5)], state, &key(&2, &1))
      state = type(state, "\"")
      assert state.selection != nil
      type(state, "(")
      assert text(buf) == "say \"(hello)\" now"
    end

    test "#3: a quote inside the other kind of string isn't counted", %{state: state, dir: dir} do
      {state, py} = open(state, dir, "v3.py", "", {0, 0})
      state = type(state, "x = \"it's\" + ': '")
      assert text(py) == "x = \"it's\" + ': '"

      {state, py} = open(state, dir, "v4.py", "", {0, 0})
      type(state, "print(\"Don't\", end=' ')")
      assert text(py) == "print(\"Don't\", end=' ')"
    end

    test "#4: in a CRLF file End stops before the CR; joins and breaks keep CRLF", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "v5.txt", "foo\r\nbar", {0, 0})
      state = key(state, {:key, :end})
      assert cursor() == {0, 3}
      state = key(state, {:paste, "X\nY"})
      assert text(buf) == "fooX\r\nY\r\nbar"

      {state, buf} = open(state, dir, "v6.txt", "a\r\nb\r\nc", {1, 0})
      state = key(state, {:key, :backspace})
      assert text(buf) == "ab\r\nc"
      state = key(state, {:key, :end}) |> key({:key, :delete})
      assert text(buf) == "abc"

      {state, buf} = open(%{state | auto_indent: false}, dir, "v7.txt", "a\r\nb", {0, 1})
      key(state, {:key, :enter})
      assert text(buf) == "a\r\n\r\nb"
    end

    test "#5: saving, Esc or copying between keeps the pair", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "v8.ex", "", {0, 0})
      state = type(state, "f(a") |> key({:ctrl, ?o}) |> key({:key, :esc}) |> key({:alt, ?c})
      type(state, ")")
      assert text(buf) == "f(a)"
    end

    test "moving inside a pair keeps it; moving out drops it", %{state: state, dir: dir} do
      {state, buf} = open(state, dir, "v9.ex", "", {0, 0})
      state = type(state, "(ab") |> key({:key, :left}) |> key({:key, :right})
      state = type(state, ")")
      assert text(buf) == "(ab)"

      {state, buf} = open(state, dir, "v10.ex", "", {0, 0})
      state = type(state, "(a") |> key({:key, :left}) |> key({:key, :left})
      state |> key({:key, :right}) |> key({:key, :right}) |> type(")")
      assert text(buf) == "(a))"
    end

    # The agent's change leaves a `)` exactly where geex's closer was: it's the agent's now, and
    # is typed again, not stepped over. The notification is delivered after the key arrives (a
    # busy loop), so only the version checked at the key can tell.
    test "a change from outside drops the pairs, even one whose notice comes late", %{
      state: state,
      dir: dir
    } do
      {state, buf} = open(state, dir, "v11.ex", "", {0, 0})
      state = type(state, "f(")

      {:ok, cmd} =
        Geex.Commands.Replace.parse(%{
          start_line: 0,
          start_col: 0,
          end_line: 0,
          end_col: 3,
          text: "(a)"
        })

      {:ok, _} =
        Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.new(:external)))

      Session.set_cursor({0, 2})
      state |> deliver({:char, ")"}) |> flush()
      assert text(buf) == "(a))"
    end
  end

  describe "indent with (roadmap item 19)" do
    test "a new Makefile or Go file gets tabs from Tab and Enter; others spaces", %{
      state: state,
      dir: dir
    } do
      {state, mk} = open(state, dir, "Makefile", "all:", {0, 4})
      state = key(state, {:key, :enter}) |> key({:key, :tab})
      # `all:` ends in `:`, so Enter indents a level (a tab); Tab adds another.
      assert text(mk) == "all:\n\t\t"

      {state, go} = open(state, dir, "main.go", "func f() {}", {0, 10})
      state = key(state, {:key, :enter})
      assert text(go) == "func f() {\n\t\n}"

      {state, py} = open(state, dir, "a.py", "", {0, 0})
      key(state, {:key, :tab})
      assert text(py) == "  "
    end

    test "the setting forces spaces or tabs, but a Makefile keeps its tabs", %{
      state: state,
      dir: dir
    } do
      {state, py} = open(%{state | indent_with: :tabs}, dir, "b.py", "", {0, 0})
      state = key(state, {:key, :tab})
      assert text(py) == "\t"

      {state, go} = open(%{state | indent_with: :spaces}, dir, "b.go", "", {0, 0})
      state = key(state, {:key, :tab})
      assert text(go) == "  "

      {state, mk} = open(state, dir, "rules.mk", "", {0, 0})
      key(state, {:key, :tab})
      assert text(mk) == "\t"
    end

    test "settings.json's indent_with; anything else is follow" do
      state = Loop.new_state(80, 24)
      assert Loop.apply_settings(state, %{"indent_with" => "tabs"}).indent_with == :tabs
      assert Loop.apply_settings(state, %{"indent_with" => "spaces"}).indent_with == :spaces
      assert Loop.apply_settings(state, %{"indent_with" => "both"}).indent_with == :follow
      assert Loop.apply_settings(state, %{}).indent_with == :follow
    end
  end

  test "settings.json's auto_close and auto_indent turn them off; on without" do
    state = Loop.new_state(80, 24)
    off = Loop.apply_settings(state, %{"auto_close" => false, "auto_indent" => false})
    assert {off.auto_close, off.auto_indent} == {false, false}
    on = Loop.apply_settings(state, %{})
    assert {on.auto_close, on.auto_indent} == {true, true}
  end
end
