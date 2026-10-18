defmodule Geex.ReconcileTest do
  # Glue tests touch the app-global BufferSupervisor + Geex.Registry — not parallel-safe.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Geex.{Buffer, Command, Reconcile}
  alias Geex.Command.Meta
  alias Geex.Commands.Insert

  defp tmp_path do
    name = "geex_recon_#{System.unique_integer([:positive])}.txt"
    path = Path.join(System.tmp_dir!(), name)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A buffer registered by path in Geex.Registry (so the watcher glue can resolve it),
  # torn down after the test.
  defp open_registered(path) do
    # register under the expanded path — the same key the watcher resolves events to
    {:ok, pid} = Geex.BufferSupervisor.start_buffer(Path.expand(path))

    on_exit(fn ->
      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
    end)

    pid
  end

  defp hex(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # Make `buf` dirty: dispatch one human edit so its text diverges from its `synced` baseline.
  defp dirty_edit(buf, text) do
    {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: text})
    {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
  end

  describe "reconcile/2 — the core (baseline echo-suppression + :external synthesis)" do
    test "equal disk text is ignored (echo-suppression, no history change)" do
      buf = start_supervised!({Buffer, text: "same\n"})
      assert Reconcile.reconcile(buf, "same\n") == :ignored
      assert Buffer.history(buf) == []
      assert Buffer.snapshot(buf).dirty == false
    end

    test "a divergent disk text is adopted as one :external command" do
      buf = start_supervised!({Buffer, text: "old line\n"})

      assert {:reconciled, snap} = Reconcile.reconcile(buf, "new line\nadded\n")
      assert snap.text == "new line\nadded\n"
      assert [recorded] = snap.history
      assert recorded.meta.actor == :external
      # exactly one command — so the external change is a single undoable step
      assert snap.version == 1
      # the buffer now equals disk, so it is in sync — not dirty (geex-as-observer)
      assert snap.dirty == false
    end

    test "a dirty buffer is NOT reverted by an event for an unchanged file (disk == baseline)" do
      # the heart of the baseline model: reconcile compares disk to the SYNCED baseline, not
      # the live text. A dirty buffer's disk still equals its baseline, so an event for it is
      # no external change — the unsaved edits survive (this is what geex's own rename relies on).
      buf = start_supervised!({Buffer, text: "base\n"})
      dirty_edit(buf, "EDIT-")
      assert Buffer.snapshot(buf).dirty == true

      assert Reconcile.reconcile(buf, "base\n") == :ignored
      assert Buffer.get_text(buf) == "EDIT-base\n"
      assert Enum.all?(Buffer.history(buf), &(&1.meta.actor != :external))
    end

    test "a dirty buffer merges a genuine external change (disk diverges from baseline)" do
      buf = start_supervised!({Buffer, text: "base\n"})
      dirty_edit(buf, "EDIT-")

      assert {:reconciled, snap} = Reconcile.reconcile(buf, "external\n")
      # both changed the one line: git's conflict block, your side first (ADR-0034 §2)
      assert snap.text ==
               "<<<<<<< buffer\nEDIT-base\n=======\nexternal\n>>>>>>> disk\n"

      # the human edit is kept in history; the external change is appended
      assert hd(snap.history).meta.actor == :human
      assert List.last(snap.history).meta.actor == :external
      assert snap.synced == "external\n"
      assert snap.dirty
    end

    test "save/1 moves the baseline: the save echo is ignored, a later external change is caught" do
      path = tmp_path()
      File.write!(path, "v1\n")
      buf = open_registered(path)
      dirty_edit(buf, "EDIT-")
      assert {:ok, _} = Buffer.save(buf)

      # save wrote "EDIT-v1\n" to disk and re-baselined to it, so the save's own watch event
      # (disk == the just-written bytes) is ignored — NOT re-ingested as an external change.
      assert Reconcile.reconcile(buf, "EDIT-v1\n") == :ignored
      # but a genuine external change *after* the save still diverges from the new baseline.
      assert {:reconciled, snap} = Reconcile.reconcile(buf, "external\n")
      assert snap.text == "external\n"
    end

    test "adopting an external change re-baselines: a re-delivered identical event is ignored" do
      buf = start_supervised!({Buffer, text: "base\n"})
      assert {:reconciled, _} = Reconcile.reconcile(buf, "adopted\n")

      # mark_synced set the baseline to the adopted disk content, so the same disk arriving
      # again (a settling/duplicate event) is ignored — not re-adopted as a second command.
      assert Reconcile.reconcile(buf, "adopted\n") == :ignored
      assert length(Buffer.history(buf)) == 1
    end

    test "a dead target buffer is contained, not a crash" do
      {:ok, buf} = GenServer.start(Buffer, text: "x")
      ref = Process.monitor(buf)
      Process.exit(buf, :kill)
      assert_receive {:DOWN, ^ref, :process, ^buf, _}

      # reconcile must not let the buffer's :exit propagate to (and crash) its caller
      assert {:error, {:buffer_down, _}} = Reconcile.reconcile(buf, "anything\n")
    end

    test "reconcile from empty buffer to content" do
      buf = start_supervised!({Buffer, text: ""})
      assert {:reconciled, snap} = Reconcile.reconcile(buf, "hello\n")
      assert snap.text == "hello\n"
    end

    test "reconcile from content to empty (external truncation)" do
      buf = start_supervised!({Buffer, text: "delete me\n"})
      assert {:reconciled, snap} = Reconcile.reconcile(buf, "")
      assert snap.text == ""
    end

    test "multi-line and unicode round-trip exactly" do
      buf = start_supervised!({Buffer, text: "a\nb\nc\n"})
      disk = "α\nβ — δ\n😀\n"
      assert {:reconciled, snap} = Reconcile.reconcile(buf, disk)
      assert snap.text == disk
    end

    test "targets the given buffer regardless of which buffer is active" do
      # two independent buffers; reconcile must hit the one passed by pid, not the
      # Session's active buffer (reconcile uses Buffer.dispatch, not Dispatch.run).
      target = start_supervised!({Buffer, text: "target old\n"}, id: :target)
      other = start_supervised!({Buffer, text: "untouched\n"}, id: :other)

      assert {:reconciled, _} = Reconcile.reconcile(target, "target new\n")
      assert Buffer.get_text(target) == "target new\n"
      assert Buffer.get_text(other) == "untouched\n"
      assert Buffer.history(other) == []
    end
  end

  describe "line-level hunks (ADR-0032)" do
    test "a multi-hunk write is one group: one command per hunk, shared group + disk sha256" do
      buf = start_supervised!({Buffer, text: "1\n2\n3\n4\n5\n"})
      disk = "1\nTWO\n3\n4\nFIVE\n"

      assert {:reconciled, snap} = Reconcile.reconcile(buf, disk)
      assert snap.text == disk
      assert [first, second] = snap.history

      for cmd <- [first, second] do
        assert cmd.meta.actor == :external
        assert %Geex.Commands.Replace{} = cmd
      end

      assert first.meta.reconcile == second.meta.reconcile
      hex = &Base.encode16(:crypto.hash(:sha256, &1), case: :lower)
      assert first.meta.reconcile.sha256 == hex.(disk)
      # the baseline the write replaced, not the buffer text
      assert first.meta.reconcile.before_sha256 == hex.("1\n2\n3\n4\n5\n")
      assert first.meta.reconcile.sha256 =~ ~r/\A[0-9a-f]{64}\z/
      # each hunk touches only its own line
      assert Enum.sort([first.text, second.text]) == ["FIVE", "TWO"]
    end

    test "before_sha256 is the synced disk baseline, even when the buffer is dirty" do
      buf = start_supervised!({Buffer, text: "base\n"})
      dirty_edit(buf, "EDIT-")

      assert {:reconciled, snap} = Reconcile.reconcile(buf, "external\n")
      ext = List.last(snap.history)
      hex = &Base.encode16(:crypto.hash(:sha256, &1), case: :lower)
      assert ext.meta.reconcile.before_sha256 == hex.("base\n")
    end

    test "separate writes are separate groups" do
      buf = start_supervised!({Buffer, text: "a\n"})
      assert {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
      assert {:reconciled, snap} = Reconcile.reconcile(buf, "c\n")
      [one, two] = snap.history
      refute one.meta.reconcile.group == two.meta.reconcile.group
    end

    test "undo walks an external write back hunk by hunk" do
      buf = start_supervised!({Buffer, text: "1\n2\n3\n"})
      assert {:reconciled, _} = Reconcile.reconcile(buf, "ONE\n2\nTHREE\n")

      assert {:ok, snap, _} = Buffer.undo(buf)
      assert snap.text in ["1\n2\nTHREE\n", "ONE\n2\n3\n"]
      assert {:ok, snap, _} = Buffer.undo(buf)
      assert snap.text == "1\n2\n3\n"
    end
  end

  describe "a disk change on a dirty buffer: git merge-file (ADR-0034 §2)" do
    test "a disjoint disk change merges in; your unsaved edit is kept and still unsaved" do
      buf = start_supervised!({Buffer, text: "1\n2\n3\n"})
      dirty_edit(buf, "MY-")
      {:ok, _v} = Buffer.subscribe(buf, self())

      assert {:reconciled, snap} = Reconcile.reconcile(buf, "1\n2\nDISK\n")
      assert snap.text == "MY-1\n2\nDISK\n"
      assert snap.synced == "1\n2\nDISK\n"
      assert snap.dirty
      refute_receive {:geex_buffer_notice, ^buf, _}, 100
    end

    test "an overlapping hunk becomes git's conflict block, the human is told, undo takes it back" do
      buf = start_supervised!({Buffer, text: "keep\nedit me\n"})
      {:ok, cmd} = Insert.parse(%{line: 1, col: 0, text: "MINE "})
      {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
      {:ok, _v} = Buffer.subscribe(buf, self())

      assert {:reconciled, snap} = Reconcile.reconcile(buf, "keep\nDISK\n")

      assert snap.text ==
               "keep\n<<<<<<< buffer\nMINE edit me\n=======\nDISK\n>>>>>>> disk\n"

      assert snap.dirty
      assert_receive {:geex_buffer_notice, ^buf, notice}, 500
      assert notice =~ "1 conflict with the disk"

      externals = Enum.count(snap.history, &(&1.meta.actor == :external))
      for _ <- 1..externals, do: {:ok, _, _} = Buffer.undo(buf)

      assert Buffer.get_text(buf) == "keep\nMINE edit me\n"
    end

    test "without git, geex's own merge: the disk wins an overlap, one undo away" do
      Application.put_env(:geex, :git_executable, "geex-test-no-such-git")
      on_exit(fn -> Application.delete_env(:geex, :git_executable) end)

      buf = start_supervised!({Buffer, text: "keep\nedit me\n"})
      {:ok, cmd} = Insert.parse(%{line: 1, col: 0, text: "MINE "})
      {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
      {:ok, _v} = Buffer.subscribe(buf, self())

      assert {:reconciled, snap} = Reconcile.reconcile(buf, "keep\nDISK\n")
      assert snap.text == "keep\nDISK\n"
      refute snap.dirty
      assert_receive {:geex_buffer_notice, ^buf, notice}, 500
      assert notice =~ "1 of your unsaved hunks"

      assert {:ok, snap, _} = Buffer.undo(buf)
      assert snap.text == "keep\nMINE edit me\n"
    end

    test "disk changing to exactly what the buffer holds records nothing, just re-syncs" do
      buf = start_supervised!({Buffer, text: "a\n"})
      dirty_edit(buf, "b")
      history = Buffer.history(buf)

      assert {:reconciled, snap} = Reconcile.reconcile(buf, "ba\n")
      assert snap.history == history
      assert snap.synced == "ba\n"
      refute snap.dirty
    end

    test "the merged group keeps the disk-bytes hashes (attestation stays exact)" do
      buf = start_supervised!({Buffer, text: "1\n2\n"})
      dirty_edit(buf, "MY-")
      assert {:reconciled, snap} = Reconcile.reconcile(buf, "1\nTWO\n")
      ext = List.last(snap.history)
      hex = &Base.encode16(:crypto.hash(:sha256, &1), case: :lower)
      assert ext.meta.reconcile.before_sha256 == hex.("1\n2\n")
      assert ext.meta.reconcile.sha256 == hex.("1\nTWO\n")
    end
  end

  describe "write completion: the per-path quiet period (ADR-0032)" do
    # The quiet period never runs out by itself here: the test delivers the reconciler's own
    # `{:settled, path, ref}` timers when it chooses. With a real one (150 ms, once 40 ms), a
    # loaded machine could stall this process mid-`File.write!` (after the truncate, before the
    # bytes) past the quiet period, and the read found "" (BUG-5).
    @settle :timer.hours(1)

    setup do
      recon =
        start_supervised!(
          {Reconcile, name: :"recon_#{System.unique_integer([:positive])}", settle_ms: @settle}
        )

      %{recon: recon}
    end

    test "nothing is read until the path is quiet; a burst is read once, to the final bytes",
         %{recon: recon} do
      path = Path.expand(tmp_path())
      File.write!(path, "v1\n")
      buf = open_registered(path)

      File.write!(path, "v2 half")
      send(recon, {:file_event, self(), {path, [:modified]}})
      %{^path => first} = :sys.get_state(recon).settling
      File.write!(path, "v2 done\n")
      send(recon, {:file_event, self(), {path, [:modified]}})
      %{^path => last} = :sys.get_state(recon).settling
      assert first != last

      # still inside the quiet period: the half-written state was never read
      assert Buffer.snapshot(buf).behind == nil

      # the first event's timer was superseded by the second's: it reads nothing
      send(recon, {:settled, path, first})
      :sys.get_state(recon)
      assert Buffer.snapshot(buf).behind == nil

      # the path went quiet: read once, now
      send(recon, {:settled, path, last})
      :sys.get_state(recon)

      # the buffer holds (ADR-0034); it was told about the final bytes only
      assert Buffer.get_text(buf) == "v1\n"
      assert Buffer.snapshot(buf).behind.sha256 == hex("v2 done\n")
      assert :sys.get_state(recon).settling == %{}

      assert {:fast_forwarded, snap, 0} = Reconcile.fast_forward(buf)
      assert snap.text == "v2 done\n"
      groups = snap.history |> Enum.map(& &1.meta.reconcile.group) |> Enum.uniq()
      assert length(groups) == 1
    end

    test "a real quiet period runs out by itself, and the file is read then" do
      recon =
        start_supervised!(
          {Reconcile, name: :"recon_#{System.unique_integer([:positive])}", settle_ms: 20},
          id: :short_settle
        )

      path = tmp_path()
      File.write!(path, "v1\n")
      buf = open_registered(path)
      File.write!(path, "v2\n")
      send(recon, {:file_event, self(), {path, [:modified]}})

      # However long the machine takes, not a deadline: wait for it, up to 5 s.
      assert Enum.any?(1..250, fn _ ->
               Process.sleep(20)
               Buffer.snapshot(buf).behind != nil
             end)

      assert Buffer.snapshot(buf).behind.sha256 == hex("v2\n")
    end
  end

  describe "the watcher glue (injected :file_event — no inotify backend needed)" do
    # The reconciler under test; the global one is gated off in test config, so this
    # named instance owns the glue without contending for the default name.
    setup do
      recon = start_supervised!({Reconcile, name: :"recon_#{System.unique_integer([:positive])}"})
      %{recon: recon}
    end

    # Force the GenServer to drain its mailbox: messages are processed FIFO, so a
    # following :sys.get_state returns only after the injected event was handled (and
    # handle_info's synchronous Buffer.dispatch completed).
    defp sync(pid), do: :sys.get_state(pid)

    test "a file_event for an open buffer whose disk changed marks it behind; it holds",
         %{recon: recon} do
      path = tmp_path()
      File.write!(path, "v1\n")
      buf = open_registered(path)
      {:ok, _v} = Buffer.subscribe(buf, self())

      # external write, then the watcher event geex would have received
      File.write!(path, "v2 external\n")
      send(recon, {:file_event, self(), {path, [:modified, :closed]}})
      sync(recon)

      assert Buffer.get_text(buf) == "v1\n"
      assert Buffer.history(buf) == []
      assert_receive {:geex_buffer_behind, ^buf, %{sha256: sha}}, 500
      assert sha == hex("v2 external\n")

      # the disk going back clears the mark
      File.write!(path, "v1\n")
      send(recon, {:file_event, self(), {path, [:modified]}})
      sync(recon)
      assert_receive {:geex_buffer_behind, ^buf, nil}, 500
    end

    test "a file_event whose disk equals the buffer is ignored (geex's own save echo)",
         %{recon: recon} do
      path = tmp_path()
      File.write!(path, "stable\n")
      buf = open_registered(path)

      send(recon, {:file_event, self(), {path, [:modified]}})
      sync(recon)

      assert Buffer.history(buf) == []
      assert Buffer.snapshot(buf).behind == nil
    end

    test "a file_event for a path with no open buffer is a harmless no-op", %{recon: recon} do
      path = tmp_path()
      File.write!(path, "nobody has this open\n")

      send(recon, {:file_event, self(), {path, [:modified]}})
      assert sync(recon)
      assert Process.alive?(recon)
    end

    test "a file_event for a deleted file does not reconcile to empty or crash",
         %{recon: recon} do
      path = tmp_path()
      File.write!(path, "present\n")
      buf = open_registered(path)
      File.rm!(path)

      send(recon, {:file_event, self(), {path, [:deleted]}})
      sync(recon)

      # the buffer keeps its content; deletion isn't reconciled to empty
      assert Buffer.get_text(buf) == "present\n"
      assert Buffer.history(buf) == []
    end

    test "a dirty buffer is not reverted by an event for its unchanged backing file",
         %{recon: recon} do
      path = tmp_path()
      File.write!(path, "base\n")
      buf = open_registered(path)
      dirty_edit(buf, "EDIT-")

      # disk is unchanged from the buffer's baseline ("base\n"), so a spurious event must not
      # revert the unsaved edits — the watcher-level analog of the baseline core test, and the
      # exact path geex's own rename relies on (the re-keyed buffer keeps its baseline).
      send(recon, {:file_event, self(), {path, [:modified]}})
      sync(recon)

      assert Buffer.get_text(buf) == "EDIT-base\n"
      assert Enum.all?(Buffer.history(buf), &(&1.meta.actor != :external))
    end

    test "a :stop event and unknown messages are ignored without crashing", %{recon: recon} do
      send(recon, {:file_event, self(), :stop})
      send(recon, :some_unexpected_message)
      assert sync(recon)
      assert Process.alive?(recon)
    end
  end

  describe "watcher cleanup (a stopped/dead watcher frees its directory)" do
    setup do
      recon = start_supervised!({Reconcile, name: :"recon_#{System.unique_integer([:positive])}"})
      %{recon: recon}
    end

    # Seed a watched dir + watcher pid without a real inotify backend (which is absent
    # here), so the cleanup handlers are exercised directly.
    defp seed_watcher(recon, dir) do
      fake = spawn(fn -> :ok end)

      :sys.replace_state(recon, fn s ->
        %{s | watched: MapSet.put(s.watched, dir), watchers: Map.put(s.watchers, fake, dir)}
      end)

      fake
    end

    test "a :stop event frees the directory so it can be re-watched", %{recon: recon} do
      dir = "/some/watched/dir"
      fake = seed_watcher(recon, dir)
      assert :sys.get_state(recon).watched == MapSet.new([dir])

      # the :file_system worker forwards :stop on a normal backend exit without itself
      # exiting, so :stop — not an {:EXIT,…} — is the authoritative cleanup signal
      send(recon, {:file_event, fake, :stop})
      :sys.get_state(recon)

      state = :sys.get_state(recon)
      assert state.watched == MapSet.new()
      assert state.watchers == %{}
    end

    test "an {:EXIT, …} for a watched worker frees the directory", %{recon: recon} do
      dir = "/another/dir"
      fake = seed_watcher(recon, dir)

      send(recon, {:EXIT, fake, :some_reason})
      :sys.get_state(recon)

      assert :sys.get_state(recon).watched == MapSet.new()
    end

    test "a stop/exit for an unknown watcher is a harmless no-op", %{recon: recon} do
      dir = "/kept/dir"
      _fake = seed_watcher(recon, dir)

      send(recon, {:file_event, spawn(fn -> :ok end), :stop})
      send(recon, {:EXIT, spawn(fn -> :ok end), :nope})
      :sys.get_state(recon)

      # the unrelated seeded dir is untouched
      assert :sys.get_state(recon).watched == MapSet.new([dir])
    end
  end

  describe "watch/2 lifecycle" do
    test "watch/2 on a not-running reconciler is a no-op (no crash)" do
      assert Reconcile.watch(:geex_reconcile_definitely_not_running, "/tmp/whatever.txt") == :ok
    end

    test "watch/2 degrades gracefully when the watch backend is unavailable" do
      # Stub the backend as unbootstrappable (what `FileSystem.start_link` returns when
      # inotify-tools is missing) so this holds on any host; watch must still return :ok
      # and leave the reconciler alive (logged degradation).
      recon =
        start_supervised!(
          {Reconcile,
           name: :"recon_#{System.unique_integer([:positive])}",
           start_watcher: fn _dir -> :ignore end}
        )

      path = tmp_path()
      File.write!(path, "")

      log =
        capture_log(fn ->
          assert Reconcile.watch(recon, path) == :ok
          :sys.get_state(recon)
        end)

      assert Process.alive?(recon)
      # the dir was not added to the watched set (backend couldn't start)
      assert :sys.get_state(recon).watched == MapSet.new()
      assert log =~ "cannot watch"
    end

    test "watch/2 records the directory once when the backend starts" do
      test_pid = self()

      # A stand-in worker that answers FileSystem.subscribe/1's :subscribe call.
      start_watcher = fn dir ->
        send(test_pid, {:started, dir})

        {:ok,
         spawn_link(fn ->
           receive do
             {:"$gen_call", from, :subscribe} -> GenServer.reply(from, :ok)
           end

           Process.sleep(:infinity)
         end)}
      end

      recon =
        start_supervised!(
          {Reconcile,
           name: :"recon_#{System.unique_integer([:positive])}", start_watcher: start_watcher}
        )

      path = tmp_path()
      dir = Path.dirname(Path.expand(path))

      assert Reconcile.watch(recon, path) == :ok
      assert Reconcile.watch(recon, path) == :ok
      state = :sys.get_state(recon)

      assert state.watched == MapSet.new([dir])
      assert map_size(state.watchers) == 1
      assert_received {:started, ^dir}
      refute_received {:started, _}
    end
  end
end
