defmodule Geex.Loop.SaveLoopTest do
  # Saving off the key loop and quitting (ADR-0035's 2026-11-15 amendment, Logan's answers):
  # Ctrl-O and `save-all` run in a process of their own; Ctrl-O again says "still saving"; a quit
  # waits for the save (quit again: leave now; Esc: stay); `cancel-save` stops a save before its
  # write begins and never cuts one short; a quit with unsaved edits names them first and the
  # next quit leaves. The test process is the loop: it stands in for `Geex.CLI` to see a quit.
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
      assert state.saving.quit == :now
      refute_received :geex_quit

      _ =
        state |> handle({:geex_saved_file, pid, path, {:ok, path}}) |> handle({:geex_saved, pid})

      assert_received :geex_quit
    end

    test "Esc after quit again: it stays, and the cancel stands", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :all, [path, Path.join(dir, "b.txt")])
      :ok = SaveFlag.write?(flag)

      state = state |> key({:ctrl, ?x}) |> key({:ctrl, ?x}) |> key({:key, :esc})
      assert state.saving.quit == nil
      assert state.notice == "staying; the save stops after this file"
      assert SaveFlag.done(flag) == :stop
    end

    test "from the command line, the wait shows: it closes", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, _flag} = fake_save(state, :one, [path])
      state = state |> key({:alt, ?m}) |> key({:ctrl, ?x})
      assert state.minibuffer.mode == :inactive
      assert state.saving.quit == :waiting
    end

    test "the terminal closing is a quit that leaves now", %{dir: dir} do
      {state, _buf, path} = open(dir, "a.txt", "a\n")
      {state, _pid, flag} = fake_save(state, :one, [path])
      :ok = SaveFlag.write?(flag)
      state = handle(state, {:geex_io, :eof})
      assert state.saving.quit == :now
      refute_received :geex_quit
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
      # Under a file, not a directory: the disk refuses.
      File.write!(Path.join(dir, "c.txt"), "")
      assert {:error, :enotdir} = Session.rename_file(path, Path.join(dir, "c.txt/b.txt"))
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
