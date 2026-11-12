defmodule Geex.Loop.UndoStepTest do
  # ADR-0031's 2026-11-12 amendment through the loop's own handle_info/2: Alt+Z and Alt+Shift+Z
  # move what one action applied together, typing stays a step per key. Uses the global Session,
  # so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_undo_step_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp open(dir, text) do
    path = Path.join(dir, "a.txt")
    File.write!(path, text)
    {:ok, pid} = Session.open_file(path)
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid, path}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp cursor, do: elem(Session.snapshot(), 1).cursor

  test "a fast-forward of two hunks is one Alt+Z and one Alt+Shift+Z, and says so", %{dir: dir} do
    {state, buf, path} = open(dir, "1\n2\n3\n")
    File.write!(path, "ONE\n2\nTHREE\n")
    Buffer.disk_changed(buf, "ONE\n2\nTHREE\n")
    state = key(state, {:alt, ?d})
    assert Buffer.get_text(buf) == "ONE\n2\nTHREE\n"

    state = key(state, {:alt, ?z})
    assert Buffer.get_text(buf) == "1\n2\n3\n"
    assert state.notice == "undid 2 edits"
    # The cursor goes to where the step's changes begin: the topmost hunk.
    assert cursor() == {0, 0}

    state = key(state, {:alt, ?Z})
    assert Buffer.get_text(buf) == "ONE\n2\nTHREE\n"
    assert state.notice == "redid 2 edits"
  end

  test "typing is still one step per key, with no notice", %{dir: dir} do
    {state, buf, _path} = open(dir, "\n")
    state = Enum.reduce(["a", "b"], state, &key(&2, {:char, &1}))
    assert Buffer.get_text(buf) == "ab\n"

    state = key(state, {:alt, ?z})
    assert Buffer.get_text(buf) == "a\n"
    assert state.notice == nil
  end

  # BUG-14: an MCP `edit` (search/replace blocks) has no coordinates of its own; undo and redo
  # raised placing the cursor. Now it lands where the text changed.
  test "Alt+Z and Alt+Shift+Z after an MCP edit land where the text changed", %{dir: dir} do
    {state, buf, _path} = open(dir, "alpha\nbeta gamma\ndelta\n")

    {:ok, edit} =
      Geex.Commands.Edit.parse(%{"edits" => [%{"search" => "beta gamma", "replace" => "BETA"}]})

    edit = Geex.Command.put_meta(edit, Geex.Command.Meta.new({:llm, "m"}))
    {:ok, _} = Buffer.dispatch(buf, edit)
    assert Buffer.get_text(buf) == "alpha\nBETA\ndelta\n"

    state = key(state, {:alt, ?z})
    assert Buffer.get_text(buf) == "alpha\nbeta gamma\ndelta\n"
    assert cursor() == {1, 0}

    _ = key(state, {:alt, ?Z})
    assert Buffer.get_text(buf) == "alpha\nBETA\ndelta\n"
    assert cursor() == {1, 4}
  end

  test "a change inside a line lands at its first different character", %{dir: dir} do
    {state, buf, _path} = open(dir, "héllo wörld\n")

    {:ok, edit} =
      Geex.Commands.Edit.parse(%{"edits" => [%{"search" => "wörld", "replace" => "wérld"}]})

    {:ok, _} = Buffer.dispatch(buf, Geex.Command.put_meta(edit, Geex.Command.Meta.new(:human)))
    _ = key(state, {:alt, ?z})
    # "wörld" and "wérld" share "w" and the lead byte of ö/é: the cursor goes before the ö.
    assert cursor() == {0, 7}
  end
end
