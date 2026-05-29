defmodule Geex.DispatchTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer.Doc
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Dispatch

  describe "run/3" do
    test "applies the command and returns the new doc + stamped command" do
      {:ok, cmd} = Insert.parse(%{"line" => "0", "col" => "5", "text" => " world"})
      assert {:ok, doc, stamped} = Dispatch.run(cmd, Doc.new("hello"), Meta.human())
      assert Doc.text(doc) == "hello world"
      assert stamped.meta.actor == :human
    end

    test "stamps LLM provenance (the LLM is just another typist)" do
      {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "x"})
      meta = Meta.llm("claude-opus-4-8")
      assert {:ok, _doc, stamped} = Dispatch.run(cmd, Doc.new(""), meta)
      assert stamped.meta.actor == {:llm, "claude-opus-4-8"}
    end

    test "propagates a command error without raising" do
      {:ok, cmd} = Insert.parse(%{line: 9, col: 0, text: "x"})
      assert {:error, :row_out_of_range} = Dispatch.run(cmd, Doc.new("x"), Meta.human())
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

    test "replays a command list to the expected document", %{commands: commands} do
      assert {:ok, doc} = Dispatch.replay(Doc.new(""), commands)
      assert Doc.text(doc) == "hello world"
    end

    test "is deterministic — replaying twice yields the identical doc", %{commands: commands} do
      assert {:ok, a} = Dispatch.replay(Doc.new(""), commands)
      assert {:ok, b} = Dispatch.replay(Doc.new(""), commands)
      assert a == b
    end

    test "halts on the first failing command, reporting which one" do
      {:ok, bad} = Insert.parse(%{line: 9, col: 0, text: "x"})
      bad = Command.put_meta(bad, Meta.human())
      assert {:error, {:row_out_of_range, ^bad}} = Dispatch.replay(Doc.new(""), [bad])
    end
  end
end
