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
end
