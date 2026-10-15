defmodule Geex.HistoryTest do
  use ExUnit.Case, async: true
  doctest Geex.History

  alias Geex.{Blame, Command, Dispatch, EditorState, History}
  alias Geex.Command.Meta
  alias Geex.Commands.{Delete, Insert, Replace}

  defp human(cmd), do: Command.put_meta(cmd, Meta.human())

  defp insert(line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    human(cmd)
  end

  defp replace(line, text, actor \\ :external, group \\ 1) do
    {:ok, cmd} =
      Replace.parse(%{start_line: line, start_col: 0, end_line: line, end_col: 1, text: text})

    Command.put_meta(cmd, Meta.new(actor, reconcile: %{group: group, sha256: "x"}))
  end

  describe "dispatch/2" do
    test "records, dirties, clears redo and bumps the clock" do
      h = History.new("a\n")
      {:ok, h} = History.dispatch(h, insert(0, 0, "x"))
      {:ok, h, _} = History.undo(h)
      {:ok, h} = History.dispatch(h, insert(0, 0, "y"))

      assert History.text(h) == "ya\n"
      assert h.redo == []
      assert h.dirty
      assert h.seq == 3
    end

    test "a failing command changes nothing" do
      h = History.new("a")
      {:ok, bad} = Delete.parse(%{line: 9, col: 0})
      assert {:error, _} = History.dispatch(h, human(bad))
    end
  end

  describe "group/3" do
    test "all or nothing" do
      h = History.new("a\nb\n")
      {:ok, bad} = Delete.parse(%{line: 9, col: 0})
      assert {:error, _} = History.group(h, [replace(0, "A"), human(bad)], nil)
    end

    test "a baseline re-syncs and recomputes dirty; an empty group keeps redo" do
      h = History.new("a\n")
      {:ok, h} = History.group(h, [replace(0, "A")], "A\n")
      refute h.dirty
      assert h.synced == "A\n"

      {:ok, h, _} = History.undo(h)
      {:ok, h} = History.group(h, [], "a\n")
      assert length(h.redo) == 1
      refute h.dirty
    end
  end

  describe "undo/1, redo/1, sync/1" do
    test "undo onto the synced text is clean; redo is dirty again" do
      h = History.new("a\n")
      {:ok, h} = History.dispatch(h, insert(0, 0, "x"))
      {:ok, h, cmd} = History.undo(h)
      assert cmd.text == "x"
      refute h.dirty
      {:ok, h, _} = History.redo(h)
      assert h.dirty
      assert History.text(h) == "xa\n"
    end

    test "nothing to undo or redo" do
      h = History.new("")
      assert History.undo(h) == {:error, :nothing_to_undo}
      assert History.redo(h) == {:error, :nothing_to_redo}
    end

    test "sync makes the current text the clean baseline" do
      {:ok, h} = History.dispatch(History.new("a"), insert(0, 1, "b"))
      h = History.sync(h)
      assert {h.synced, h.dirty} == {"ab", false}
    end
  end

  describe "attest/3 and the group queries" do
    test "group ids come from the history, and attest relabels only its group" do
      h = History.new("a\nb\n")
      # whatever id a command arrives with, the history numbers its reconcile groups
      {:ok, h} = History.group(h, [replace(0, "A", :external, 99)], nil)
      {:ok, h} = History.group(h, [replace(1, "B", :external, 99)], nil)
      assert History.newest_group(h).group == 2
      assert h.next_group == 3

      agent = {:agent, %{harness: "claude-code", session: "s"}}
      h = History.attest(h, 1, agent)

      assert Enum.map(History.commands_oldest_first(h), & &1.meta.actor) == [agent, :external]
      assert [{^agent, 1}, {:external, 2}, nil] = h.blame
      refute History.unattested?(h, 1)
      assert History.unattested?(h, 2)
    end

    test "a group with no reconcile stamp leaves the counter alone" do
      {:ok, h} = History.group(History.new("a"), [insert(0, 0, "x")], nil)
      assert h.next_group == 1
    end
  end

  # The rule the durable ledger rests on (ADR-0033 §3): whatever sequence of transitions ran,
  # replaying the recorded commands over `base` rebuilds the same document and the same blame.
  test "after random dispatch/undo/redo, replay rebuilds the document and the blame" do
    :rand.seed(:exsss, {1, 2, 3})

    final =
      Enum.reduce(1..300, History.new("one\ntwo\nthree\n"), fn _, h ->
        case :rand.uniform(4) do
          1 -> step(History.undo(h), h)
          2 -> step(History.redo(h), h)
          _ -> random_edit(h)
        end
      end)

    {:ok, via_dispatch} = Dispatch.replay(final.base, History.commands_oldest_first(final))
    {:ok, editor, blame} = Blame.replay(final.base, History.commands_oldest_first(final))

    assert EditorState.text(via_dispatch) == History.text(final)
    assert editor == final.editor
    assert blame == final.blame
    assert length(final.blame) == length(EditorState.lines(final.editor))
  end

  defp step({:ok, h, _command}, _h), do: h
  defp step({:error, _}, h), do: h

  defp random_edit(h) do
    lines = EditorState.lines(h.editor)
    line = :rand.uniform(length(lines)) - 1
    col = :rand.uniform(String.length(Enum.at(lines, line)) + 1) - 1
    text = Enum.random(["x", "\n", "yy\nz", ""])
    actor = Enum.random([:human, :external, {:agent, %{harness: "h", session: "s"}}])
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})

    case History.dispatch(h, Command.put_meta(cmd, Meta.new(actor))) do
      {:ok, h} -> h
      {:error, _} -> h
    end
  end
end
