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

  setup do
    %{buf: start_supervised!({Buffer, text: ""})}
  end

  test "dispatch threads a command into the EditorState and records it with provenance", %{buf: buf} do
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

  test "a raising command is contained: buffer stays alive, state + history untouched", %{buf: buf} do
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
end
