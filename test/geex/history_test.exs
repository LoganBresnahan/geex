defmodule Geex.HistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  doctest Geex.History

  alias Geex.{Blame, Command, Dispatch, EditorState, Gen, History, Reconcile}
  alias Geex.Ledger.{Codec, Compact, Restore}
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
      ops = [{:reconcile, "a"}, {:reconcile, "\na\n"}, :undo, {:attest, "s1", 0}, :redo]
      h = Enum.reduce(ops, History.new(""), &run_op/2)

      agent = {:agent, %{harness: "claude-code", session: "s1"}}
      group = Enum.filter(h.commands, &match?(%{meta: %{reconcile: %{group: 2}}}, &1))
      assert Enum.map(group, & &1.meta.actor) == [agent, agent]
      # "\na\n": group 2 wrote the empty lines around group 1's "a"
      assert h.blame == [{agent, 2}, {:external, 1}, {agent, 2}]
      refute History.unattested?(h, 2)
    end

    # BUG-9: a compaction folded some of group 7's commands into the checkpoint (their lines carry
    # `{:external, 7}` in the checkpoint's blame) and kept one. The attestation must credit the
    # checkpoint's lines too, or the next undo, which rebuilds the blame from the checkpoint's,
    # brings them back `:external` while `unattested?/2` says the group is credited.
    test "attest credits the group's lines in a checkpoint's blame, through an undo" do
      h = History.from_checkpoint("a\nb", [{:external, 7}, {:external, 7}], "a\nb", 8)
      {:ok, h} = History.dispatch(h, replace(1, "B", :external, 7))
      agent = {:agent, %{harness: "claude-code", session: "s1"}}
      h = History.attest(h, 7, agent)
      assert h.blame == [{agent, 7}, {agent, 7}]

      {:ok, h} = History.dispatch(h, insert(1, 1, "!"))
      {:ok, h, _} = History.undo(h)
      assert h.blame == [{agent, 7}, {agent, 7}]
      assert h.base_blame == [{agent, 7}, {agent, 7}]
      refute History.unattested?(h, 7)
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
  # commands, applied or undone, carry one actor.
  property "the blame names only recorded writers, and a group has one actor" do
    check all({base, ops} <- transitions()) do
      final = Enum.reduce(ops, History.new(base), &run_op/2)
      writers = MapSet.new(final.commands, &Blame.writer/1)

      for writer <- final.blame,
          writer != nil,
          do: assert(writer in writers, "#{inspect(writer)} wrote no recorded command")

      (final.commands ++ final.redo)
      |> Enum.filter(&match?(%{meta: %{reconcile: %{group: g}}} when is_integer(g), &1))
      |> Enum.group_by(& &1.meta.reconcile.group, & &1.meta.actor)
      |> Enum.each(fn {group, actors} ->
        assert length(Enum.uniq(actors)) == 1, "group #{group} has actors #{inspect(actors)}"
      end)
    end
  end

  # BUG-8's law, aimed at directly (the general property above reaches it only now and then): a
  # reconcile group of several hunks, any number of them undone (all of them, and an older group's
  # too), then a late attestation, then any number redone. The group stays attestable, and the
  # attestation credits every command of it, applied or undone, and every line it wrote.
  property "an attestation credits its whole group, however much of it was undone" do
    check all(
            start <- Gen.text(max_lines: 3),
            lines <- list_of(Gen.line(), min_length: 3, max_length: 8),
            flips <- list_of(boolean(), length: length(lines)),
            undos <- integer(0..8),
            redos <- integer(0..8),
            session <- member_of(["s1", "s2"])
          ) do
      # distinct lines, and every other one rewritten (the first always), so the group has
      # separate hunks
      before = lines |> Enum.with_index() |> Enum.map(fn {l, i} -> "#{l}~#{i}" end)

      disk =
        before
        |> Enum.zip(flips)
        |> Enum.with_index()
        |> Enum.map(fn {{l, flip}, i} ->
          if rem(i, 2) == 0 and (flip or i == 0), do: "agent #{i}", else: l
        end)

      h = run_op({:reconcile, Enum.join(before, "\n")}, History.new(start))
      group = h.next_group
      h = run_op({:reconcile, Enum.join(disk, "\n")}, h)
      h = Enum.reduce(List.duplicate(:undo, undos), h, &run_op/2)

      assert group in Enum.map(History.attestable_groups(h), & &1.group)
      agent = {:agent, %{harness: "claude-code", session: session}}
      h = History.attest(h, group, agent)
      h = Enum.reduce(List.duplicate(:redo, redos), h, &run_op/2)

      ours =
        Enum.filter(h.commands ++ h.redo, &match?(%{meta: %{reconcile: %{group: ^group}}}, &1))

      assert ours != []
      assert Enum.all?(ours, &(&1.meta.actor == agent))
      refute History.unattested?(h, group)
      for {_actor, ^group} = writer <- h.blame, do: assert(writer == {agent, group})
    end
  end

  # BUG-9's law: a compaction (the real `Ledger.Compact` rewrite, encoded and restored as a
  # ledger would be) may fold some of a group's commands into the checkpoint and keep the rest;
  # an attestation for the group then credits every line it wrote, the checkpoint's included,
  # through any undo and redo after it. Stated as attesting commuting with undo and redo (the
  # whole history value alike either way round), which also catches crediting too much.
  property "after a compaction splits a group, an attestation credits all its lines" do
    check all(
            start <- Gen.text(max_lines: 3),
            lines <- list_of(Gen.line(), min_length: 3, max_length: 8),
            flips <- list_of(boolean(), length: length(lines)),
            typed <-
              list_of(
                tuple({non_negative_integer(), non_negative_integer(), member_of(["x", "\n"])}),
                max_length: 3
              ),
            keep_seed <- non_negative_integer(),
            aim_split <- frequency([{3, constant(true)}, {1, constant(false)}]),
            steps <- list_of(member_of([:undo, :redo]), max_length: 12),
            session <- member_of(["s1", "s2"])
          ) do
      before = lines |> Enum.with_index() |> Enum.map(fn {l, i} -> "#{l}~#{i}" end)

      disk =
        before
        |> Enum.zip(flips)
        |> Enum.with_index()
        |> Enum.map(fn {{l, flip}, i} ->
          if rem(i, 2) == 0 and (flip or i == 0), do: "agent #{i}", else: l
        end)

      h = run_op({:reconcile, Enum.join(before, "\n")}, History.new(start))
      group = h.next_group
      h = run_op({:reconcile, Enum.join(disk, "\n")}, h)
      h = Enum.reduce(typed, h, fn {l, c, t}, h -> run_op({:insert, l, c, t, :human}, h) end)

      # Mostly a `keep` that splits the group (all the typed commands and some, not all, of the
      # group's); otherwise any.
      ours = Enum.count(h.commands, &match?(%{meta: %{reconcile: %{group: ^group}}}, &1))

      keep =
        if aim_split and ours > 1,
          do: length(typed) + 1 + rem(keep_seed, ours - 1),
          else: rem(keep_seed, length(h.commands) + 1)

      restored = compact(h, keep)
      assert Compact.check(restored, h) == :ok

      # Attestable only while one of its commands is kept: a compaction that folds every command
      # of the group into the checkpoint (keep <= the typed edits, when not aiming) drops its
      # stamp, so a late attestation finds no group, even for the newest write (a known limit,
      # bugs.md BUG-9).
      if group in Enum.map(History.attestable_groups(restored), & &1.group) do
        agent = {:agent, %{harness: "claude-code", session: session}}
        h = Enum.reduce(steps, History.attest(restored, group, agent), &run_op/2)

        assert h == History.attest(Enum.reduce(steps, restored, &run_op/2), group, agent)
        for {_actor, ^group} = writer <- h.blame, do: assert(writer == {agent, group})
        refute History.unattested?(h, group)
      end
    end
  end

  # `h` compacted to its last `keep` commands and restored, as `mix geex.ledger compact` does.
  # The line split mirrors `Geex.Ledger`'s private `split_lines/1`; keep the two alike.
  defp compact(h, keep) do
    at = ~U[2026-11-09 12:00:00Z]
    bytes = h |> Compact.entries("/r/f", keep, "test") |> Enum.map_join(&Codec.encode(&1, at))

    {lines, _end} =
      bytes
      |> :binary.split("\n", [:global])
      |> Enum.drop(-1)
      |> Enum.map_reduce(0, fn line, offset ->
        next = offset + byte_size(line) + 1
        {{line, next}, next}
      end)

    {:ok, %{history: restored, stopped: nil}} = Restore.restore(lines)
    restored
  end

  defp transitions, do: tuple({Gen.text(), list_of(transition(), max_length: 100)})

  # What a buffer's history goes through: edits (an insert's line and column are seeds, taken
  # modulo the document as it is when the insert runs, so every insert lands somewhere valid and
  # shrinks toward 0:0), undo and redo, the disk changing (a reconcile group adopting it), a late
  # attestation for one of the groups `Geex.Buffer` would try (hashes aside), and a save.
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
      {1, tuple({constant(:attest), member_of(["s1", "s2"]), non_negative_integer()})},
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

  # Buffer's rule: one of the groups it tries (the newest undone, the newest applied; `pick`
  # stands for which one the attestation's hashes match), once, while all of it is :external.
  defp run_op({:attest, session, pick}, h) do
    case History.attestable_groups(h) do
      [] ->
        h

      stamps ->
        %{group: group} = Enum.at(stamps, rem(pick, length(stamps)))

        if History.unattested?(h, group),
          do: History.attest(h, group, {:agent, %{harness: "claude-code", session: session}}),
          else: h
    end
  end

  defp step({:ok, h, _command}, _h), do: h
  defp step({:error, _}, h), do: h
end
