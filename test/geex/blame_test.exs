defmodule Geex.BlameTest do
  use ExUnit.Case, async: true
  doctest Geex.Blame

  alias Geex.{Blame, Buffer, Command, EditorState, Reconcile}
  alias Geex.Command.Meta
  alias Geex.Commands.{Insert, Replace}

  defp hex(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp agent(session),
    do: {:agent, %{harness: "claude-code", session: session, turn: "t1", tool_use: "u1"}}

  defp attest(buf, before, after_text, session \\ "s1") do
    Buffer.attest(buf, %{
      before: hex(before),
      sha256: hex(after_text),
      harness: "claude-code",
      session: session,
      turn: "t1",
      tool_use: "u1"
    })
  end

  defp type(buf, line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
  end

  defp actors(buf), do: buf |> Buffer.snapshot() |> Map.fetch!(:blame) |> Enum.map(&actor/1)
  defp actor(nil), do: nil
  defp actor({actor, _group}), do: actor

  describe "step/4 — the changed lines take the writer" do
    test "a deletion drops the deleted lines' entries" do
      w = {:human, nil}
      assert Blame.step([:a, :b, :c], ["a", "b", "c"], ["a", "c"], w) == [:a, :c]
    end

    test "no change keeps everything" do
      assert Blame.step([:a, :b], ["a", "b"], ["a", "b"], {:human, nil}) == [:a, :b]
    end

    test "a change spanning lines marks only the rewritten middle" do
      w = {:external, 1}
      assert Blame.step([:a, :b, :c, :d], ~w(a b c d), ~w(a X Y Z d), w) == [:a, w, w, w, :d]
    end
  end

  describe "replay/2" do
    test "ends where Dispatch.replay/2 ends, with one entry per line" do
      base = EditorState.new("one\ntwo\n")
      {:ok, c1} = Insert.parse(%{line: 1, col: 0, text: "new\n"})

      {:ok, c2} =
        Replace.parse(%{start_line: 0, start_col: 0, end_line: 0, end_col: 3, text: "ONE"})

      cmds = [Command.put_meta(c1, Meta.human()), Command.put_meta(c2, Meta.new(agent("s9")))]

      {:ok, via_dispatch} = Geex.Dispatch.replay(base, cmds)
      {:ok, editor, blame} = Blame.replay(base, cmds)

      assert EditorState.text(editor) == EditorState.text(via_dispatch)
      assert length(blame) == length(EditorState.lines(editor))
      assert Enum.map(blame, &actor/1) == [agent("s9"), :human, nil, nil]
    end
  end

  describe "a buffer's blame follows its history" do
    test "an attested agent hunk marks its lines; a shell write doesn't" do
      buf = start_supervised!({Buffer, text: "a\nb\nc\nd\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "a\nB-agent\nc\nd\n")
      :attested = attest(buf, "a\nb\nc\nd\n", "a\nB-agent\nc\nd\n")
      {:reconciled, _} = Reconcile.reconcile(buf, "a\nB-agent\nc\nD-sed\n")

      assert [nil, agent("s1"), nil, :external, nil] == actors(buf)
    end

    test "attested first (held): the group lands already marked" do
      buf = start_supervised!({Buffer, text: "a\nb\n"})
      :held = attest(buf, "a\nb\n", "A\nb\n")
      {:reconciled, snap} = Reconcile.reconcile(buf, "A\nb\n")
      assert [{agent_actor, _group}, nil, nil] = snap.blame
      assert agent_actor == agent("s1")
    end

    test "two sessions' hunks keep their own labels" do
      buf = start_supervised!({Buffer, text: "a\nb\nc\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "A\nb\nc\n")
      :attested = attest(buf, "a\nb\nc\n", "A\nb\nc\n", "one")
      {:reconciled, _} = Reconcile.reconcile(buf, "A\nb\nC\n")
      :attested = attest(buf, "A\nb\nc\n", "A\nb\nC\n", "two")

      assert [agent("one"), nil, agent("two"), nil] == actors(buf)
    end

    test "typing on an agent's line makes it yours; Enter at its end doesn't" do
      buf = start_supervised!({Buffer, text: "a\nb\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "A\nB\n")
      :attested = attest(buf, "a\nb\n", "A\nB\n")

      type(buf, 0, 1, "\n")
      assert [agent("s1"), :human, agent("s1"), nil] == actors(buf)

      type(buf, 2, 0, "x")
      assert [agent("s1"), :human, :human, nil] == actors(buf)
    end

    test "undo clears an agent hunk's mark; redo restores it" do
      buf = start_supervised!({Buffer, text: "a\nb\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "a\nB\n")
      :attested = attest(buf, "a\nb\n", "a\nB\n")

      {:ok, _, _} = Buffer.undo(buf)
      assert [nil, nil, nil] == actors(buf)
      {:ok, _, _} = Buffer.redo(buf)
      assert [nil, agent("s1"), nil] == actors(buf)
    end

    test "an attested group's later lines keep its mark as your edits shift them" do
      buf = start_supervised!({Buffer, text: "a\nb\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "a\nB\n")
      :attested = attest(buf, "a\nb\n", "a\nB\n")
      type(buf, 0, 0, "top\n")
      assert [:human, nil, agent("s1"), nil] == actors(buf)
    end
  end
end
