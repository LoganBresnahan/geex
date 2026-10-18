defmodule Geex.Tree.WatcherTest do
  # The tree's watcher (ADR-0034 §5): which directories it watches, which events it reports, and
  # (where inotify-tools is installed) a real watch end to end.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Geex.Tree.Watcher

  doctest Watcher

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_tree_watch_#{Geex.Fixtures.uniq()}")

    for d <- ["lib/geex", "_build/dev", ".git/objects", "empty"],
        do: File.mkdir_p!(Path.join(dir, d))

    for f <- ["README.md", "lib/geex/a.ex"], do: File.write!(Path.join(dir, f), "")
    on_exit(fn -> File.rm_rf(dir) end)
    %{root: dir}
  end

  # A stand-in worker that answers FileSystem.subscribe/1, and says which directories it got.
  defp stub(test) do
    fn dirs ->
      worker =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, :subscribe} -> GenServer.reply(from, :ok)
          end

          Process.sleep(:infinity)
        end)

      send(test, {:started, worker, dirs})
      {:ok, worker}
    end
  end

  defp start(opts) do
    start_supervised!(
      {Watcher, [name: :"tree_watch_#{System.unique_integer([:positive])}"] ++ opts}
    )
  end

  test "watches the root, the directories holding files, and their subdirectories, not deeper",
       %{root: root} do
    w = start(start_worker: stub(self()))
    Watcher.watch(w, root, Watcher.dirs_of(["README.md", "lib/geex/a.ex"]), self())
    assert_receive {:started, _worker, dirs}

    # `_build` and `empty` are seen (a new file in them shows up), `_build/dev` and `.git` are not.
    assert dirs == [root | Enum.map(["_build", "empty", "lib", "lib/geex"], &Path.join(root, &1))]

    # The same directories again: the same worker (once the cast is handled, no restart came).
    Watcher.watch(w, root, ["lib/geex", "."], self())
    :sys.get_state(w)
    refute_received {:started, _, _}
  end

  test "a burst of creates, deletes and moves is one message; a file's edits are none",
       %{root: root} do
    w = start(start_worker: stub(self()), delay_ms: 20)
    Watcher.watch(w, root, ["."], self())
    assert_receive {:started, worker, _dirs}

    send(w, {:file_event, worker, {Path.join(root, "a.txt"), [:modified, :closed]}})
    refute_receive {:geex_tree_changed, _}, 60

    for events <- [[:created], [:deleted], [:moved_to], [:moved_from], [:created, :isdir]],
        do: send(w, {:file_event, worker, {Path.join(root, "x"), events}})

    assert_receive {:geex_tree_changed, ^root}
    refute_receive {:geex_tree_changed, _}, 60

    # An event from a worker it has replaced is ignored.
    send(w, {:file_event, self(), {Path.join(root, "y"), [:created]}})
    refute_receive {:geex_tree_changed, _}, 60
  end

  test "a new set of directories starts a new worker and stops the old one", %{root: root} do
    w = start(start_worker: stub(self()))
    Watcher.watch(w, root, ["."], self())
    assert_receive {:started, old, _}
    ref = Process.monitor(old)

    File.mkdir_p!(Path.join(root, "new"))
    Watcher.watch(w, root, ["."], self())
    assert_receive {:started, new, dirs}
    assert Path.join(root, "new") in dirs
    assert_receive {:DOWN, ^ref, :process, ^old, _}
    assert :sys.get_state(w).worker == new
  end

  test "a stopped worker asks for a read, which restarts it; twice in a row it gives up",
       %{root: root} do
    w = start(start_worker: stub(self()))
    Watcher.watch(w, root, ["."], self())
    assert_receive {:started, worker, _}

    send(w, {:file_event, worker, :stop})
    assert_receive {:geex_tree_changed, ^root}
    Watcher.watch(w, root, ["."], self())
    assert_receive {:started, worker, _}

    send(w, {:file_event, worker, :stop})
    assert_receive {:geex_tree_changed, ^root}
    Watcher.watch(w, root, ["."], self())
    assert_receive {:started, worker, _}

    send(w, {:file_event, worker, :stop})
    refute_receive {:geex_tree_changed, _}, 60
  end

  test "without a backend it says so once and stays up", %{root: root} do
    w = start(start_worker: fn _dirs -> :ignore end)
    Watcher.watch(w, root, ["."], self())
    Watcher.watch(w, root, ["."], self())
    assert %{worker: nil, warned: true} = :sys.get_state(w)
  end

  test "a directory made is watched at once with what's under it, but not what git ignores",
       %{root: root} do
    {_, 0} = System.cmd("git", ["init", "-q", root])
    File.write!(Path.join(root, ".gitignore"), "/new/out/\n")
    for d <- ["new/a/b", "new/out/deep", "new/.hidden"], do: File.mkdir_p!(Path.join(root, d))

    assert Watcher.new_dirs(root, [Path.join(root, "new")]) ==
             Enum.map(["new", "new/a", "new/a/b"], &Path.join(root, &1))

    w = start(start_worker: stub(self()), delay_ms: 20)
    Watcher.watch(w, root, ["."], self())
    assert_receive {:started, worker, _}
    send(w, {:file_event, worker, {Path.join(root, "new"), [:created, :isdir]}})
    # The restart runs `git check-ignore`: slow on a loaded machine, so a long wait.
    assert_receive {:started, _new_worker, dirs}, 10_000
    assert Path.join(root, "new/a/b") in dirs
    refute Path.join(root, "new/out") in dirs
    assert_receive {:geex_tree_changed, ^root}

    # The next read lists no file under `new/`, and it stays watched. Once the watcher has
    # handled the cast (get_state waits for that), a restart would already have said so.
    Watcher.watch(w, root, ["."], self())
    assert Path.join(root, "new/a/b") in :sys.get_state(w).dirs
    refute_received {:started, _, _}
  end

  test "watch/4 is a no-op when no watcher runs" do
    assert Watcher.watch(:no_such_tree_watcher, "/x", ["."], self()) == :ok
  end

  describe "with inotify" do
    @describetag :inotify
    setup do
      if System.find_executable("inotifywait"), do: :ok, else: {:skip, "no inotifywait"}
    end

    # `inotifywait` sets its watches some time after it starts; on a loaded machine longer than
    # any fixed sleep (300 ms wasn't). So: make a file in `dir` until its event arrives, then
    # drop whatever else that brought. After this, `dir` is watched.
    defp watching(root, dir) do
      assert Enum.any?(1..100, fn i ->
               File.write!(Path.join(dir, ".probe-#{i}"), "")

               receive do
                 {:geex_tree_changed, ^root} -> true
               after
                 100 -> false
               end
             end),
             "#{dir} never watched"

      drain(root)
    end

    defp drain(root) do
      receive do
        {:geex_tree_changed, ^root} -> drain(root)
      after
        200 -> :ok
      end
    end

    test "a new file, a file in a new directory, and a deleted file are each reported",
         %{root: root} do
      w = start(delay_ms: 20)
      Watcher.watch(w, root, Watcher.dirs_of(["README.md", "lib/geex/a.ex"]), self())
      watching(root, Path.join(root, "lib/geex"))

      File.write!(Path.join(root, "lib/geex/b.ex"), "")
      assert_receive {:geex_tree_changed, ^root}, 5_000

      File.mkdir_p!(Path.join(root, "notes"))
      assert_receive {:geex_tree_changed, ^root}, 5_000
      # The loop's next read hands over the new directory.
      Watcher.watch(w, root, Watcher.dirs_of(["README.md", "lib/geex/a.ex"]), self())
      watching(root, Path.join(root, "notes"))
      File.write!(Path.join(root, "notes/today.md"), "")
      assert_receive {:geex_tree_changed, ^root}, 5_000

      File.rm!(Path.join(root, "README.md"))
      assert_receive {:geex_tree_changed, ^root}, 5_000

      # The coordinator's case: empty nested directories, a file in the deepest one later. The
      # watch on e1/e2 comes from the creation event alone: no read hands it over.
      File.mkdir_p!(Path.join(root, "e1/e2"))
      assert_receive {:geex_tree_changed, ^root}, 5_000
      watching(root, Path.join(root, "e1/e2"))
      File.write!(Path.join(root, "e1/e2/late.txt"), "hi\n")
      assert_receive {:geex_tree_changed, ^root}, 5_000

      # Nothing under `_build/dev` is watched: it isn't in the set (the deterministic half),
      # and, with the steps above drained (a late event once landed here), a file there says
      # nothing.
      refute Path.join(root, "_build/dev") in :sys.get_state(w).dirs
      drain(root)
      File.write!(Path.join(root, "_build/dev/x.beam"), "")
      refute_receive {:geex_tree_changed, _}, 300
    end
  end
end
