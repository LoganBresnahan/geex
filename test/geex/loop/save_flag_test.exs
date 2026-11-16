defmodule Geex.Loop.SaveFlagTest do
  # How a save off the key loop and a cancel agree (ADR-0035's 2026-11-15 amendment): a cancel
  # never lets a write begin after it, and never cuts one short.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.Loop.SaveFlag

  doctest Geex.Loop.SaveFlag

  test "a cancel before any write: no write begins, and the save stops" do
    flag = SaveFlag.new()
    assert SaveFlag.cancel(flag) == :cancelled
    assert SaveFlag.write?(flag) == :cancelled
    assert SaveFlag.done(flag) == :stop
  end

  test "a cancel during a write waits for it; a second cancel waits too" do
    flag = SaveFlag.new()
    assert SaveFlag.write?(flag) == :ok
    assert SaveFlag.cancel(flag) == :writing
    assert SaveFlag.cancel(flag) == :writing
    assert SaveFlag.done(flag) == :stop
    assert SaveFlag.write?(flag) == :cancelled
  end

  test "the same file again (it changed on disk first) is still writing, unless a cancel came" do
    flag = SaveFlag.new()
    assert SaveFlag.write?(flag) == :ok
    assert SaveFlag.write?(flag) == :ok
    assert SaveFlag.cancel(flag) == :writing
    # Nothing was written yet: the cancel stops it there.
    assert SaveFlag.write?(flag) == :cancelled
    assert SaveFlag.done(flag) == :stop
  end

  test "between files the cancel takes the idle cell" do
    flag = SaveFlag.new()
    assert SaveFlag.write?(flag) == :ok
    assert SaveFlag.done(flag) == :go
    assert SaveFlag.cancel(flag) == :cancelled
    assert SaveFlag.write?(flag) == :cancelled
  end

  test "a file refused before its write (no write? at all) goes on to the next" do
    flag = SaveFlag.new()
    assert SaveFlag.done(flag) == :go
    assert SaveFlag.write?(flag) == :ok
    assert SaveFlag.done(flag) == :go
  end

  # The save's side as it runs: for each file, its write begun once or more (a file that changed
  # on disk goes round again) or never (refused first), then answered. A cancel lands anywhere.
  defp save_steps do
    gen all(
          files <- list_of(member_of([[], [:write?], [:write?, :write?]]), max_length: 4),
          files != []
        ) do
      Enum.flat_map(files, &(&1 ++ [:done]))
    end
  end

  property "after a cancel no write begins, except that the one under way finishes" do
    check all(
            steps <- save_steps(),
            at <- integer(0..length(steps))
          ) do
      flag = SaveFlag.new()
      {before, rest} = Enum.split(steps, at)
      # The save's steps up to the cancel, stopping as it would.
      {state, stopped?} = run(before, flag, :idle)

      unless stopped? do
        case SaveFlag.cancel(flag) do
          :cancelled ->
            # No write under way: no write begins after it.
            assert state != :writing
            refute Enum.any?(run_answers(rest, flag), &(&1 == {:write?, :ok}))

          :writing ->
            # A write under way: the save stops when it is answered, and nothing begins again.
            assert state == :writing
            answers = run_answers(rest, flag)
            {_, after_done} = Enum.split_while(answers, &(elem(&1, 0) != :done))
            assert match?([{:done, :stop} | _], after_done)
            # Going round the same file again (nothing written yet) is stopped too.
            refute Enum.any?(answers, &(&1 == {:write?, :ok}))
        end
      end
    end
  end

  # The steps before the cancel; whether a file's write is under way when it comes.
  defp run([], _flag, state), do: {state, false}

  defp run([:write? | rest], flag, _state) do
    :ok = SaveFlag.write?(flag)
    run(rest, flag, :writing)
  end

  defp run([:done | rest], flag, _state) do
    :go = SaveFlag.done(flag)
    run(rest, flag, :idle)
  end

  # The steps after it, each with its answer, stopping where the save would.
  defp run_answers(steps, flag) do
    Enum.reduce_while(steps, [], fn
      :write?, acc ->
        case SaveFlag.write?(flag) do
          :ok -> {:cont, [{:write?, :ok} | acc]}
          :cancelled -> {:cont, [{:write?, :cancelled} | acc]}
        end

      :done, acc ->
        case SaveFlag.done(flag) do
          :go -> {:cont, [{:done, :go} | acc]}
          :stop -> {:halt, [{:done, :stop} | acc]}
        end
    end)
    |> Enum.reverse()
  end
end
