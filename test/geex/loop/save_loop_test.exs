defmodule Geex.Loop.SaveLoopTest do
  # Saving off the key loop and quitting (ADR-0035's 2026-11-15 amendment, Logan's answers):
  # Ctrl-O and `save-all` run in a process of their own; Ctrl-O again says "still saving"; a quit
  # waits for the save (quit again cuts the save short; Esc: stay), and the second quit leaves, a
  # write under way given 1 s (2026-11-16); the terminal closing lets the save finish, up to 30 s
  # (2026-11-17); `cancel-save` stops a save before its write begins and never cuts one short; a
  # quit with unsaved edits names them first and the next quit leaves. The test process is the
  # loop: it stands in for `Geex.CLI` to see a quit.
  # Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, LoopSave, Session}
  alias Geex.Loop.{FileOps, SaveFlag}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_save_loop_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    Session.set_start(dir)
    Process.register(self(), Geex.CLI)

    on_exit(fn ->
      if Process.whereis(Geex.CLI), do: Process.unregister(Geex.CLI)

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
    {state, pid, path}
  end

  # A key, with no waiting on any save it starts.
  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp keys(state, events), do: Enum.reduce(events, state, &key(&2, &1))
  defp type(state, text), do: keys(state, Enum.map(String.graphemes(text), &{:char, &1}))
  defp run(state, command), do: state |> key({:alt, ?m}) |> type(command) |> key({:key, :enter})

  defp insert_z(buf) do
    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "z"})
    {:ok, _} = Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))
  end

  # The status line as the loop paints it.
  defp status_row(state) do
    {:noreply, _} = Loop.handle_info(:repaint, state)
    screen = Geex.Renderer.current()
    Enum.map_join(0..(screen.w - 1), &Geex.Screen.get_cell(screen, &1, screen.h - 1).char)
  end

  defp handle(state, msg) do
    {:noreply, state} = Loop.handle_info(msg, state)
    state
  end

  # A save in the loop's state whose process the test plays: `flag` says whether its write is
  # under way (`SaveFlag.write?/1`), and the test sends its answers.
  defp fake_save(state, kind, paths) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(pid)
    flag = SaveFlag.new()

    saving = %{
      pid: pid,
      ref: ref,
      flag: flag,
      kind: kind,
      paths: paths,
      results: [],
      slow: false,
      quit: nil,
      cut_after: nil,
      leave_by: nil,
      cancel: false
    }

    {%{state | saving: saving}, pid, flag}
  end

  describe "Ctrl-O off the key loop" do
    test "the key comes back at once; the file is written when the save answers", %{dir: dir} do
      {state, buf, path} = open(dir, "a.txt", "a  \n")
      state = key(state, {:ctrl, ?o})
      assert %{kind: :one, paths: [^path]} = state.saving

      state = LoopSave.finish(state)
      assert state.saving == nil
      assert File.read!(path) == "a\n"
      refute Buffer.status(buf).dirty
      assert state.notice == nil
    end

    test "Ctrl-O or save-all again while it runs: still saving", %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      state = state |> type("x") |> key({:ctrl, ?o})
      assert key(state, {:ctrl, ?o}).notice == "still saving"
      assert run(state, "save-all").notice == "still saving"
      LoopSave.finish(state)
    end

    test "past the time a save starts showing, it shows; a late word from it is nothing",
         %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      state = key(state, {:ctrl, ?o})
      pid = state.saving.pid
      state = handle(state, {:geex_save_slow, pid})
      assert state.saving.slow
      state = LoopSave.finish(state)
      assert handle(state, {:geex_save_slow, pid}) == state
    end

    test "a key typed while it runs lands; the file is the text before it or after it, whole",
         %{dir: dir} do
      {state, buf, path} = open(dir, "a.txt", "a\n")
      state = state |> key({:ctrl, ?o}) |> type("x") |> LoopSave.finish()

      assert Buffer.get_text(buf) == "xa\n"
      on_disk = File.read!(path)
      assert on_disk in ["a\n", "xa\n"]
      assert Buffer.status(buf).dirty == (on_disk == "a\n")
      assert state.saving == nil
    end

    # BUG-22: the file swapped for a FIFO, the stand-in for a disk that hung, is never opened.
    test "the file now a FIFO: not saved, said at once; a fast-forward says so too",
         %{dir: dir} do
      {state, buf, path} = open(dir, "a.txt", "a\n")
      state = type(state, "x")
      Geex.Fifo.make!(path)

      state =
        Geex.Fifo.within(path, 3_000, fn -> state |> key({:ctrl, ?o}) |> LoopSave.finish() end)

      assert state.notice == "not saved: the file is now a FIFO, a device or a socket"
      assert Buffer.status(buf).dirty

      state = Geex.Fifo.within(path, 3_000, fn -> run(state, "fast-forward") end)
      assert state.notice == "not read: the file is now a FIFO, a device or a socket"
      assert Buffer.get_text(buf) == "xa\n"
    end
  end

  describe "cancel-save" do
    test "with nothing saving, it says so", %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      assert run(state, "cancel-save").notice == "nothing is being saved"
    end

    test "before its write begins: over there and then; it begins no write", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, pid, flag} = fake_save(state, :one, [path])
      state = run(state, "cancel-save")

      assert state.notice == "save cancelled"
      assert state.saving == nil
      assert SaveFlag.write?(flag) == :cancelled
      assert SaveFlag.cancelled?(flag)
      # Its process isn't killed (mod-verify's review): it ends on its own, and a late word from
      # it is nothing.
      assert Process.alive?(pid)
      assert handle(state, {:geex_saved_file, pid, path, {:error, :cancelled}}) == state
    end

    test "while it writes: it finishes, and says so", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)

      state = run(state, "cancel-save")
      assert state.notice == "already writing: it finishes that file, then stops"
      assert Process.alive?(pid)

      # The write is answered: saved after all, and nothing more is begun.
      assert SaveFlag.done(flag) == :stop

      state =
        state |> handle({:geex_saved_file, pid, path, {:ok, path}}) |> handle({:geex_saved, pid})

      assert state.saving == nil
      assert state.notice == "saved (it was already writing)"
    end

    test "save-all stopped while a file writes: that file finishes, the rest aren't saved",
         %{dir: dir} do
      {state, _buf, a} = open(dir, "a.txt", "a\n")
      b = Path.join(dir, "b.txt")
      {state, pid, flag} = fake_save(state, :all, [a, b])
      :ok = SaveFlag.write?(flag)
      state = run(state, "cancel-save")
      assert SaveFlag.done(flag) == :stop

      state = state |> handle({:geex_saved_file, pid, a, {:ok, a}}) |> handle({:geex_saved, pid})
      assert state.notice == "save-all cancelled: saved 1 file; not saved: b.txt"
    end

    test "save-all stopped between files: what was saved, and what wasn't", %{dir: dir} do
      {state, _buf, a} = open(dir, "a.txt", "a\n")
      b = Path.join(dir, "b.txt")
      c = Path.join(dir, "c.txt")
      {state, pid, flag} = fake_save(state, :all, [a, b, c])

      # a.txt is done, and its answer sent, before the cancel.
      :ok = SaveFlag.write?(flag)
      send(self(), {:geex_saved_file, pid, a, {:ok, a}})
      :go = SaveFlag.done(flag)

      state = run(state, "cancel-save")
      assert state.notice == "save-all cancelled: saved 1 file; not saved: b.txt, c.txt"
      assert state.saving == nil
    end

    test "a real save cancelled: never half-written", %{dir: dir} do
      {state, buf, path} = open(dir, "a.txt", "a  \n")
      state = state |> key({:ctrl, ?o}) |> run("cancel-save") |> LoopSave.finish()

      # Stopped before its write, or finished: the file is one whole text, and the buffer's.
      assert File.read!(path) in ["a  \n", "a\n"]
      assert Buffer.get_text(buf) == File.read!(path)
      refute Buffer.status(buf).dirty
      assert state.saving == nil
    end
  end

  describe "quit while a save runs" do
    test "it waits, then quits once the save is done", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a  \n")
      state = state |> key({:ctrl, ?o}) |> key({:ctrl, ?x})
      assert state.saving.quit == :waiting
      refute_received :geex_quit

      _ = LoopSave.finish(state)
      assert_received :geex_quit
      assert File.read!(path) == "a\n"
    end

    test "Esc stays, and the save goes on", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a  \n")
      state = state |> key({:ctrl, ?o}) |> key({:ctrl, ?x}) |> key({:key, :esc})
      assert state.saving.quit == nil
      assert state.notice == "staying; the save goes on"

      _ = LoopSave.finish(state)
      refute_received :geex_quit
      assert File.read!(path) == "a\n"
    end

    test "quit again leaves now: a save whose write hasn't begun is stopped", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, pid, _flag} = fake_save(state, :one, [path])
      state = key(state, {:ctrl, ?x})
      refute_received :geex_quit

      _ = key(state, {:ctrl, ?q})
      assert_received :geex_quit
      assert SaveFlag.cancelled?(state.saving.flag)
      assert Process.alive?(pid)
    end

    test "quit again while it writes: it leaves once the write is done", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)

      state = state |> key({:ctrl, ?x}) |> key({:ctrl, ?x})
      Process.cancel_timer(state.saving.leave_by.timer)
      assert state.saving.quit == :now
      refute_received :geex_quit

      _ =
        state |> handle({:geex_saved_file, pid, path, {:ok, path}}) |> handle({:geex_saved, pid})

      assert_received :geex_quit
    end

    # 2026-11-16, Logan: the first quit warns; the second forces the exit.
    test "Esc after quit again doesn't call it off; save-all stops after this file", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :all, [path, Path.join(dir, "b.txt")])
      :ok = SaveFlag.write?(flag)

      state = state |> key({:ctrl, ?x}) |> key({:ctrl, ?x}) |> key({:key, :esc})
      Process.cancel_timer(state.saving.leave_by.timer)
      assert state.saving.quit == :now
      assert SaveFlag.done(flag) == :stop
    end

    test "from the command line, the wait shows: it closes", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, _flag} = fake_save(state, :one, [path])
      state = state |> key({:alt, ?m}) |> key({:ctrl, ?x})
      assert state.minibuffer.mode == :inactive
      assert state.saving.quit == :waiting
    end

    # 2026-11-16, Logan: the first quit warns; the second forces the exit.
    test "quit again while it writes: it leaves within 1 s, the write cut short if not done",
         %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)

      # The warning before the key that cuts it.
      state = key(state, {:ctrl, ?x})
      assert status_row(state) =~ "quits once saved (quit again cuts the save short; Esc: stay)"

      state = key(state, {:ctrl, ?q})
      %{token: token, timer: timer} = state.saving.leave_by
      assert_in_delta Process.read_timer(timer), 1_000, 200
      assert state.saving.quit == :now
      assert status_row(state) =~ "leaving once written (cut short after 1 s): writing a.txt…"
      refute_received :geex_quit

      # The second is over and the write isn't: it leaves, the write going till the VM stops. The
      # real timer's word, not one made here (mod-verify's mutant: a timer carrying another token
      # would never leave).
      assert_receive {:geex_leave_anyway, ^token} = word, 1_500
      _ = handle(state, word)
      assert_received :geex_quit
      assert Process.alive?(pid)
    end

    # mod-verify's review: a burst of keys from one read, or a key held down, is handled before
    # any frame shows the warning.
    test "quits after the second don't leave sooner than its 1 s", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)

      state = state |> key({:ctrl, ?x}) |> key({:ctrl, ?q})
      Process.cancel_timer(state.saving.leave_by.timer)
      state = key(state, {:ctrl, ?c})
      assert state.saving.quit == :now
      refute_received :geex_quit

      _ =
        state
        |> put_in([:saving, :cut_after], System.monotonic_time(:millisecond))
        |> key({:ctrl, ?c})

      assert_received :geex_quit
    end

    # mod-verify's review: three quits handled back to back, before any :repaint.
    test "three quits from one read leave the write going, and the warning to be seen",
         %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)

      state = state |> key({:ctrl, ?x}) |> key({:ctrl, ?x}) |> key({:ctrl, ?x})
      Process.cancel_timer(state.saving.leave_by.timer)
      assert state.saving.quit == :now
      refute_received :geex_quit
    end

    # mod-verify's review: a quit from the command line or the settings view, which draw over the
    # status line, while the first quit waits.
    test "the second quit closes the command line or the settings view: the warning shows",
         %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")

      for open_it <- [{:alt, ?m}, {:alt, ?y}] do
        {state, _pid, flag} = fake_save(state, :one, [path])
        :ok = SaveFlag.write?(flag)
        state = state |> key({:ctrl, ?x}) |> key(open_it) |> key({:ctrl, ?x})
        Process.cancel_timer(state.saving.leave_by.timer)
        assert state.saving.quit == :now
        assert state.minibuffer.mode == :inactive
        assert state.settings == nil
        assert status_row(state) =~ "leaving once written (cut short after 1 s)"
      end
    end

    # mod-verify's reviews: the status line is clipped at its edge, a real save is dirty, and a
    # long name, `[+]` and behind left the first warning cut on 80 columns. While a quit waits,
    # the warning leads the line.
    test "on 80 columns, a long nested name with [+] and behind: each warning shows whole",
         %{dir: dir} do
      name = "a_rather_long_file_name_x.ex"
      assert String.length(name) == 28
      File.mkdir_p!(Path.join(dir, "lib/geex/loop"))
      {state, buf, path} = open(dir, "lib/geex/loop/" <> name, "a\n")
      insert_z(buf)
      :behind = Buffer.disk_changed(buf, "new\n")
      {state, _pid, flag} = fake_save(%{state | w: 80}, :one, [path])
      :ok = SaveFlag.write?(flag)
      assert status_row(state) =~ " #{name} [+]  behind disk (Alt+D)"

      waiting = key(state, {:ctrl, ?x})

      assert status_row(waiting) =~
               ~r/^ quits once saved \(quit again cuts the save short; Esc: stay\): saving a_r/

      now = key(waiting, {:ctrl, ?x})
      Process.cancel_timer(now.saving.leave_by.timer)
      assert status_row(now) =~ ~r/^ leaving once written \(cut short after 1 s\): writing a_r/

      signalled = handle(waiting, :geex_shutdown)
      Process.cancel_timer(signalled.saving.leave_by.timer)

      assert status_row(signalled) =~
               ~r/^ leaving once saved \(quit again cuts it short\): saving/
    end

    # mod-verify's review: while a quit waits the warning leads the line and "behind disk" isn't
    # drawn, so a press where it would be is on the warning, and does nothing.
    test "a press on the warning, where behind disk would be, doesn't fast-forward", %{dir: dir} do
      {state, buf, path} = open(dir, "a.txt", "a\n")
      File.write!(path, "new\n")
      :behind = Buffer.disk_changed(buf, "new\n")
      {state, _pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)

      state = key(state, {:ctrl, ?x})
      refute status_row(state) =~ "behind disk"
      press = %{action: :press, button: :left, x: 9, y: state.h - 1, mods: []}
      state = key(%{state | click: nil}, {:mouse, press})
      assert Buffer.status(buf).behind
      assert state.saving.quit == :waiting
    end

    test "save-all's warning names the file being written", %{dir: dir} do
      {state, _buf, a} = open(dir, "a.txt", "a\n")
      b = Path.join(dir, "b.txt")
      {state, pid, flag} = fake_save(state, :all, [a, b])
      :ok = SaveFlag.write?(flag)
      state = state |> key({:ctrl, ?x}) |> key({:ctrl, ?x})
      Process.cancel_timer(state.saving.leave_by.timer)
      assert status_row(state) =~ "writing a.txt…"

      state = handle(state, {:geex_saved_file, pid, a, {:ok, a}})
      assert status_row(state) =~ "writing b.txt…"
    end

    # 2026-11-17, Logan: closing the window shows no warning, so a save it would cut isn't cancelled.
    test "the terminal closing, SIGTERM or SIGHUP leaves once the save is done, up to 30 s",
         %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")

      for msg <- [{:geex_io, :eof}, :geex_shutdown], writing? <- [false, true] do
        # Whether or not its write has begun, the save runs on.
        {state, pid, flag} = fake_save(state, :one, [path])
        if writing?, do: :ok = SaveFlag.write?(flag)
        waiting = handle(state, msg)
        Process.cancel_timer(waiting.saving.leave_by.timer)
        assert waiting.saving.quit == :shutdown
        refute SaveFlag.cancelled?(flag)
        refute waiting.saving.cancel

        assert status_row(waiting) =~
                 "leaving once saved (quit again cuts it short): saving a.txt…"

        refute_received :geex_quit

        _ =
          waiting
          |> handle({:geex_saved_file, pid, path, {:ok, path}})
          |> handle({:geex_saved, pid})

        assert_received :geex_quit
      end
    end

    test "its wait is 30 s; nothing saving, it leaves at once", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      _ = handle(state, :geex_shutdown)
      assert_received :geex_quit

      {state, _pid, _flag} = fake_save(state, :one, [path])
      waiting = handle(state, :geex_shutdown)
      assert_in_delta Process.read_timer(waiting.saving.leave_by.timer), 30_000, 200
      Process.cancel_timer(waiting.saving.leave_by.timer)
    end

    test "a save-all goes on to its last file", %{dir: dir} do
      {state, _buf, a} = open(dir, "a.txt", "a\n")
      b = Path.join(dir, "b.txt")
      {state, pid, flag} = fake_save(state, :all, [a, b])
      :ok = SaveFlag.write?(flag)
      waiting = handle(state, :geex_shutdown)
      Process.cancel_timer(waiting.saving.leave_by.timer)
      assert SaveFlag.done(flag) == :go

      waiting = handle(waiting, {:geex_saved_file, pid, a, {:ok, a}})
      assert status_row(waiting) =~ "saving b.txt…"
      refute_received :geex_quit

      _ = waiting |> handle({:geex_saved_file, pid, b, {:ok, b}}) |> handle({:geex_saved, pid})
      assert_received :geex_quit
    end

    test "a cancel-save made while it writes stands: save-all stops after this file", %{dir: dir} do
      {state, _buf, a} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :all, [a, Path.join(dir, "b.txt")])
      :ok = SaveFlag.write?(flag)
      waiting = state |> run("cancel-save") |> handle(:geex_shutdown)
      Process.cancel_timer(waiting.saving.leave_by.timer)
      assert waiting.saving.cancel
      assert SaveFlag.done(flag) == :stop
    end

    test "a shutdown's wait for a write that hangs ends: it leaves anyway", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)
      waiting = handle(state, :geex_shutdown)
      %{token: token, timer: timer} = waiting.saving.leave_by
      Process.cancel_timer(timer)
      refute_received :geex_quit

      # A second signal keeps the first deadline. A signal after a second quit, which cut the save
      # short, changes nothing: its 1 s stands.
      assert handle(waiting, :geex_shutdown).saving.leave_by == waiting.saving.leave_by
      quit_twice = state |> key({:ctrl, ?x}) |> key({:ctrl, ?x})
      Process.cancel_timer(quit_twice.saving.leave_by.timer)
      assert handle(quit_twice, :geex_shutdown) == quit_twice

      _ = handle(waiting, {:geex_leave_anyway, token})
      assert_received :geex_quit

      # Once the save is over, or from an earlier save, the late word is nothing.
      _ = handle(%{waiting | saving: nil}, {:geex_leave_anyway, token})
      _ = handle(waiting, {:geex_leave_anyway, make_ref()})
      refute_received :geex_quit
    end

    # mod-verify's review: SIGTERM with the terminal still there, the command line or the settings
    # view open.
    test "a signal closes the command line or the settings view: its warning shows", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")

      for open_it <- [{:alt, ?m}, {:alt, ?y}] do
        {state, _pid, flag} = fake_save(state, :one, [path])
        :ok = SaveFlag.write?(flag)
        waiting = state |> key(open_it) |> handle(:geex_shutdown)
        Process.cancel_timer(waiting.saving.leave_by.timer)
        assert waiting.minibuffer.mode == :inactive
        assert waiting.settings == nil
        assert status_row(waiting) =~ "leaving once saved (quit again cuts it short)"
      end
    end

    test "after a signal, a quit within 1 s doesn't cut; one after does", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)
      waiting = handle(state, :geex_shutdown)
      Process.cancel_timer(waiting.saving.leave_by.timer)

      waiting = key(waiting, {:ctrl, ?x})
      assert waiting.saving.quit == :shutdown
      refute_received :geex_quit

      _ =
        waiting
        |> put_in([:saving, :cut_after], System.monotonic_time(:millisecond))
        |> key({:ctrl, ?x})

      assert_received :geex_quit
    end

    # A save whose write hasn't begun, cut short by a quit or by the deadline, begins no write
    # while the VM stops.
    test "after a signal, a quit or the deadline cancels a save not yet writing", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")

      for cut <- [:quit, :deadline] do
        {state, pid, flag} = fake_save(state, :one, [path])
        waiting = handle(state, :geex_shutdown)
        %{token: token, timer: timer} = waiting.saving.leave_by
        Process.cancel_timer(timer)
        refute SaveFlag.cancelled?(flag)

        _ =
          case cut do
            :quit ->
              waiting
              |> put_in([:saving, :cut_after], System.monotonic_time(:millisecond))
              |> key({:ctrl, ?x})

            :deadline ->
              handle(waiting, {:geex_leave_anyway, token})
          end

        assert_received :geex_quit
        assert SaveFlag.cancelled?(flag)
        assert SaveFlag.write?(flag) == :cancelled
        assert Process.alive?(pid)
      end
    end

    # mod-verify's review: Esc called a signal off, and its timer then cut a later wait short.
    test "Esc doesn't call a shutdown off", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)
      waiting = handle(state, :geex_shutdown)
      Process.cancel_timer(waiting.saving.leave_by.timer)

      still = key(waiting, {:key, :esc})
      assert still.saving.quit == :shutdown

      _ =
        still |> handle({:geex_saved_file, pid, path, {:ok, path}}) |> handle({:geex_saved, pid})

      assert_received :geex_quit
    end

    test "a real save, quit twice: it leaves, and the file is never half-written", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a  \n")
      state = state |> key({:ctrl, ?o}) |> key({:ctrl, ?x}) |> key({:ctrl, ?x})
      _ = LoopSave.finish(state)
      assert_received :geex_quit
      assert File.read!(path) in ["a  \n", "a\n"]
    end
  end

  describe "quit with unsaved edits" do
    test "the first quit names them; the next quit leaves", %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      state = state |> type("x") |> key({:ctrl, ?x})

      refute_received :geex_quit
      # The ledger is off under `mix test`: nothing keeps them.
      assert state.notice == "unsaved: a.txt (not kept: a.txt); quit again to leave"

      _ = key(state, {:ctrl, ?c})
      assert_received :geex_quit
    end

    test "any other key in between disarms it", %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      state = state |> type("x") |> key({:ctrl, ?x}) |> key({:key, :right}) |> key({:ctrl, ?x})
      refute_received :geex_quit
      assert state.notice =~ "quit again to leave"
    end

    test "quit typed in the command line is the next quit too", %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      state = state |> type("x") |> key({:ctrl, ?x})
      _ = run(state, "exit")
      assert_received :geex_quit
    end

    # mod-verify's review: the command line and the settings view draw over the status line.
    test "from the command line or the settings view, the warning shows: they close", %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      state = type(state, "x")

      from_line = state |> key({:alt, ?m}) |> key({:ctrl, ?x})
      assert from_line.minibuffer.mode == :inactive
      assert from_line.notice =~ "quit again to leave"
      assert from_line.quit_armed

      from_settings = state |> key({:alt, ?y}) |> key({:ctrl, ?x})
      assert from_settings.settings == nil
      assert from_settings.notice =~ "quit again to leave"
      refute_received :geex_quit
    end

    test "a command run from the command line disarms it; a palette quit is the next quit",
         %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      state = state |> type("x") |> key({:ctrl, ?x}) |> run("select-all")
      refute state.quit_armed
      state = key(state, {:ctrl, ?x})
      refute_received :geex_quit
      assert state.notice =~ "quit again to leave"

      _ = state |> key({:alt, ?b}) |> type("quit") |> key({:key, :enter})
      assert_received :geex_quit
    end

    test "nothing unsaved: the first quit leaves", %{dir: dir} do
      {state, _buf, _path} = open(dir, "a.txt", "a\n")
      _ = key(state, {:ctrl, ?x})
      assert_received :geex_quit
    end

    test "kept for next time when the ledger has them; several files, a few named", %{dir: dir} do
      ledger = Path.join(dir, "ledger")
      Application.put_env(:geex, :ledger, true)
      Application.put_env(:geex, :ledger_dir, ledger)

      on_exit(fn ->
        Application.delete_env(:geex, :ledger)
        Application.delete_env(:geex, :ledger_dir)
      end)

      state =
        Enum.reduce(~w(a b c d e), nil, fn name, _ ->
          {state, _buf, _path} = open(dir, name <> ".txt", "x\n")
          type(state, "y")
        end)

      state = key(state, {:ctrl, ?x})

      assert state.notice =~
               ~r/^unsaved: \w\.txt, \w\.txt, \w\.txt and 2 more \(kept for next time\)/

      refute_received :geex_quit
    end
  end

  # mod-verify's review: the write had already read its path, so a rename or delete during it
  # brought the old file back; a close ended the buffer mid-save.
  describe "a rename, delete or close while a save writes" do
    test "Session refuses each, touching nothing; once the write is done they go", %{dir: dir} do
      {_state, buf, path} = open(dir, "a.txt", "a\n")
      to = Path.join(dir, "b.txt")
      {:ok, _} = Buffer.begin_write(buf)

      assert Session.rename_file(path, to) == {:error, :saving}
      assert Session.delete_file(path) == {:error, :saving}
      assert Session.close_buffer(buf) == {:error, :saving}
      assert File.exists?(path)
      refute File.exists?(to)

      assert FileOps.step({:rename, path, to}, dir) ==
               {:done, "not renamed: a.txt to b.txt: it's being saved"}

      {:ok, _} = Buffer.end_write(buf, :ok)
      assert {:ok, _} = Session.rename_file(path, to)
      assert Buffer.status(buf).path == to
      assert {:ok, _} = Buffer.begin_write(buf)
      {:ok, _} = Buffer.end_write(buf, :ok)
    end

    test "a rename that fails on disk lets saves begin again", %{dir: dir} do
      {_state, buf, path} = open(dir, "a.txt", "a\n")
      # Into a directory it may not write: the disk refuses.
      ro = Path.join(dir, "ro")
      File.mkdir_p!(ro)
      File.chmod!(ro, 0o500)
      on_exit(fn -> File.chmod(ro, 0o700) end)
      assert {:error, :eacces} = Session.rename_file(path, Path.join(ro, "b.txt"))
      assert {:ok, _} = Buffer.begin_write(buf)
      {:ok, _} = Buffer.end_write(buf, :ok)
    end

    test "the loop's own save: closing its tab is refused, the tab kept", %{dir: dir} do
      {state, buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, _flag} = fake_save(state, :one, [path])
      state = key(state, {:alt, ?w})
      assert state.notice == "not closed: it's being saved (cancel-save stops it)"
      assert Process.alive?(buf)
      assert buf in Enum.map(Session.buffers(), & &1.pid)
    end
  end
end
