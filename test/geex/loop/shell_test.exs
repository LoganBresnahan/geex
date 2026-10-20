defmodule Geex.Loop.ShellTest do
  # `!`, `!!`, `|`, the output pane and the minibuffer's history (ADR-0042), through the loop's
  # own handle_info/2 with real `sh` commands; the runner's answers are delivered by hand, as
  # the tree's are in panes_test. Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Minibuffer, Selection, Session}
  alias Geex.Loop.{Output, Verbs}
  alias Geex.Minibuffer.Recall

  doctest Geex.Loop.Output
  doctest Geex.Minibuffer.Recall

  setup do
    root = Path.join(System.tmp_dir!(), "geex_loopshell_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "one\ntwo\nthree\n")
    File.write!(Path.join(root, "notes.txt"), "c\nb\na\nkeep\n")
    Session.set_start(root)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp type(state, text), do: Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))

  defp typed(state, line), do: state |> key({:alt, ?m}) |> type(line) |> key({:key, :enter})

  defp editing(path) do
    {:ok, pid} = Session.open_file(path)
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, Loop.new_state(120, 30))
    {state, pid}
  end

  # Deliver the runner's messages until the command has ended.
  defp ran(%{shell: nil} = state), do: state

  defp ran(%{shell: %{pid: pid}} = state) do
    assert_receive {:geex_shell, ^pid, _} = msg, 10_000
    {:noreply, state} = Loop.handle_info(msg, state)
    ran(state)
  end

  describe "parsing" do
    test "! and | keep the command as typed; !! is the last again; bare ones are unknown" do
      assert Verbs.parse("!mix test --only Foo") == {:shell, "mix test --only Foo"}
      assert Verbs.parse("! git log -3 ") == {:shell, "git log -3"}
      assert Verbs.parse("!!") == :shell_again
      assert Verbs.parse("|sort -r") == {:pipe, "sort -r"}
      assert Verbs.parse("!") == :unknown
      assert Verbs.parse("|  ") == :unknown
    end
  end

  describe "the output pane" do
    test "it follows the output at the bottom, and stops when moved up" do
      out = Output.new("seq", :show, 0) |> Output.append("1\n2\n3\n")
      assert {out.sel, out.follow} == {2, true}
      out = Output.move(out, -1) |> Output.append("4\n")
      assert {out.sel, out.follow} == {1, false}
      out = Output.move(out, 5) |> Output.append("5\n")
      assert {out.sel, out.follow} == {4, true}
      assert Output.settle(out, 2).top == 3
    end

    test "only the newest lines are kept" do
      out = Output.new("yes", :show, 0, max: 10)
      out = Enum.reduce(1..30, out, &Output.append(&2, "#{&1}\n"))
      assert Output.size(out) <= 11
      assert Output.line(out, Output.size(out) - 1) == "30"
    end
  end

  describe "! in the loop" do
    test "shows the output, the exit, and Enter on path:line opens the file there",
         %{root: root} do
      {state, _pid} = editing(Path.join(root, "notes.txt"))
      state = typed(state, "!pwd; echo 'lib/a.ex:3:2: warning'; exit 4")
      assert state.focus == :output
      state = ran(state)

      assert %Output{status: {:exit, 4}} = state.output
      assert Output.rows(state.output, 5) == [root, "lib/a.ex:3:2: warning"]
      assert Output.title(state.output, 0) =~ "! pwd; echo"

      state = key(state, {:key, :enter})
      assert {:ok, a} = Geex.BufferSupervisor.whereis(Path.join(root, "lib/a.ex"))
      assert Session.active_buffer() == {:ok, a}
      assert {:ok, %{cursor: {2, 1}}} = Session.snapshot()
      assert state.focus == :editor
    end

    test "! in the pane runs it again, !! from the minibuffer too; q closes the pane",
         %{root: root} do
      {state, _} = editing(Path.join(root, "notes.txt"))
      state = typed(state, "!echo hi") |> ran()
      state = key(state, {:char, "!"})
      assert %{kind: :show} = state.shell
      state = ran(state)
      assert Output.rows(state.output, 5) == ["hi"]

      state = key(state, {:char, "q"})
      assert {state.output, state.focus} == {nil, :editor}

      state = typed(state, "!!")
      assert state.output.cmd == "echo hi"
      assert ran(state).output.status == {:exit, 0}
    end

    test "Ctrl-G stops it; a second one waits for the first", %{root: root} do
      {state, _} = editing(Path.join(root, "notes.txt"))
      state = typed(state, "!echo go; sleep 30")
      state = typed(state, "!echo second")
      assert state.notice =~ "still running"
      state = key(state, {:ctrl, ?g})
      assert state.shell.stopping
      assert state.notice == "stopping…"
      state = ran(state)
      assert state.output.status == {:exit, 143}
      assert state.notice == nil
    end

    test "a program that wants a terminal is stopped, and says so", %{root: root} do
      {state, _} = editing(Path.join(root, "notes.txt"))
      state = typed(state, ~S|!printf '\033[?1049h'; sleep 30|) |> ran()
      assert state.output.status == :needs_tty
      assert state.notice =~ "needs a real terminal"
    end

    test "a full-screen program isn't started at all", %{root: root} do
      {state, _} = editing(Path.join(root, "notes.txt"))
      state = typed(state, "!vim notes.txt")
      assert {state.shell, state.output} == {nil, nil}
      assert state.notice =~ "needs a real terminal"
    end
  end

  describe "| in the loop" do
    defp selecting(state, from, to),
      do: %{state | selection: Selection.new(from) |> Selection.extend(to)}

    test "replaces the selection with the output as one edit, which one undo takes back",
         %{root: root} do
      {state, pid} = editing(Path.join(root, "notes.txt"))
      state = selecting(state, {0, 0}, {3, 0}) |> typed("|sort") |> ran()

      assert Buffer.get_text(pid) == "a\nb\nc\nkeep\n"
      assert [%{meta: %{actor: :human}}] = Buffer.history(pid)
      assert state.notice =~ "replaced the selection"

      {:ok, _, _} = Buffer.undo(pid)
      assert Buffer.get_text(pid) == "c\nb\na\nkeep\n"
    end

    test "the output's last newline goes when the selection had none", %{root: root} do
      {state, pid} = editing(Path.join(root, "notes.txt"))
      selecting(state, {3, 0}, {3, 4}) |> typed("|tr a-z A-Z") |> ran()
      assert Buffer.get_text(pid) == "c\nb\na\nKEEP\n"
    end

    test "a failure shows stderr and leaves the text alone", %{root: root} do
      {state, pid} = editing(Path.join(root, "notes.txt"))
      state = selecting(state, {0, 0}, {1, 0}) |> typed("|echo broken >&2; exit 3") |> ran()

      assert Buffer.get_text(pid) == "c\nb\na\nkeep\n"
      assert Buffer.history(pid) == []
      assert %Output{kind: :pipe, status: {:exit, 3}} = state.output
      assert Output.rows(state.output, 5) == ["broken"]
      assert state.notice =~ "the text is unchanged"
    end

    test "nothing is replaced when the text changed while it ran", %{root: root} do
      {state, pid} = editing(Path.join(root, "notes.txt"))
      state = selecting(state, {0, 0}, {1, 0}) |> typed("|cat")
      {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 3, col: 0, text: "x"})
      Buffer.dispatch(pid, Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))
      state = ran(state)
      assert Buffer.get_text(pid) == "c\nb\na\nxkeep\n"
      assert state.notice =~ "nothing replaced"
    end

    test "without a selection it says what it needs", %{root: root} do
      {state, _} = editing(Path.join(root, "notes.txt"))
      assert typed(state, "|sort").notice =~ "needs a selection"
    end
  end

  describe "the minibuffer's history" do
    test "Up and Down walk what was entered, per mode, back to what was being typed",
         %{root: root} do
      {state, _} = editing(Path.join(root, "notes.txt"))
      state = state |> typed("line 2") |> typed("!true") |> ran()

      state = key(state, {:alt, ?m}) |> type("dra")
      state = key(state, {:key, :up})
      assert Minibuffer.value(state.minibuffer) == "!true"
      state = key(state, {:key, :up})
      assert Minibuffer.value(state.minibuffer) == "line 2"
      state = key(state, {:key, :down}) |> key({:key, :down})
      assert Minibuffer.value(state.minibuffer) == "dra"

      assert state.recall.grid.entries == []
    end

    test "is kept in a private file", %{root: root} do
      file = Path.join(root, "state/history.json")
      lists = %{"command" => ["!make", "save"], "grid" => ["a1"]}
      assert Recall.save(file, lists) == :ok
      assert Recall.load(file) == lists
      assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
      File.write!(file, "not json")
      assert Recall.load(file) == %{}
    end
  end
end
