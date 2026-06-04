defmodule Geex.CassetteTest do
  @moduledoc """
  The §15c-ii golden-pair replay test — the free, no-LLM regression backbone.

  Proves the replay property (ADR-0014, mcp-ai-integration.md §15c) *before any AI
  work exists*: a recorded `%Command{}` sequence replays deterministically to a
  recorded golden buffer state. This is the v0.1 exit criterion (roadmap.md).
  """
  use ExUnit.Case, async: true

  alias Geex.Buffer.Doc
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.{Delete, Insert}
  alias Geex.Dispatch
  alias Geex.EditorState

  @modules %{insert: Insert, delete: Delete}

  # Reconstruct the recorded %Command{}s through the real parse/1 + provenance path.
  defp load_cassette(name) do
    {data, _bindings} = Code.eval_file("test/fixtures/cassettes/#{name}.exs")

    commands =
      Enum.map(data.commands, fn entry ->
        {:ok, dt, _} = DateTime.from_iso8601(entry.meta.at)
        {:ok, cmd} = @modules[entry.name].parse(entry.args)
        Command.put_meta(cmd, Meta.new(entry.meta.actor, at: dt))
      end)

    golden = %EditorState{doc: %Doc{lines: data.golden.lines}}
    %{initial: data.initial, commands: commands, golden: golden}
  end

  test "a recorded command sequence replays to the independently-authored golden state" do
    %{initial: initial, commands: commands, golden: golden} = load_cassette("hello_world")

    assert {:ok, final} = Dispatch.replay(EditorState.new(initial), commands)

    # Diff against the golden the cassette recorded — NOT a state this replay made.
    assert final == golden
    assert EditorState.text(final) == "world"
  end

  test "replay is deterministic — the same cassette yields the identical state twice" do
    %{initial: initial, commands: commands} = load_cassette("hello_world")

    assert {:ok, a} = Dispatch.replay(EditorState.new(initial), commands)
    assert {:ok, b} = Dispatch.replay(EditorState.new(initial), commands)
    assert a == b
  end

  test "the recorded provenance survives reconstruction (frozen `at`, mixed actors)" do
    %{commands: commands} = load_cassette("hello_world")

    assert Enum.map(commands, & &1.meta.actor) ==
             [:human, {:llm, "claude-opus-4-8"}, :human]

    # `at` is frozen in the fixture, so replay re-runs stable values (§15c).
    assert Enum.map(commands, & &1.meta.at) == [
             ~U[2026-05-28 00:00:00Z],
             ~U[2026-05-28 00:00:01Z],
             ~U[2026-05-28 00:00:02Z]
           ]
  end
end
