defmodule Geex.DispatchTest.Crashing do
  @moduledoc false
  # A command whose run/2 raises — used to prove crash containment.
  defstruct [:meta]
  def run(_command, _state), do: raise("boom")
end

defmodule Geex.DispatchTest do
  use ExUnit.Case, async: true

  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.{Delete, Insert}
  alias Geex.Dispatch
  alias Geex.EditorState

  describe "apply_command/2 — the pure inner layer" do
    test "applies a command and returns the new EditorState" do
      {:ok, cmd} = Insert.parse(%{"line" => "0", "col" => "5", "text" => " world"})
      assert {:ok, state} = Dispatch.apply_command(cmd, EditorState.new("hello"))
      assert EditorState.text(state) == "hello world"
    end

    test "does not stamp provenance — the command carries its own meta" do
      {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "x"})
      stamped = Command.put_meta(cmd, Meta.llm("claude-opus-4-8"))
      assert {:ok, _state} = Dispatch.apply_command(stamped, EditorState.new(""))
      # apply_command is pure over the value: it neither sets nor mutates meta.
      assert stamped.meta.actor == {:llm, "claude-opus-4-8"}
    end

    test "propagates a command error without raising" do
      {:ok, cmd} = Insert.parse(%{line: 9, col: 0, text: "x"})
      assert {:error, :row_out_of_range} = Dispatch.apply_command(cmd, EditorState.new("x"))
    end

    test "contains a raising command as {:command_crashed, _} instead of propagating" do
      assert {:error, {:command_crashed, info}} =
               Dispatch.apply_command(%Geex.DispatchTest.Crashing{}, EditorState.new(""))

      assert info =~ "boom"
    end
  end

  describe "replay/2 — the free, no-LLM regression backbone (§15c)" do
    setup do
      # A recorded sequence of provenance-tagged commands. `at` is fixed so the
      # recorded values are stable — replay re-runs them, it does not re-stamp.
      {:ok, c1} = Insert.parse(%{line: 0, col: 0, text: "hello"})
      {:ok, c2} = Insert.parse(%{line: 0, col: 5, text: " world"})

      commands = [
        Command.put_meta(c1, Meta.human(at: ~U[2026-05-28 00:00:00Z])),
        Command.put_meta(c2, Meta.llm("m", at: ~U[2026-05-28 00:00:01Z]))
      ]

      %{commands: commands}
    end

    test "replays a command list to the expected state", %{commands: commands} do
      assert {:ok, state} = Dispatch.replay(EditorState.new(""), commands)
      assert EditorState.text(state) == "hello world"
    end

    test "is deterministic — replaying twice yields the identical state", %{commands: commands} do
      assert {:ok, a} = Dispatch.replay(EditorState.new(""), commands)
      assert {:ok, b} = Dispatch.replay(EditorState.new(""), commands)
      assert a == b
    end

    test "halts on the first failing command, reporting which one" do
      {:ok, bad} = Delete.parse(%{line: 9, col: 0, count: 1})
      bad = Command.put_meta(bad, Meta.human())
      assert {:error, {:row_out_of_range, ^bad}} = Dispatch.replay(EditorState.new(""), [bad])
    end
  end
end
