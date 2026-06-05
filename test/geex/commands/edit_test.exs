defmodule Geex.Commands.EditTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.Edit
  alias Geex.Dispatch
  alias Geex.EditorState

  defp edits(blocks), do: Enum.map(blocks, fn {s, r} -> %{"search" => s, "replace" => r} end)

  describe "parse/1 (the :edits arg type)" do
    test "coerces a JSON-shaped edits array into normalized blocks" do
      assert {:ok, cmd} =
               Edit.parse(%{
                 "edits" => [%{"search" => "x", "replace" => "y", "description" => "d"}],
                 "description" => "top-level"
               })

      assert cmd.edits == [%{search: "x", replace: "y", description: "d"}]
      assert cmd.description == "top-level"
    end

    test "a block missing a required field is a parse error" do
      assert {:error, message} = Edit.parse(%{"edits" => [%{"search" => "x"}]})
      assert message =~ "replace"
    end

    test "edits must be a list" do
      assert {:error, _} = Edit.parse(%{"edits" => "not a list"})
    end

    test "an empty edits array is rejected (not a no-op that dirties the buffer)" do
      assert {:error, message} = Edit.parse(%{"edits" => []})
      assert message =~ "at least one"
    end
  end

  describe "run/2 (pure, sequential)" do
    test "applies a single block" do
      {:ok, cmd} = Edit.parse(%{"edits" => edits([{"a", "A"}])})
      assert {:ok, state} = Edit.run(cmd, EditorState.new("a\nb"))
      assert EditorState.text(state) == "A\nb"
    end

    test "applies blocks in order, each re-resolved against the post-edit doc" do
      # block 1 turns "a" into "X"; block 2's search ("X") only exists after block 1
      {:ok, cmd} = Edit.parse(%{"edits" => edits([{"a", "X"}, {"X", "Y"}])})
      assert {:ok, state} = Edit.run(cmd, EditorState.new("a\nb"))
      assert EditorState.text(state) == "Y\nb"
    end

    test "a block that can't resolve refuses the whole edit with guidance" do
      {:ok, cmd} = Edit.parse(%{"edits" => edits([{"a", "A"}, {"missing", "Z"}])})
      assert {:error, {:edit_failed, message}} = Edit.run(cmd, EditorState.new("a\nb"))
      assert message =~ "block 2/2"
      assert message =~ "No edits were applied"
    end

    test "a block that an earlier block makes ambiguous refuses the whole edit (re-resolved against post-edit text)" do
      # block 1 turns "a\nb" into "b\nb"; block 2's "b" is now ambiguous -> refuse, atomic
      {:ok, cmd} = Edit.parse(%{"edits" => edits([{"a", "b"}, {"b", "c"}])})
      assert {:error, {:edit_failed, message}} = Edit.run(cmd, EditorState.new("a\nb"))
      assert message =~ "more than one place"
    end

    test "the refusal message reflects the classification" do
      {:ok, ambiguous} = Edit.parse(%{"edits" => edits([{"dup", "X"}])})
      assert {:error, {:edit_failed, msg}} = Edit.run(ambiguous, EditorState.new("dup\ndup"))
      assert msg =~ "more than one place"

      {:ok, stale} = Edit.parse(%{"edits" => edits([{"alpha\nbeta", "Z"}])})
      assert {:error, {:edit_failed, msg}} = Edit.run(stale, EditorState.new("alpha\nMID\nbeta"))
      assert msg =~ "changed since you read it"
    end
  end

  describe "through the dispatcher (atomic, recorded as one command)" do
    defp stamped(cmd), do: Command.put_meta(cmd, Meta.human())

    test "a successful multi-block edit records exactly one Edit command" do
      buf = start_supervised!({Buffer, text: "one\ntwo\nthree"})
      {:ok, cmd} = Edit.parse(%{"edits" => edits([{"one", "1"}, {"three", "3"}])})

      assert {:ok, snap} = Buffer.dispatch(buf, stamped(cmd))
      assert snap.text == "1\ntwo\n3"
      assert [recorded] = snap.history
      assert recorded.__struct__ == Edit
      assert recorded.meta.actor == :human
    end

    test "a failing block leaves the buffer and history completely untouched (all-or-nothing)" do
      buf = start_supervised!({Buffer, text: "one\ntwo\nthree"})
      # block 1 would apply, block 2 fails -> the whole edit must roll back
      {:ok, cmd} = Edit.parse(%{"edits" => edits([{"one", "1"}, {"nonexistent", "Z"}])})

      assert {:error, {:edit_failed, _}} = Buffer.dispatch(buf, stamped(cmd))
      assert Buffer.get_text(buf) == "one\ntwo\nthree"
      assert Buffer.history(buf) == []
    end

    test "a recorded Edit replays deterministically (re-resolves against the same doc)" do
      # Edit records the search/replace strings, not baked coordinates, so replay re-runs
      # the matcher — it must reproduce identically given the same starting doc (§15c).
      {:ok, cmd} = Edit.parse(%{"edits" => edits([{"one", "1"}, {"1", "ONE"}])})
      stamped = stamped(cmd)
      initial = EditorState.new("one\ntwo")

      {:ok, applied} = Dispatch.apply_command(stamped, initial)
      assert EditorState.text(applied) == "ONE\ntwo"
      assert Dispatch.replay(initial, [stamped]) == {:ok, applied}
      # idempotent across repeated replays
      assert Dispatch.replay(initial, [stamped]) == Dispatch.replay(initial, [stamped])
    end
  end
end
