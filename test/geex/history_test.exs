defmodule Geex.HistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  doctest Geex.History

  alias Geex.{Blame, Command, Dispatch, EditorState, Gen, History, Reconcile}
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

    # The history property's first counterexample (ADR-0044 §4), shrunk to five transitions:
    # the attestation came while one of the group's two commands was undone, and the redo
    # brought that command back still :external, so the group was half credited and a repeat
    # attestation was ignored (`unattested?/2` false).
    test "attest credits the group's undone commands too, so a redo stays credited" do
      ops = [{:reconcile, "a"}, {:reconcile, "\na\n"}, :undo, {:attest, "s1"}, :redo]
      h = Enum.reduce(ops, History.new(""), &run_op/2)

      agent = {:agent, %{harness: "claude-code", session: "s1"}}
      group = Enum.filter(h.commands, &match?(%{meta: %{reconcile: %{group: 2}}}, &1))
      assert Enum.map(group, & &1.meta.actor) == [agent, agent]
      # "\na\n": group 2 wrote the empty lines around group 1's "a"
      assert h.blame == [{agent, 2}, {:external, 1}, {agent, 2}]
      refute History.unattested?(h, 2)
    end

    test "a group with no reconcile stamp leaves the counter alone" do
      {:ok, h} = History.group(History.new("a"), [insert(0, 0, "x")], nil)
      assert h.next_group == 1
    end
  end

  # The rule the durable ledger rests on (ADR-0033 §3): whatever sequence of transitions ran,
  # replaying the recorded commands over `base` rebuilds the same document and the same blame.
  # ADR-0044 §6: the sequence is generated, so a failure shrinks to the fewest operations.
  property "after any sequence of transitions, replay rebuilds the document and the blame" do
    check all({base, ops} <- transitions()) do
      final = Enum.reduce(ops, History.new(base), &run_op/2)

      {:ok, via_dispatch} = Dispatch.replay(final.base, History.commands_oldest_first(final))
      {:ok, editor, blame} = Blame.replay(final.base, History.commands_oldest_first(final))

      assert EditorState.text(via_dispatch) == History.text(final)
      assert editor == final.editor
      assert blame == final.blame
      assert length(final.blame) == length(EditorState.lines(final.editor))
    end
  end

  # ADR-0044 §8.2: attribution is the history's. Whoever the blame names for a line is the writer
  # of a recorded command, and an attestation credits a reconcile group as a whole: all of its
  # commands carry one actor.
  property "the blame names only recorded writers, and a group has one actor" do
    check all({base, ops} <- transitions()) do
      final = Enum.reduce(ops, History.new(base), &run_op/2)
      writers = MapSet.new(final.commands, &Blame.writer/1)

      for writer <- final.blame,
          writer != nil,
          do: assert(writer in writers, "#{inspect(writer)} wrote no recorded command")

      final.commands
      |> Enum.filter(&match?(%{meta: %{reconcile: %{group: g}}} when is_integer(g), &1))
      |> Enum.group_by(& &1.meta.reconcile.group, & &1.meta.actor)
      |> Enum.each(fn {group, actors} ->
        assert length(Enum.uniq(actors)) == 1, "group #{group} has actors #{inspect(actors)}"
      end)
    end
  end

  defp transitions, do: tuple({Gen.text(), list_of(transition(), max_length: 100)})

  # What a buffer's history goes through: edits (an insert's line and column are seeds, taken
  # modulo the document as it is when the insert runs, so every insert lands somewhere valid and
  # shrinks toward 0:0), undo and redo, the disk changing (a reconcile group adopting it), an
  # attestation for the newest group (as `Geex.Buffer` takes one, hashes aside), and a save.
  defp transition do
    frequency([
      {1, constant(:undo)},
      {1, constant(:redo)},
      {3,
       tuple(
         {constant(:insert), non_negative_integer(), non_negative_integer(), Gen.insertion(),
          Gen.actor()}
       )},
      {1, tuple({constant(:reconcile), Gen.text(max_lines: 5)})},
      {1, tuple({constant(:attest), member_of(["s1", "s2"])})},
      {1, constant(:sync)}
    ])
  end

  defp run_op(:undo, h), do: step(History.undo(h), h)
  defp run_op(:redo, h), do: step(History.redo(h), h)
  defp run_op(:sync, h), do: History.sync(h)

  defp run_op({:insert, line_seed, col_seed, text, actor}, h) do
    lines = EditorState.lines(h.editor)
    line = rem(line_seed, length(lines))
    col = rem(col_seed, String.length(Enum.at(lines, line)) + 1)
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})

    case History.dispatch(h, Command.put_meta(cmd, Meta.new(actor))) do
      {:ok, h} -> h
      {:error, _} -> h
    end
  end

  defp run_op({:reconcile, disk}, h) do
    commands = Reconcile.external_commands(History.text(h), disk, h.synced, disk)

    case History.group(h, commands, disk) do
      {:ok, h} -> h
      {:error, _} -> h
    end
  end

  # Buffer's rule: the newest reconcile group, once, while every command of it is :external.
  defp run_op({:attest, session}, h) do
    case History.newest_group(h) do
      %{group: group} when is_integer(group) ->
        if History.unattested?(h, group),
          do: History.attest(h, group, {:agent, %{harness: "claude-code", session: session}}),
          else: h

      _none ->
        h
    end
  end

  defp step({:ok, h, _command}, _h), do: h
  defp step({:error, _}, h), do: h
end
