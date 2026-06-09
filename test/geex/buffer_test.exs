defmodule Geex.BufferTest.Crashing do
  @moduledoc false
  defstruct [:meta]
  def run(_command, _state), do: raise("boom")
end

defmodule Geex.BufferTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.{Delete, Insert}

  defp insert(line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    Command.put_meta(cmd, Meta.human())
  end

  defp delete(line, col, count) do
    {:ok, cmd} = Delete.parse(%{line: line, col: col, count: count})
    Command.put_meta(cmd, Meta.human())
  end

  defp replace(sl, sc, el, ec, text) do
    {:ok, cmd} =
      Geex.Commands.Replace.parse(%{
        start_line: sl,
        start_col: sc,
        end_line: el,
        end_col: ec,
        text: text
      })

    Command.put_meta(cmd, Meta.human())
  end

  setup do
    %{buf: start_supervised!({Buffer, text: ""})}
  end

  test "subscribe/2 notifies on change; unsubscribe/2 stops the notifications", %{buf: buf} do
    {:ok, _v} = Buffer.subscribe(buf, self())
    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "a"))
    # version + the edit's byte footprint (ADR-0022 optimistic overlay)
    assert_receive {:geex_buffer_change, ^buf, _, %{at: 0, removed: 0, added: 1}}, 500

    :ok = Buffer.unsubscribe(buf, self())
    # A sync round-trip ensures the unsubscribe cast is processed before the next edit.
    _ = Buffer.snapshot(buf)
    {:ok, _} = Buffer.dispatch(buf, insert(0, 1, "b"))
    refute_receive {:geex_buffer_change, ^buf, _, _}, 200
  end

  test "dispatch threads a command into the EditorState and records it with provenance", %{
    buf: buf
  } do
    cmd = insert(0, 0, "hello") |> Command.put_meta(Meta.llm("claude-opus-4-8"))
    assert {:ok, snap} = Buffer.dispatch(buf, cmd)
    assert snap.text == "hello"
    assert snap.version == 1
    assert [recorded] = snap.history
    assert recorded.meta.actor == {:llm, "claude-opus-4-8"}
  end

  test "history preserves order and provenance across multiple dispatches", %{buf: buf} do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "hello"))
    {:ok, _} = Buffer.dispatch(buf, insert(0, 5, " world"))
    {:ok, snap} = Buffer.dispatch(buf, delete(0, 0, 6))

    assert snap.text == "world"
    assert snap.version == 3
    assert Enum.map(snap.history, & &1.__struct__) == [Insert, Insert, Delete]
    assert Enum.all?(snap.history, &(&1.meta.actor == :human))
  end

  test "a failing command leaves state and history unchanged and is not recorded", %{buf: buf} do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "abc"))
    assert {:error, :row_out_of_range} = Buffer.dispatch(buf, insert(9, 0, "x"))

    snap = Buffer.snapshot(buf)
    assert snap.text == "abc"
    assert snap.version == 1
    assert length(snap.history) == 1
  end

  test "read-only query surface: get_text/1, snapshot/1, history/1 (§15b)", %{buf: buf} do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "data"))

    assert Buffer.get_text(buf) == "data"

    snap = Buffer.snapshot(buf)
    assert snap.text == "data"
    assert snap.lines == ["data"]
    assert snap.dirty == true
    assert snap.path == nil

    assert [%Insert{}] = Buffer.history(buf)
  end

  test "a Replace command edits a multi-line range through the dispatcher", %{buf: buf} do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "one\ntwo\nthree"))
    {:ok, snap} = Buffer.dispatch(buf, replace(0, 1, 2, 2, "X\nY"))
    assert snap.text == "oX\nYree"
    assert snap.version == 2

    assert Enum.map(snap.history, & &1.__struct__) == [
             Geex.Commands.Insert,
             Geex.Commands.Replace
           ]
  end

  test "a raising command is contained: buffer stays alive, state + history untouched", %{
    buf: buf
  } do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "ok"))
    assert {:error, {:command_crashed, _}} = Buffer.dispatch(buf, %Geex.BufferTest.Crashing{})
    assert Process.alive?(buf)
    snap = Buffer.snapshot(buf)
    assert snap.text == "ok"
    assert snap.version == 1
  end

  test "a fresh buffer is clean with empty history", %{buf: buf} do
    snap = Buffer.snapshot(buf)
    assert snap.text == ""
    assert snap.version == 0
    assert snap.dirty == false
    assert snap.history == []
  end

  describe "undo/redo (ADR-0031)" do
    test "undo reverts the newest edit and returns the undone command; redo re-applies it", %{
      buf: buf
    } do
      {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "hello"))
      {:ok, _} = Buffer.dispatch(buf, insert(0, 5, " world"))

      assert {:ok, snap, %Insert{col: 5, text: " world"}} = Buffer.undo(buf)
      assert snap.text == "hello"
      assert snap.version == 1
      assert Enum.map(snap.history, & &1.__struct__) == [Insert]

      assert {:ok, snap, %Insert{col: 5, text: " world"}} = Buffer.redo(buf)
      assert snap.text == "hello world"
      assert snap.version == 2
    end

    test "undo on empty history / redo with nothing undone are errors", %{buf: buf} do
      assert {:error, :nothing_to_undo} = Buffer.undo(buf)
      assert {:error, :nothing_to_redo} = Buffer.redo(buf)

      {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "x"))
      assert {:error, :nothing_to_redo} = Buffer.redo(buf)
    end

    test "a fresh edit after an undo clears the redo future", %{buf: buf} do
      {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "a"))
      {:ok, _} = Buffer.dispatch(buf, insert(0, 1, "b"))
      {:ok, _, _} = Buffer.undo(buf)
      {:ok, snap} = Buffer.dispatch(buf, insert(0, 1, "c"))
      assert snap.text == "ac"
      assert {:error, :nothing_to_redo} = Buffer.redo(buf)
    end

    test "undo back to the synced baseline clears the dirty flag" do
      buf = start_supervised!(Supervisor.child_spec({Buffer, text: "base"}, id: :baseline_buf))
      {:ok, snap} = Buffer.dispatch(buf, insert(0, 4, "!"))
      assert snap.dirty == true
      assert {:ok, snap, _} = Buffer.undo(buf)
      assert snap.text == "base"
      assert snap.dirty == false
    end

    test "undo/redo round-trips a mixed Insert/Delete/Replace history (replay-from-base)", %{
      buf: buf
    } do
      {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "one\ntwo\nthree"))
      {:ok, _} = Buffer.dispatch(buf, replace(0, 1, 2, 2, "X\nY"))
      {:ok, s3} = Buffer.dispatch(buf, delete(0, 0, 1))
      assert s3.text == "X\nYree"

      {:ok, u1, %Delete{}} = Buffer.undo(buf)
      assert u1.text == "oX\nYree"
      {:ok, u2, %Geex.Commands.Replace{}} = Buffer.undo(buf)
      assert u2.text == "one\ntwo\nthree"
      {:ok, u3, %Insert{}} = Buffer.undo(buf)
      assert u3.text == ""
      assert u3.version == 0
      assert u3.dirty == false

      {:ok, r1, %Insert{}} = Buffer.redo(buf)
      assert r1.text == "one\ntwo\nthree"
      {:ok, r2, %Geex.Commands.Replace{}} = Buffer.redo(buf)
      assert r2.text == "oX\nYree"
      {:ok, r3, %Delete{}} = Buffer.redo(buf)
      assert r3.text == "X\nYree"
    end

    test "undo emits a :reset change so overlays re-derive (not a byte-shiftable footprint)", %{
      buf: buf
    } do
      {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "a"))
      {:ok, _v} = Buffer.subscribe(buf, self())
      {:ok, _, _} = Buffer.undo(buf)
      assert_receive {:geex_buffer_change, ^buf, 0, :reset}, 500
    end
  end
end
