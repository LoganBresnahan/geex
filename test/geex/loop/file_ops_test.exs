defmodule Geex.Loop.FileOpsTest do
  # The file operations' steps (ADR-0019's 2026-10-19 amendment) against a scratch root, through
  # the global Session, so not async; then the same through the loop's own handle_info/2: the
  # typed verbs and the tree's a/d/r, each step answered by its own process (ADR-0035).
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Command, Dispatch, Loop, Minibuffer, Session}
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Loop.FileOps

  doctest Geex.Loop.FileOps

  setup do
    root = Path.join(System.tmp_dir!(), "geex_fileops_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "a\n")
    Session.set_start(root)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp at(root, rel), do: Path.join(root, rel)

  describe "resolve/2" do
    test "relative paths are from the root and may not leave it; absolute ones go anywhere" do
      assert FileOps.resolve("a/../b", "/r") == {:ok, "/r/b"}
      assert FileOps.resolve("..", "/r") == {:error, :outside_root}
      assert FileOps.resolve("../rx", "/r") == {:error, :outside_root}
      assert FileOps.resolve("~/x", "/r") == {:ok, Path.expand("~/x")}
      assert FileOps.resolve("/etc/../tmp", "/r") == {:ok, "/tmp"}
    end
  end

  describe "step/2" do
    test "new: creates an empty file and says to open it; refuses one that exists", %{root: root} do
      assert {:open, path, "created lib/b.ex"} = FileOps.step({:new, at(root, "lib/b.ex")}, root)
      assert File.read!(path) == ""

      assert FileOps.step({:new, path}, root) == {:done, "not created: lib/b.ex already exists"}
    end

    test "new: a missing directory is asked about first, and made only on the next step",
         %{root: root} do
      file = at(root, "x/y/c.ex")

      assert {:confirm, "x/y/ doesn't exist; create it? (y/n) ", {:new_parents, ^file}} =
               FileOps.step({:new, file}, root)

      refute File.exists?(at(root, "x"))
      assert {:open, ^file, _} = FileOps.step({:new_parents, file}, root)
      assert File.regular?(file)
    end

    test "new: an open buffer not saved yet counts as existing", %{root: root} do
      {:ok, _} = Session.open_file(at(root, "draft.ex"))

      assert {:done, "not created: draft.ex already exists"} =
               FileOps.step({:new, at(root, "draft.ex")}, root)
    end

    test "mkdir: makes it, or refuses one that exists", %{root: root} do
      assert {:made_dir, _, "created docs/"} = FileOps.step({:mkdir, at(root, "docs")}, root)
      assert File.dir?(at(root, "docs"))

      assert {:done, "not created: lib already exists"} =
               FileOps.step({:mkdir, at(root, "lib")}, root)
    end

    test "delete: asks first, and says when unsaved edits go too", %{root: root} do
      file = at(root, "lib/a.ex")

      assert FileOps.step({:delete, file}, root) ==
               {:confirm, "delete lib/a.ex? (y/n) ", {:rm, file}}

      {:ok, pid} = Session.open_file(file)
      {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "z"})
      {:ok, _} = Dispatch.run(Command.put_meta(cmd, Meta.human()))

      assert {:confirm, "delete lib/a.ex? Its unsaved edits go with it. (y/n) ", {:rm, ^file}} =
               FileOps.step({:delete, file}, root)

      assert File.exists?(file)
      assert FileOps.step({:rm, file}, root) == {:done, "deleted lib/a.ex, and its unsaved edits"}
      refute File.exists?(file)
      refute Process.alive?(pid)
    end

    test "delete: a directory only when empty", %{root: root} do
      assert FileOps.step({:delete, at(root, "lib")}, root) ==
               {:done, "not deleted: lib/ isn't empty"}

      File.mkdir_p!(at(root, "empty"))
      empty = at(root, "empty")

      assert FileOps.step({:delete, empty}, root) ==
               {:confirm, "delete empty/? (y/n) ", {:rmdir, empty}}

      assert FileOps.step({:rmdir, empty}, root) == {:done, "deleted empty/"}
      refute File.exists?(empty)
    end

    test "rename: refuses to overwrite", %{root: root} do
      File.write!(at(root, "b.ex"), "b\n")

      assert FileOps.step({:rename, at(root, "lib/a.ex"), at(root, "b.ex")}, root) ==
               {:done, "not renamed: b.ex already exists"}

      assert File.read!(at(root, "b.ex")) == "b\n"
      assert File.read!(at(root, "lib/a.ex")) == "a\n"
    end
  end

  describe "through the loop" do
    defp key(state, event) do
      {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
      state
    end

    defp type(state, text), do: Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))

    # A step runs in a process of its own; deliver its answer.
    defp answered(state) do
      assert_receive {:geex_file_op, _pid, _answer} = msg, 5_000
      {:noreply, state} = Loop.handle_info(msg, state)
      state
    end

    defp tree_read(state) do
      assert_receive {:geex_tree, _pid, _index} = answer, 5_000
      {:noreply, state} = Loop.handle_info(answer, state)
      state
    end

    # The editor's keys need a buffer: `path`'s, shown.
    defp editing(path) do
      {:ok, pid} = Session.open_file(path)
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, Loop.new_state(120, 30))
      state
    end

    defp in_tree do
      state = %{Loop.new_state(120, 30) | focus: :tree}

      {:noreply, state} =
        Loop.handle_info({:geex_tree_changed, nil}, put_in(state.tree.index, %{}))

      tree_read(state)
    end

    test "typed `new` opens the file it made; `new ../x` is refused without touching the disk",
         %{root: root} do
      state = editing(at(root, "lib/a.ex"))
      state = key(state, {:alt, ?m}) |> type("new lib/b.ex") |> key({:key, :enter})
      assert state.file_ops != %{}
      state = answered(state)

      assert state.notice == "created lib/b.ex"
      assert {:ok, pid} = Geex.BufferSupervisor.whereis(at(root, "lib/b.ex"))
      assert Session.active_buffer() == {:ok, pid}

      state = key(state, {:alt, ?m}) |> type("new ../escape.ex") |> key({:key, :enter})

      assert state.notice ==
               "../escape.ex is outside the project root; type an absolute path to go there"

      assert state.file_ops == %{}
      refute File.exists?(Path.join(Path.dirname(root), "escape.ex"))
    end

    test "the directories `new` made stay in the tree once the file in them is gone",
         %{root: root} do
      state = editing(at(root, "lib/a.ex"))
      state = key(state, {:alt, ?m}) |> type("new x/y/c.ex") |> key({:key, :enter}) |> answered()
      assert Minibuffer.prompt(state.minibuffer) == "x/y/ doesn't exist; create it? (y/n) "
      state = key(state, {:char, "y"}) |> answered()
      assert MapSet.subset?(MapSet.new(["x", "x/y"]), state.tree.made)

      File.rm!(at(root, "x/y/c.ex"))

      {:noreply, state} =
        Loop.handle_info({:geex_tree_changed, root}, put_in(state.tree.index, %{}))

      state = tree_read(state)
      assert %{"x" => %{"y" => %{}}} = state.tree.index
    end

    test "typed `delete` asks y/n: n keeps the file, y deletes it", %{root: root} do
      state = editing(at(root, "lib/a.ex"))

      state = key(state, {:alt, ?m}) |> type("delete") |> key({:key, :enter}) |> answered()
      assert %Minibuffer{mode: :confirm} = state.minibuffer
      assert Minibuffer.prompt(state.minibuffer) == "delete lib/a.ex? (y/n) "

      state = key(state, {:char, "n"})
      assert state.notice == "nothing done"
      assert File.exists?(at(root, "lib/a.ex"))

      state = key(state, {:alt, ?m}) |> type("delete") |> key({:key, :enter}) |> answered()
      state = key(state, {:char, "y"}) |> answered()
      assert state.notice == "deleted lib/a.ex"
      refute File.exists?(at(root, "lib/a.ex"))
    end

    test "typed `rename` keeps the buffer, its history and its cursor", %{root: root} do
      state = editing(at(root, "lib/a.ex"))
      {:ok, pid} = Session.active_buffer()
      {:ok, cmd} = Insert.parse(%{line: 0, col: 1, text: "b"})
      {:ok, _} = Dispatch.run(Command.put_meta(cmd, Meta.human()))
      Session.set_cursor({0, 2})

      state = key(state, {:alt, ?m}) |> type("mv lib/ab.ex") |> key({:key, :enter}) |> answered()

      assert state.notice == "renamed lib/a.ex to lib/ab.ex"
      assert Geex.BufferSupervisor.whereis(at(root, "lib/ab.ex")) == {:ok, pid}
      assert {:ok, %{cursor: {0, 2}, text: "ab\n"}} = Session.snapshot()
      assert [_edit] = Buffer.history(pid)
    end

    test "tree a: the minibuffer starts at the highlighted directory; a trailing / makes one",
         %{root: root} do
      state = in_tree()
      assert [%{path: "lib"}] = state.tree.rows

      state = key(state, {:char, "a"})
      assert {state.minibuffer.mode, Minibuffer.value(state.minibuffer)} == {:command, "new lib/"}

      state = type(state, "util/") |> key({:key, :enter}) |> answered()
      assert state.notice == "created lib/util/"
      assert File.dir?(at(root, "lib/util"))
      assert state.focus == :tree

      # The watcher's event reads the tree again: the empty directory shows, highlighted.
      {:noreply, state} = Loop.handle_info({:geex_tree_changed, root}, state)
      state = tree_read(state)
      assert Enum.at(state.tree.rows, state.tree.sel).path == "lib/util"
    end

    test "tree d on a directory with files in it refuses; on a file it asks", %{root: root} do
      state = key(in_tree(), {:char, "d"}) |> answered()
      assert state.notice == "not deleted: lib/ isn't empty"
      assert state.minibuffer.mode == :inactive

      state = key(state, {:key, :enter}) |> key({:key, :down}) |> key({:char, "d"}) |> answered()
      assert Minibuffer.prompt(state.minibuffer) == "delete lib/a.ex? (y/n) "
      state = key(state, {:key, :esc})
      assert File.exists?(at(root, "lib/a.ex"))
      assert state.minibuffer.mode == :inactive
    end

    test "tree r renames the highlighted entry, a directory too, with its open file",
         %{root: root} do
      {:ok, pid} = Session.open_file(at(root, "lib/a.ex"))
      state = key(in_tree(), {:char, "r"})
      assert Minibuffer.prompt(state.minibuffer) == "rename lib/ to: "
      assert Minibuffer.value(state.minibuffer) == "lib"

      state = key(state, {:key, :backspace}) |> key({:key, :backspace}) |> key({:key, :backspace})
      state = type(state, "src") |> key({:key, :enter}) |> answered()

      assert state.notice == "renamed lib to src"
      assert Geex.BufferSupervisor.whereis(at(root, "src/a.ex")) == {:ok, pid}
      assert state.tree.want == "src"
    end
  end
end
