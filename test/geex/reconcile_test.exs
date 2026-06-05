defmodule Geex.ReconcileTest do
  # Glue tests touch the app-global BufferSupervisor + Geex.Registry — not parallel-safe.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Geex.{Buffer, Reconcile}

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

  describe "reconcile/2 — the core (echo-suppression + :external synthesis)" do
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

    test "a file_event for an open buffer whose disk changed reconciles it", %{recon: recon} do
      path = tmp_path()
      File.write!(path, "v1\n")
      buf = open_registered(path)
      assert Buffer.get_text(buf) == "v1\n"

      # external write, then the watcher event geex would have received
      File.write!(path, "v2 external\n")
      send(recon, {:file_event, self(), {path, [:modified, :closed]}})
      sync(recon)

      assert Buffer.get_text(buf) == "v2 external\n"
      assert [recorded] = Buffer.history(buf)
      assert recorded.meta.actor == :external
    end

    test "a file_event whose disk equals the buffer is ignored (geex's own save echo)",
         %{recon: recon} do
      path = tmp_path()
      File.write!(path, "stable\n")
      buf = open_registered(path)

      send(recon, {:file_event, self(), {path, [:modified]}})
      sync(recon)

      assert Buffer.history(buf) == []
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
      recon = start_supervised!({Reconcile, name: :"recon_#{System.unique_integer([:positive])}"})
      path = tmp_path()
      File.write!(path, "")

      # inotify-tools is absent here, so FileSystem.start_link returns :ignore; watch
      # must still return :ok and leave the reconciler alive (logged degradation).
      log =
        capture_log(fn ->
          assert Reconcile.watch(recon, path) == :ok
          :sys.get_state(recon)
        end)

      assert Process.alive?(recon)
      # the dir was not added to the watched set (backend couldn't start)
      assert :sys.get_state(recon).watched == MapSet.new()
      assert log =~ "cannot watch" or log =~ "inotify"
    end
  end
end
