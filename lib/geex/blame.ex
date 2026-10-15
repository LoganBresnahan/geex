defmodule Geex.Blame do
  @moduledoc """
  Who last wrote each line, derived from the buffer's one undo history: `git blame` over
  geex's history (ADR-0032 step e, display only).

  A blame is a list with one entry per document line: `nil` for a line as loaded, or a
  `{actor, group}` writer, the `meta.actor` of the last command that changed the line and
  its reconcile group id (`nil` for anything but a reconcile), so a late attestation can
  relabel the group's lines in place (`relabel/3`).

  A command's lines are the ones between the longest common prefix and the longest common
  suffix of the document's lines before and after it. So an agent's hunk marks exactly the
  lines it rewrote, pressing Enter at the end of a line marks only the new line, and typing
  on an agent's line makes that line yours, as in `git blame`. An undone command's lines lose
  its mark because the blame is rebuilt from the remaining history (`replay/2`).

  Pure: `value -> value`, like the dispatch core.
  """

  alias Geex.{Dispatch, EditorState}
  alias Geex.Command.Meta

  @type writer :: {Meta.actor(), pos_integer() | nil}
  @type t :: [writer() | nil]

  @doc """
  The blame of a freshly loaded document: every line unwritten.

      iex> Geex.Blame.new(["a", "b"])
      [nil, nil]
  """
  @spec new([String.t()]) :: t()
  def new(lines) when is_list(lines), do: List.duplicate(nil, length(lines))

  @doc "The writer a recorded command stamps on the lines it changes."
  @spec writer(struct()) :: writer()
  def writer(%{meta: %Meta{actor: actor} = meta}), do: {actor, group(meta)}

  @doc """
  Advance `blame` across one command that turned `before` lines into `after` lines: the
  changed lines take `writer`; the common prefix and suffix keep theirs.

      iex> Geex.Blame.step([nil, nil, nil], ["a", "b", "c"], ["a", "B", "c"], {:human, nil})
      [nil, {:human, nil}, nil]

      iex> Geex.Blame.step([nil, nil], ["a", "b"], ["a", "", "b"], {:human, nil})
      [nil, {:human, nil}, nil]
  """
  @spec step(t(), [String.t()], [String.t()], writer()) :: t()
  def step(blame, before, after_lines, writer) do
    {prefix, old_rest, new_rest} = split_common_prefix(before, after_lines, 0)
    suffix = common_suffix_length(old_rest, new_rest)
    changed = length(new_rest) - suffix
    {head, rest} = Enum.split(blame, prefix)
    head ++ List.duplicate(writer, changed) ++ Enum.take(rest, -suffix)
  end

  @doc """
  Replay `commands` (oldest first) over `base`, the way `Geex.Dispatch.replay/2` does, and
  build the blame alongside. Returns the resulting editor state and its blame.
  """
  @spec replay(EditorState.t(), [struct()]) ::
          {:ok, EditorState.t(), t()} | {:error, {term(), struct()}}
  def replay(%EditorState{} = base, commands) when is_list(commands) do
    Enum.reduce_while(commands, {:ok, base, new(EditorState.lines(base))}, fn command,
                                                                              {:ok, editor, blame} ->
      case Dispatch.apply_command(command, editor) do
        {:ok, next} ->
          blame = step(blame, EditorState.lines(editor), EditorState.lines(next), writer(command))
          {:cont, {:ok, next, blame}}

        {:error, reason} ->
          {:halt, {:error, {reason, command}}}
      end
    end)
  end

  @doc """
  A late attestation: the lines last written by reconcile `group` now carry `actor`.

      iex> Geex.Blame.relabel([{:external, 7}, nil, {:external, 8}], 7, {:agent, %{}})
      [{{:agent, %{}}, 7}, nil, {:external, 8}]
  """
  @spec relabel(t(), pos_integer(), Meta.actor()) :: t()
  def relabel(blame, group, actor) do
    Enum.map(blame, fn
      {_old, ^group} -> {actor, group}
      entry -> entry
    end)
  end

  defp group(%Meta{reconcile: %{group: group}}), do: group
  defp group(_meta), do: nil

  defp split_common_prefix([line | before], [line | after_lines], n),
    do: split_common_prefix(before, after_lines, n + 1)

  defp split_common_prefix(before, after_lines, n), do: {n, before, after_lines}

  defp common_suffix_length(before, after_lines),
    do: count_equal(Enum.reverse(before), Enum.reverse(after_lines), 0)

  defp count_equal([line | before], [line | after_lines], n),
    do: count_equal(before, after_lines, n + 1)

  defp count_equal(_before, _after_lines, n), do: n
end
