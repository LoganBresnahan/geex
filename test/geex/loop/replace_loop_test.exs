defmodule Geex.Loop.ReplaceLoopTest do
  # `replace`, `replace-all` and `save-all` (2026-11-13, ADR-0053's amendment) through the loop's
  # own handle_info/2, no terminal: the plan worked out off the key loop, a y/n, each file's one
  # command through the shared path, left unsaved, one undo step per file; a file changed since
  # the plan is refused; save-all writes them. Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, BufferSupervisor, Loop, Minibuffer, Session}
  alias Geex.Commands.Insert
  alias Geex.Loop.Output

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_replace_loop_#{Geex.Fixtures.uniq()}")
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

  defp open(dir, name, text) do
    path = Path.join(dir, name)
    File.write!(path, text)
    {:ok, pid} = Session.open_file(path)
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp keys(state, events), do: Enum.reduce(events, state, &key(&2, &1))
  defp type(state, text), do: keys(state, Enum.map(String.graphemes(text), &{:char, &1}))
  defp run(state, command), do: state |> key({:alt, ?m}) |> type(command) |> key({:key, :enter})
  defp search(state, query), do: state |> key({:alt, ?q}) |> type(query) |> key({:key, :enter})

  # The replace process's answer, handled as the loop would.
  defp answer(state) do
    assert_receive {:geex_replace, _pid, _answer} = msg, 2_000
    {:noreply, state} = Loop.handle_info(msg, state)
    state
  end

  defp text(pid), do: Buffer.get_text(pid)
  defp history(pid), do: Buffer.history(pid)
  defp dirty?(pid), do: Buffer.status(pid).dirty

  # A project search's results in the output pane, as `search-all` leaves them.
  defp results(state, query, lines) do
    out = Output.new("search-all", :show, 0) |> Output.add(lines, "")
    out = %{out | search: %{query: query, mode: :search_all}, status: {:exit, 0}}
    %{state | output: out}
  end

  describe "replace: the file you're in" do
    test "a y/n, then every match replaced as one undo step, the file left unsaved", %{dir: dir} do
      {state, pid} = open(dir, "a.txt", "foo bar foo\nFoo\nnone\n")
      before = length(history(pid))
      state = state |> search("foo") |> run("replace baz qux")
      state = answer(state)

      assert state.minibuffer.mode == :confirm
      assert Minibuffer.prompt(state.minibuffer) =~ "replace 3 matches?"
      assert text(pid) == "foo bar foo\nFoo\nnone\n"

      state = state |> key({:char, "y"}) |> answer()
      assert text(pid) == "baz qux bar baz qux\nbaz qux\nnone\n"
      assert state.notice =~ "replaced 3 matches (unsaved"
      assert dirty?(pid)
      assert File.read!(Path.join(dir, "a.txt")) == "foo bar foo\nFoo\nnone\n"

      # One command, the human's; one Alt+Z takes it all back.
      assert length(history(pid)) == before + 1
      assert List.last(history(pid)).meta.actor == :human
      _ = key(state, {:alt, ?z})
      assert text(pid) == "foo bar foo\nFoo\nnone\n"
    end

    test "n leaves the file as it was", %{dir: dir} do
      {state, pid} = open(dir, "a.txt", "foo\n")
      state = state |> search("foo") |> run("replace x") |> answer() |> key({:char, "n"})
      assert state.notice == "nothing done"
      assert text(pid) == "foo\n"
      refute dirty?(pid)
    end

    test "bare, it asks for the text: the command line again with the query", %{dir: dir} do
      {state, _pid} = open(dir, "a.txt", "foo\n")
      state = state |> search("foo") |> run("replace")

      assert {state.minibuffer.mode, Minibuffer.value(state.minibuffer)} ==
               {:command, "replace foo"}
    end

    test "with no search first, it says so; with no match, it says so", %{dir: dir} do
      {state, pid} = open(dir, "a.txt", "foo\n")
      assert run(state, "replace x").notice =~ "search the file first"
      state = state |> search("zzz") |> run("replace x") |> answer()
      assert state.notice == "nothing to replace: no match"
      assert text(pid) == "foo\n"
    end

    test "an edit between the y/n's question and the yes: refused, the edit kept", %{dir: dir} do
      {state, pid} = open(dir, "a.txt", "foo\n")
      state = state |> search("foo") |> run("replace x") |> answer()
      {:ok, ins} = Insert.parse(%{line: 0, col: 0, text: "!"})
      {:ok, _} = Buffer.dispatch(pid, Geex.Command.put_meta(ins, Geex.Command.Meta.human()))

      state = state |> key({:char, "y"}) |> answer()
      assert state.notice =~ "changed since, not replaced: a.txt"
      assert text(pid) == "!foo\n"
    end
  end

  describe "replace-all: every file the project search listed" do
    test "open and closed files, each one undo step, unsaved; the view stays", %{dir: dir} do
      File.write!(Path.join(dir, "b.txt"), "foo in b\nalso foo\n")
      File.write!(Path.join(dir, "c.txt"), "nothing\n")
      {state, a} = open(dir, "a.txt", "foo in a\n")

      state =
        results(state, "foo", ["a.txt:1:foo in a", "b.txt:1:foo in b", "b.txt:2:also foo"])

      state = state |> run("replace-all bar") |> answer()
      assert Minibuffer.prompt(state.minibuffer) =~ "replace 3 matches in 2 files?"
      # Nothing opened before the yes.
      assert BufferSupervisor.whereis(Path.join(dir, "b.txt")) == :error

      state = state |> key({:char, "y"}) |> answer()
      assert state.notice =~ "replaced 3 matches in 2 files (unsaved"

      {:ok, b} = BufferSupervisor.whereis(Path.join(dir, "b.txt"))
      assert text(a) == "bar in a\n"
      assert text(b) == "bar in b\nalso bar\n"
      assert dirty?(a) and dirty?(b)
      assert File.read!(Path.join(dir, "b.txt")) == "foo in b\nalso foo\n"
      assert List.last(history(b)).meta.actor == :human
      assert length(history(b)) == 1

      # You stay where you were; b is listed among the buffers.
      assert Session.active_buffer() == {:ok, a}
      assert b in Enum.map(Session.buffers(), & &1.pid)

      # save-all writes both.
      state = run(state, "save-all")
      assert state.notice == "saved 2 files"
      assert File.read!(Path.join(dir, "a.txt")) == "bar in a\n"
      assert File.read!(Path.join(dir, "b.txt")) == "bar in b\nalso bar\n"
      refute dirty?(a) or dirty?(b)
      assert run(state, "save-all").notice == "nothing to save"
    end

    test "a closed file changed on disk after the plan is refused", %{dir: dir} do
      File.write!(Path.join(dir, "b.txt"), "foo\n")
      {state, _a} = open(dir, "a.txt", "x\n")
      state = results(state, "foo", ["b.txt:1:foo"]) |> run("replace-all bar") |> answer()
      File.write!(Path.join(dir, "b.txt"), "foo changed\n")

      state = state |> key({:char, "y"}) |> answer()
      assert state.notice =~ "changed since, not replaced: b.txt"
      {:ok, b} = BufferSupervisor.whereis(Path.join(dir, "b.txt"))
      assert text(b) == "foo changed\n"
    end

    test "with no project search, it says so; bare, it asks with the query", %{dir: dir} do
      {state, _a} = open(dir, "a.txt", "x\n")
      assert run(state, "replace-all bar").notice =~ "search the project first"
      state = results(state, "foo", ["a.txt:1:x"]) |> run("replace-all")
      assert Minibuffer.value(state.minibuffer) == "replace-all foo"
    end

    test "results cut short or still coming: refused", %{dir: dir} do
      {state, _a} = open(dir, "a.txt", "x\n")
      state = results(state, "foo", ["a.txt:1:x"])
      assert run(put_in(state.output.capped, true), "replace-all y").notice =~ "cut short"
      assert run(put_in(state.output.status, :running), "replace-all y").notice =~ "still running"
    end
  end
end
