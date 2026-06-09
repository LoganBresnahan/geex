defmodule Geex.SessionTest.RenameExiter do
  @moduledoc false
  # A stand-in registered under a path: replies to :snapshot (so dirty?/buffer_status don't
  # crash) but EXITS on {:rename, _}, so Session.rekey_buffer's Buffer.rename hits safe_rename's
  # `catch :exit` deterministically — pinning the Session-crash guard without a registry race.
  # Started unlinked so its exit doesn't take the test process down.
  use GenServer

  def start(path),
    do: GenServer.start(__MODULE__, [], name: {:via, Registry, {Geex.Registry, path}})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:snapshot, _from, state),
    do:
      {:reply, %{path: nil, text: "", lines: [""], version: 0, dirty: false, history: []}, state}

  def handle_call({:rename, _to}, _from, state), do: {:stop, :normal, state}
end

defmodule Geex.SessionTest do
  # Drives the application-global Geex.Session singleton — not parallel-safe.
  use ExUnit.Case, async: false

  alias Geex.SessionTest.RenameExiter
  alias Geex.Buffer
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Dispatch
  alias Geex.Session

  setup do
    buf = start_supervised!({Buffer, text: ""})
    Session.set_active_buffer(buf)
    # The view-local cursor lives on the global Session; reset it so a prior test's
    # cursor move (set_cursor/1) can't leak into one that assumes the default.
    Session.set_cursor({0, 0})
    on_exit(fn -> Session.set_active_buffer(nil) end)
    %{buf: buf}
  end

  defp insert(line, col, text, meta) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    Command.put_meta(cmd, meta)
  end

  test "active_buffer/0 reports the buffer the view points at", %{buf: buf} do
    assert Session.active_buffer() == {:ok, buf}
  end

  test "subscribe/1 returns the current active buffer and pushes on change", %{buf: buf} do
    assert Session.subscribe() == buf

    other = start_supervised!({Buffer, text: "x"}, id: :other_active_buf)
    Session.set_active_buffer(other)
    assert_receive {:geex_active_buffer, ^other}, 1_000

    Session.set_active_buffer(nil)
    assert_receive {:geex_active_buffer, nil}, 1_000
  end

  test "subscribe/1 does not notify when the active buffer is unchanged", %{buf: buf} do
    Session.subscribe()
    # `buf` is already active (setup) → no pointer change → no notification.
    Session.set_active_buffer(buf)
    refute_receive {:geex_active_buffer, _}, 200
  end

  test "a cursor set by ANOTHER process notifies subscribers (the agent-moved-cursor repaint)" do
    Session.subscribe()
    test = self()

    # An out-of-process mover (an MCP transport calling the `line` view action, ADR-0030).
    spawn(fn ->
      :ok = Session.set_cursor({1, 0})
      send(test, :moved)
    end)

    assert_receive :moved, 1_000
    assert_receive {:geex_cursor, {1, 0}}, 1_000
  end

  test "a subscriber's OWN set_cursor is not echoed back (no double-repaint)" do
    Session.subscribe()
    :ok = Session.set_cursor({0, 1})
    refute_receive {:geex_cursor, _}, 200
  end

  test "snapshot/0 clamps an out-of-range stored cursor to the text" do
    {:ok, _} = Dispatch.run(insert(0, 0, "ab\ncd", Meta.human()))
    # A raced/stale cursor far past the buffer (e.g. set against a previous, larger buffer).
    :ok = Session.set_cursor({149, 7})
    assert {:ok, %{cursor: {1, 2}}} = Session.snapshot()
  end

  test "snapshot/0 with a dead active buffer degrades to no_active_buffer (never exits)", %{
    buf: buf
  } do
    Process.exit(buf, :kill)
    refute Process.alive?(buf)
    assert {:error, :no_active_buffer} = Session.snapshot()
  end

  test "set_cursor/1 updates the view-local cursor surfaced by snapshot/0" do
    {:ok, _} = Dispatch.run(insert(0, 0, "abc", Meta.human()))
    :ok = Session.set_cursor({0, 2})
    assert {:ok, %{cursor: {0, 2}}} = Session.snapshot()
  end

  test "Dispatch.run/1 routes a stamped command to the active buffer and records it" do
    assert {:ok, snap} = Dispatch.run(insert(0, 0, "hi", Meta.llm("claude-opus-4-8")))
    assert snap.text == "hi"
    assert [recorded] = snap.history
    assert recorded.meta.actor == {:llm, "claude-opus-4-8"}
  end

  test "snapshot/0 merges the view-local cursor with the active buffer's recorded state" do
    {:ok, _} = Dispatch.run(insert(0, 0, "abc", Meta.human()))

    assert {:ok, snap} = Session.snapshot()
    assert snap.text == "abc"
    # cursor is view-local (default {0, 0}), not part of the recorded buffer state.
    assert snap.cursor == {0, 0}
    assert snap.version == 1
  end

  test "with no active buffer, run/1 and snapshot/0 fail cleanly" do
    Session.set_active_buffer(nil)
    assert Dispatch.run(insert(0, 0, "x", Meta.human())) == {:error, :no_active_buffer}
    assert Session.snapshot() == {:error, :no_active_buffer}
  end

  describe "open_file/1 (multi-buffer, active-buffer model — ADR-0019)" do
    defp tmp_path do
      name = "geex_sess_#{System.unique_integer([:positive])}.txt"
      path = Path.join(System.tmp_dir!(), name)
      on_exit(fn -> File.rm(path) end)
      path
    end

    defp open(path) do
      {:ok, pid} = Session.open_file(path)

      on_exit(fn ->
        if Process.alive?(pid),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
      end)

      pid
    end

    test "starts a buffer for the path, loads it, and makes it active" do
      path = tmp_path()
      File.write!(path, "loaded\n")

      pid = open(path)
      assert Session.active_buffer() == {:ok, pid}
      assert Buffer.get_text(pid) == "loaded\n"
    end

    test "re-opening the same path reuses the buffer (preserves unsaved edits)" do
      path = tmp_path()
      File.write!(path, "original")
      pid = open(path)

      {:ok, _} = Dispatch.run(insert(0, 0, "X", Meta.human()))
      assert Buffer.get_text(pid) == "Xoriginal"

      # second open returns the same pid; the in-memory edit is not clobbered
      assert {:ok, ^pid} = Session.open_file(path)
      assert Buffer.get_text(pid) == "Xoriginal"
    end

    test "differently-spelled forms of one path resolve to the same buffer" do
      path = tmp_path()
      File.write!(path, "")
      pid = open(path)

      # a redundant "/./" segment normalizes to the same expanded path
      redundant = Path.join([Path.dirname(path), ".", Path.basename(path)])
      assert {:ok, ^pid} = Session.open_file(redundant)
    end

    test "the buffer is registered by its expanded path in Geex.Registry" do
      path = tmp_path()
      File.write!(path, "")
      pid = open(path)
      assert Geex.BufferSupervisor.whereis(Path.expand(path)) == {:ok, pid}
    end
  end

  describe "create_file/2 (disk-file lifecycle — ADR-0019)" do
    test "creates a new file with content on disk without opening a buffer", %{buf: buf} do
      path = tmp_path()
      refute File.exists?(path)

      assert {:ok, full} = Session.create_file(path, "seed\n")
      assert full == Path.expand(path)
      assert File.read!(path) == "seed\n"

      # a disk operation: no buffer opened, active pointer unchanged (still the scratch).
      assert Session.active_buffer() == {:ok, buf}
      assert Geex.BufferSupervisor.whereis(Path.expand(path)) == :error
    end

    test "content defaults to empty" do
      path = tmp_path()
      assert {:ok, _} = Session.create_file(path)
      assert File.read!(path) == ""
    end

    test "refuses if the file already exists on disk (no clobber)" do
      path = tmp_path()
      File.write!(path, "existing")
      assert Session.create_file(path, "new") == {:error, :eexist}
      assert File.read!(path) == "existing"
    end

    test "refuses if a buffer is already open for the path (even with no file on disk yet)" do
      path = tmp_path()
      refute File.exists?(path)
      _pid = open(path)
      refute File.exists?(path)
      assert Session.create_file(path, "x") == {:error, :eexist}
    end

    test "surfaces a posix error (missing parent directory) rather than crashing" do
      missing =
        Path.join([System.tmp_dir!(), "geex_nope_#{System.unique_integer([:positive])}", "f.txt"])

      assert {:error, :enoent} = Session.create_file(missing, "x")
    end
  end

  describe "delete_file/1 (disk-file lifecycle — ADR-0019)" do
    test "deletes a file with no open buffer" do
      path = tmp_path()
      File.write!(path, "bye")
      assert {:ok, {full, false}} = Session.delete_file(path)
      assert full == Path.expand(path)
      refute File.exists?(path)
    end

    test "deletes the file and evicts its buffer, clearing the active pointer" do
      path = tmp_path()
      File.write!(path, "data")
      pid = open(path)
      assert Session.active_buffer() == {:ok, pid}

      assert {:ok, {_full, false}} = Session.delete_file(path)
      refute File.exists?(path)
      refute Process.alive?(pid)
      assert Session.active_buffer() == :error
      assert Geex.BufferSupervisor.whereis(Path.expand(path)) == :error
    end

    test "reports discarded? = true when the evicted buffer had unsaved edits" do
      path = tmp_path()
      File.write!(path, "data")
      _pid = open(path)
      {:ok, _} = Dispatch.run(insert(0, 0, "X", Meta.human()))

      assert {:ok, {_full, true}} = Session.delete_file(path)
    end

    test "a missing file is a clean :enoent (not a crash)" do
      path = tmp_path()
      refute File.exists?(path)
      assert Session.delete_file(path) == {:error, :enoent}
    end
  end

  describe "rename_file/2 (disk-file lifecycle — ADR-0019)" do
    test "renames a file on disk with no open buffer" do
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "x")

      assert {:ok, {ff, ft}} = Session.rename_file(from, to)
      assert ff == Path.expand(from)
      assert ft == Path.expand(to)
      refute File.exists?(from)
      assert File.read!(to) == "x"
    end

    test "re-keys an open buffer: edits + history preserved, save writes to the new path" do
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "orig\n")
      pid = open(from)

      {:ok, _} = Dispatch.run(insert(0, 0, "Z", Meta.human()))
      assert Buffer.get_text(pid) == "Zorig\n"

      assert {:ok, {_f, ft}} = Session.rename_file(from, to)

      # same process, re-keyed under the new path; the old key is freed.
      assert Geex.BufferSupervisor.whereis(Path.expand(to)) == {:ok, pid}
      assert Geex.BufferSupervisor.whereis(Path.expand(from)) == :error
      # the active pid is unchanged (it is the same process).
      assert Session.active_buffer() == {:ok, pid}
      # in-memory edits and undo history survive the rename.
      assert Buffer.get_text(pid) == "Zorig\n"
      assert [_one] = Buffer.history(pid)

      # a save now lands on the NEW path, not the old one.
      assert {:ok, ^ft} = Buffer.save(pid)
      assert File.read!(to) == "Zorig\n"
      refute File.exists?(from)
    end

    test "refuses if the destination already exists (no clobber)" do
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "a")
      File.write!(to, "b")
      assert Session.rename_file(from, to) == {:error, :destination_exists}
      assert File.read!(from) == "a"
      assert File.read!(to) == "b"
    end

    test "refuses a no-op rename (same source and destination)" do
      path = tmp_path()
      File.write!(path, "a")
      assert Session.rename_file(path, path) == {:error, :same_path}
    end

    test "a missing source with no open buffer is a clean :enoent" do
      from = tmp_path()
      to = tmp_path()
      refute File.exists?(from)
      assert {:error, :enoent} = Session.rename_file(from, to)
    end

    test "renames a buffer opened on a not-yet-saved path (in-memory re-key, no disk file)" do
      from = tmp_path()
      to = tmp_path()
      refute File.exists?(from)
      pid = open(from)
      {:ok, _} = Dispatch.run(insert(0, 0, "draft", Meta.human()))
      assert Buffer.get_text(pid) == "draft"

      # File.rename hits :enoent (no disk file yet), but the buffer is real — re-key it.
      assert {:ok, {_f, ft}} = Session.rename_file(from, to)
      assert Geex.BufferSupervisor.whereis(Path.expand(to)) == {:ok, pid}
      assert Geex.BufferSupervisor.whereis(Path.expand(from)) == :error
      assert Buffer.get_text(pid) == "draft"

      # a later save now creates the file at the new path
      assert {:ok, ^ft} = Buffer.save(pid)
      assert File.read!(to) == "draft"
      refute File.exists?(from)
    end

    test "a dirty buffer's rename is not reverted by the reconcile floor (echo-suppressed)" do
      # the global reconciler is gated off under mix test; bring it up for this one test so
      # the rename actually seeds + the watcher glue runs (events injected, no real inotify).
      start_supervised!(Geex.Reconcile)
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "orig\n")
      pid = open(from)
      {:ok, _} = Dispatch.run(insert(0, 0, "EDIT-", Meta.human()))
      assert Buffer.get_text(pid) == "EDIT-orig\n"

      assert {:ok, {_f, ft}} = Session.rename_file(from, to)
      assert Buffer.get_text(pid) == "EDIT-orig\n"

      # the watcher's own moved-to event for `to` carries the moved bytes, which still equal the
      # re-keyed buffer's `synced` baseline — so reconcile sees no external change and skips it,
      # NOT adopting over the unsaved edits. A coalesced/settling repeat for the same unchanged
      # disk stays ignored too (baseline comparison is stateless), so a repeat can't revert them.
      for _ <- 1..2 do
        send(Geex.Reconcile, {:file_event, self(), {ft, [:moved_to]}})
        :sys.get_state(Geex.Reconcile)
      end

      assert Buffer.get_text(pid) == "EDIT-orig\n"
      assert Enum.all?(Buffer.history(pid), &(&1.meta.actor != :external))
    end

    test "a genuine external write after a dirty rename is still adopted (not over-suppressed)" do
      start_supervised!(Geex.Reconcile)
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "orig\n")
      pid = open(from)
      {:ok, _} = Dispatch.run(insert(0, 0, "EDIT-", Meta.human()))

      assert {:ok, {_f, ft}} = Session.rename_file(from, to)
      assert Buffer.get_text(pid) == "EDIT-orig\n"

      # a REAL external writer changes `to` to content that diverges from the buffer's baseline:
      # reconcile must adopt it as :external (the "never miss a genuine external change" half).
      File.write!(ft, "external-edit\n")
      send(Geex.Reconcile, {:file_event, self(), {ft, [:modified]}})
      :sys.get_state(Geex.Reconcile)

      assert Buffer.get_text(pid) == "external-edit\n"
      assert Enum.any?(Buffer.history(pid), &(&1.meta.actor == :external))
    end

    test "an event for the unchanged backing file is ignored even after further edits (edits preserved)" do
      # End-to-end baseline behavior: after a dirty rename the re-keyed buffer keeps its baseline
      # ("orig\n"); further edits don't change the baseline, so an event whose disk still equals
      # it is no external *change* and is ignored — the unsaved edits survive. Reconcile compares
      # disk to the baseline, never to the live text.
      start_supervised!(Geex.Reconcile)
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "orig\n")
      pid = open(from)
      {:ok, _} = Dispatch.run(insert(0, 0, "EDIT-", Meta.human()))

      assert {:ok, {_f, ft}} = Session.rename_file(from, to)
      # edit the buffer FURTHER, so its text no longer equals the moved bytes nor the original
      {:ok, _} = Dispatch.run(insert(0, 0, "MORE-", Meta.human()))
      assert Buffer.get_text(pid) == "MORE-EDIT-orig\n"

      # an external actor writes exactly the moved bytes — disk is unchanged from geex's move,
      # so it is suppressed; the unsaved edits survive (no revert, no spurious :external command)
      File.write!(ft, "orig\n")
      send(Geex.Reconcile, {:file_event, self(), {ft, [:modified]}})
      :sys.get_state(Geex.Reconcile)

      assert Buffer.get_text(pid) == "MORE-EDIT-orig\n"
      assert Enum.all?(Buffer.history(pid), &(&1.meta.actor != :external))
    end

    test "a buffer whose re-key call exits does not crash Session (safe_rename guard)" do
      # Deterministically exercise safe_rename/2's `catch :exit`: a stand-in registered under
      # `from` answers :snapshot (so dirty?/buffer_status don't crash) but EXITS on {:rename, _},
      # so rekey_buffer's Buffer.rename hits the guard — no registry-cleanup race needed. Without
      # the guard this :exit would propagate out of handle_call and crash the serialized Session.
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "x\n")
      {:ok, stub} = RenameExiter.start(Path.expand(from))
      session = Process.whereis(Geex.Session)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {_f, _t}} = Session.rename_file(from, to)
        end)

      assert Process.alive?(session)
      refute Process.alive?(stub)
      # the disk rename committed; only the (un-re-keyable) buffer side degraded, with a warning.
      refute File.exists?(from)
      assert File.read!(to) == "x\n"
      assert log =~ "could not re-key its buffer"
    end
  end

  describe "close_file/1 (buffer lifecycle — ADR-0019)" do
    test "closes the active buffer (no path), leaving the file on disk untouched" do
      path = tmp_path()
      File.write!(path, "keep\n")
      pid = open(path)
      assert Session.active_buffer() == {:ok, pid}

      assert {:ok, {label, false}} = Session.close_file()
      assert label == Path.expand(path)
      refute Process.alive?(pid)
      assert Session.active_buffer() == :error
      assert File.read!(path) == "keep\n"
    end

    test "closes a specific buffer by path" do
      path = tmp_path()
      File.write!(path, "")
      pid = open(path)
      assert {:ok, {_label, false}} = Session.close_file(path)
      refute Process.alive?(pid)
      assert Geex.BufferSupervisor.whereis(Path.expand(path)) == :error
    end

    test "closing a non-active buffer by path leaves the active buffer intact", %{buf: buf} do
      path = tmp_path()
      File.write!(path, "")
      other = open(path)
      Session.set_active_buffer(buf)
      assert Session.active_buffer() == {:ok, buf}

      assert {:ok, _} = Session.close_file(path)
      refute Process.alive?(other)
      assert Session.active_buffer() == {:ok, buf}
    end

    test "reports discarded? = true when closing a buffer with unsaved edits" do
      path = tmp_path()
      File.write!(path, "x")
      _pid = open(path)
      {:ok, _} = Dispatch.run(insert(0, 0, "Y", Meta.human()))
      assert {:ok, {_label, true}} = Session.close_file()
    end

    test "no active buffer is a clean :no_such_buffer" do
      Session.set_active_buffer(nil)
      assert Session.close_file() == {:error, :no_such_buffer}
    end

    test "a path with no open buffer is a clean :no_such_buffer" do
      path = tmp_path()
      assert Session.close_file(path) == {:error, :no_such_buffer}
    end

    test "closing the active pathless scratch buffer actually terminates it (no leak)", %{
      buf: buf
    } do
      # the scratch buffer from setup is active and is NOT a BufferSupervisor child, so a
      # discarded terminate/1 result would leave it alive while reporting "closed".
      assert {:ok, {"active buffer", false}} = Session.close_file()
      refute Process.alive?(buf)
      assert Session.active_buffer() == :error
    end

    test "closing a dirty scratch buffer reports the discard and frees the process", %{buf: buf} do
      {:ok, _} = Dispatch.run(insert(0, 0, "x", Meta.human()))
      assert {:ok, {"active buffer", true}} = Session.close_file()
      # the "discarded unsaved edits" report must be honest — the process is really gone.
      refute Process.alive?(buf)
    end

    test "close_file on a dead active buffer is a clean result, not a Session crash", %{buf: buf} do
      session = Process.whereis(Geex.Session)
      ref = Process.monitor(buf)
      Process.exit(buf, :kill)
      assert_receive {:DOWN, ^ref, :process, ^buf, _}

      # the active pid is unmonitored, so it is now stale; close must tolerate the dead pid
      # (the unguarded GenServer.call it used to make would crash Session).
      assert {:ok, {_label, false}} = Session.close_file()
      assert Process.alive?(session)
      assert Session.active_buffer() == :error
    end
  end
end
