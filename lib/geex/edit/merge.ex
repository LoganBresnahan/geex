defmodule Geex.Edit.Merge do
  @moduledoc """
  Three-way line merge for an out-of-band write to a **dirty** buffer (ADR-0032 step b).

  `base` is the disk text geex last synced, `ours` is the buffer (base plus your unsaved
  edits), `theirs` is the new disk text (base plus the other writer's change). The rule the
  maintainer chose: **disk wins, and you're told.**

    * Every hunk of `theirs` is applied: disk is the writer's ground truth for its next step.
    * Each of your unsaved hunks is kept unless it overlaps one of theirs; an overlapping one
      is replaced by the disk version, and counted as a conflict (unless it is the identical
      change, which loses nothing).

  The caller diffs `ours` against the merged text with `Geex.Edit.LineDiff`, so the merge
  lands as ordinary hunk commands and your replaced text stays one undo away.

  Hunks are compared in `base` line coordinates (`LineDiff.hunks/2`). Two hunks overlap when
  their removed ranges intersect, when both insert at the same point, or when one inserts
  strictly inside the other's removed range. Hunks that only touch at an edge (changing
  adjacent lines) do not conflict; both are kept.
  """

  alias Geex.Edit.LineDiff

  @doc """
  Merge `theirs` into `ours` over `base`. Returns `{merged_text, conflicts}`, where
  `conflicts` is how many of your unsaved hunks were replaced by the disk version.

      iex> Geex.Edit.Merge.merge("a\\nb\\nc", "A\\nb\\nc", "a\\nb\\nC")
      {"A\\nb\\nC", 0}

      iex> Geex.Edit.Merge.merge("a\\nb\\nc", "a\\nmine\\nc", "a\\ndisk\\nc")
      {"a\\ndisk\\nc", 1}
  """
  @spec merge(String.t(), String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def merge(base, ours, theirs) when is_binary(base) and is_binary(ours) and is_binary(theirs) do
    ours_hunks = LineDiff.hunks(base, ours)
    theirs_hunks = LineDiff.hunks(base, theirs)

    {kept, replaced} =
      Enum.split_with(ours_hunks, fn o -> not Enum.any?(theirs_hunks, &overlap?(o, &1)) end)

    conflicts = Enum.count(replaced, &(&1 not in theirs_hunks))
    merged = base |> String.split("\n") |> apply_hunks(kept ++ theirs_hunks) |> Enum.join("\n")

    {merged, conflicts}
  end

  # Removed ranges are [line, line + removed); a pure insert (removed 0) sits at `line`.
  defp overlap?(%{line: a, removed: n}, %{line: b, removed: m}) do
    cond do
      n > 0 and m > 0 -> a < b + m and b < a + n
      n == 0 and m == 0 -> a == b
      n == 0 -> b < a and a < b + m
      true -> a < b and b < a + n
    end
  end

  # Apply non-overlapping hunks (all in base coordinates) bottom-up, so each splice leaves
  # the lines above it where the hunks below expect them. At one line, a replacement goes
  # before an insert, which then lands ahead of the replaced block.
  defp apply_hunks(lines, hunks) do
    hunks
    |> Enum.sort_by(&{&1.line, &1.removed}, :desc)
    |> Enum.reduce(lines, fn %{line: at, removed: n, added: added}, acc ->
      Enum.take(acc, at) ++ added ++ Enum.drop(acc, at + n)
    end)
  end
end
