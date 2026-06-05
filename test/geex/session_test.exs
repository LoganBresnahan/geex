defmodule Geex.SessionTest do
  # Drives the application-global Geex.Session singleton — not parallel-safe.
  use ExUnit.Case, async: false

  alias Geex.Buffer
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Dispatch
  alias Geex.Session

  setup do
    buf = start_supervised!({Buffer, text: ""})
    Session.set_active_buffer(buf)
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
end
