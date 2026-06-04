# §15c-ii %Command{}-sequence cassette (geex-native, the spine).
#
# A PAIR (ADR-0014 / §15c): the recorded command sequence AND an independently
# authored `golden` final buffer state. The test reconstructs the commands through
# the real `parse/1` + provenance path, replays them through `Geex.Dispatch.replay/2`,
# and diffs the result against `golden` — NOT against a state the same replay
# regenerated. So a runner-logic regression cannot pass silently.
#
# `at` is fixed (frozen) so the recorded values are bit-stable; replay re-runs the
# values, it does not re-stamp them. This is the free, no-LLM, no-key regression test.
#
# Pure data only (no aliases) — loaded via Code.eval_file/1.
%{
  initial: "",
  commands: [
    %{
      name: :insert,
      args: %{"line" => 0, "col" => 0, "text" => "hello"},
      meta: %{actor: :human, at: "2026-05-28T00:00:00Z"}
    },
    %{
      name: :insert,
      args: %{"line" => 0, "col" => 5, "text" => " world"},
      meta: %{actor: {:llm, "claude-opus-4-8"}, at: "2026-05-28T00:00:01Z"}
    },
    %{
      name: :delete,
      args: %{"line" => 0, "col" => 0, "count" => 6},
      meta: %{actor: :human, at: "2026-05-28T00:00:02Z"}
    }
  ],
  # Independently authored golden: "hello world" minus the leading "hello " == "world".
  golden: %{lines: ["world"]}
}
