defmodule Geex.Revert do
  @moduledoc """
  Per-agent revert (ADR-0033 §7): take back one agent's change, or one outside change, from the
  middle of the history without touching anything written after it.

  Undo stays linear (ADR-0031); this is a **revert**, like `git revert`. `plan/3` works out the
  edit that returns the change's lines to what they were, against the current text, as plain
  `replace` commands stamped `:human` with `meta.reverts`. The buffer records them as a new
  group, so the history only grows and replay stays deterministic.

  The change is the reconcile group that last wrote the line under the cursor (its blame
  entry). Scope `:hunk` takes back the one hunk of it under the cursor; `:call` takes back the
  whole group, i.e. the whole tool call.

  How: replay to just before and just after the group (`before`, `after`), then three-way merge
  with base `after`, ours the current text, and theirs `after` with the chosen hunks undone
  (`Geex.Edit.Merge.plan/3`). If any later change (yours, or another agent's) overlaps a hunk
  being taken back, the revert is **refused** and the overlapping lines are named: a partial
  revert would leave text nobody wrote. Pure.
  """

  alias Geex.{Command, Dispatch, EditorState, History}
  alias Geex.Command.Meta
  alias Geex.Commands.Replace
  alias Geex.Edit.{LineDiff, Merge}

  @type scope :: :hunk | :call
  @type info :: %{actor: Meta.actor(), group: pos_integer(), hunks: pos_integer()}
  @type reason ::
          :not_a_change
          | :not_found
          | :already_reverted
          | {:overlap, Meta.actor(), [{pos_integer(), pos_integer()}]}

  @doc """
  The commands that take back the change that wrote `line` (0-based) of `history`'s text.
  `{:error, :not_a_change}` when no reconcile group last wrote that line (your own edits, or
  text as loaded); `{:error, {:overlap, actor, ranges}}` with the 1-based line ranges, in the
  current text, of the later changes in the way; `{:error, :already_reverted}` when the text
  already reads as it did before.
  """
  @spec plan(History.t(), non_neg_integer(), scope()) ::
          {:ok, [struct()], info()} | {:error, reason()}
  def plan(%History{} = h, line, scope) when scope in [:hunk, :call] do
    with {:ok, actor, group} <- writer(h.blame, line),
         {:ok, before, after_text} <- around(h, group),
         now = History.text(h),
         undo = LineDiff.hunks(after_text, before),
         {:ok, chosen} <- choose(undo, LineDiff.hunks(after_text, now), line, scope) do
      theirs = after_text |> String.split("\n") |> Merge.apply_hunks(chosen) |> Enum.join("\n")

      case Merge.plan(after_text, now, theirs) do
        %{conflicts: [_ | _] = conflicts, ours: ours} ->
          {:error, {:overlap, actor, Enum.map(conflicts, &now_range(&1, ours))}}

        %{merged: ^now} ->
          {:error, :already_reverted}

        %{merged: merged} ->
          meta = Meta.human(reverts: %{group: group, scope: scope})
          {:ok, replaces(now, merged, meta), %{actor: actor, group: group, hunks: length(chosen)}}
      end
    end
  end

  defp writer(blame, line) do
    case Enum.at(blame, line) do
      {actor, group} when is_integer(group) -> {:ok, actor, group}
      _ -> {:error, :not_a_change}
    end
  end

  # The text just before and just after the group's commands, replayed from the base.
  defp around(h, group) do
    {earlier, rest} =
      h |> History.commands_oldest_first() |> Enum.split_while(&(not in_group?(&1, group)))

    commands = Enum.take_while(rest, &in_group?(&1, group))

    with {:ok, before} <- Dispatch.replay(h.base, earlier),
         {:ok, after_state} <- Dispatch.replay(before, commands) do
      {:ok, EditorState.text(before), EditorState.text(after_state)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp in_group?(command, group), do: match?(%{reconcile: %{group: ^group}}, command.meta)

  # `undo` and `ours` are hunks in `after` coordinates: undoing the change, and everything
  # since. For one hunk, map the cursor's line back to `after` through the later changes.
  defp choose([], _ours, _line, _scope), do: {:error, :already_reverted}
  defp choose(undo, _ours, _line, :call), do: {:ok, undo}

  defp choose(undo, ours, line, :hunk) do
    with {:ok, at} <- to_after(ours, line) do
      case Enum.find(undo, fn h -> h.removed > 0 and at >= h.line and at < h.line + h.removed end) do
        nil -> {:error, :not_found}
        hunk -> {:ok, [hunk]}
      end
    end
  end

  # A current line's position in `after`, or :not_found when a later change rewrote it.
  defp to_after(ours, line) do
    Enum.reduce_while(ours, {:ok, 0}, fn h, {:ok, offset} ->
      start = h.line + offset

      cond do
        line < start -> {:halt, {:ok, offset}}
        line < start + length(h.added) -> {:halt, :rewritten}
        true -> {:cont, {:ok, offset + length(h.added) - h.removed}}
      end
    end)
    |> case do
      {:ok, offset} -> {:ok, line - offset}
      :rewritten -> {:error, :not_found}
    end
  end

  # Where a later change (an `ours` hunk, `after` coordinates) sits in the current text, as a
  # 1-based line range. A pure deletion names the line it left behind.
  defp now_range(hunk, ours) do
    offset =
      ours
      |> Enum.take_while(&(&1 != hunk))
      |> Enum.reduce(0, fn h, acc -> acc + length(h.added) - h.removed end)

    first = hunk.line + offset + 1
    {first, max(first + length(hunk.added) - 1, first)}
  end

  defp replaces(now, merged, meta) do
    spans =
      case LineDiff.spans(now, merged) do
        {:ok, spans} -> spans
        :error -> [whole_text(now, merged)]
      end

    Enum.map(spans, fn {{{sl, sc}, {el, ec}}, text} ->
      {:ok, cmd} =
        Replace.parse(%{start_line: sl, start_col: sc, end_line: el, end_col: ec, text: text})

      Command.put_meta(cmd, meta)
    end)
  end

  defp whole_text(now, merged) do
    lines = String.split(now, "\n")
    {{{0, 0}, {length(lines) - 1, lines |> List.last() |> String.length()}}, merged}
  end
end
