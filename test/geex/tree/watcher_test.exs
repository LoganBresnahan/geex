defmodule Geex.Tree.WatcherTest do
  # The tree's watcher (ADR-0034 §5): which directories it watches, which events it reports, and
  # (where inotify-tools is installed) a real watch end to end.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Geex.Tree.Watcher

  doctest Watcher

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_tree_watch_#{System.unique_integer([:positive])}")

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

    # The same directories again: the same worker.
    Watcher.watch(w, root, ["lib/geex", "."], self())
    refute_receive {:started, _, _}, 50
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

  test "watch/4 is a no-op when no watcher runs" do
    assert Watcher.watch(:no_such_tree_watcher, "/x", ["."], self()) == :ok
  end

  describe "with inotify" do
    @describetag :inotify
    setup do
      if System.find_executable("inotifywait"), do: :ok, else: {:skip, "no inotifywait"}
    end

    test "a new file, a file in a new directory, and a deleted file are each reported",
         %{root: root} do
      w = start(delay_ms: 20)
      Watcher.watch(w, root, Watcher.dirs_of(["README.md", "lib/geex/a.ex"]), self())
      # inotifywait sets its watches after it starts.
      Process.sleep(300)

      File.write!(Path.join(root, "lib/geex/b.ex"), "")
      assert_receive {:geex_tree_changed, ^root}, 2_000

      File.mkdir_p!(Path.join(root, "notes"))
      assert_receive {:geex_tree_changed, ^root}, 2_000
      # The loop's next read hands over the new directory.
      Watcher.watch(w, root, Watcher.dirs_of(["README.md", "lib/geex/a.ex"]), self())
      Process.sleep(300)
      File.write!(Path.join(root, "notes/today.md"), "")
      assert_receive {:geex_tree_changed, ^root}, 2_000

      File.rm!(Path.join(root, "README.md"))
      assert_receive {:geex_tree_changed, ^root}, 2_000

      # Nothing under `_build/dev` is watched.
      File.write!(Path.join(root, "_build/dev/x.beam"), "")
      refute_receive {:geex_tree_changed, _}, 300
    end
  end
end
