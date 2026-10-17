defmodule Geex.Finder do
  @moduledoc """
  The ranking behind `Alt+O`, the fuzzy file finder ([ADR-0028](../../doc/adr/0028-editor-shell-and-minibuffer.md)'s
  2026-10-17 amendment): the files under the root (the tree's own list, `Geex.Tree.list/1`)
  matched against what you type, best first.

  A path matches when the query is a subsequence of it (`Geex.Fuzzy`). A match within the file
  name always ranks above one spread across directories (as the palette ranks name matches above
  description matches), so `loop` puts `lib/geex/loop.ex` above `lib/geex/loop/keymap.ex`. Ties
  go to the shorter path, then alphabetical order, so the same files and query always rank the
  same way.

  A root can hold hundreds of thousands of files. The list is kept **packed**, one binary with a
  path per line (`pack/1`): a binary that size is shared between processes, not copied, so the
  loop can hand it to a new search on every key for free. `match/3` cuts it into byte ranges at
  line ends and scores each range in a process of its own, keeping only the best `limit` of each.
  The loop runs it in a process of its own and drops it when the query changes
  ([ADR-0035](../../doc/adr/0035-the-loop-never-waits.md)).
  """

  alias Geex.Fuzzy

  @typedoc "Paths joined by newlines (`pack/1`)."
  @type packed :: binary()

  # Added to a match within the file name, so it outranks any match across directories.
  @name_band 100_000

  # Bytes per scoring process: enough that the processes' cost is small next to the scoring.
  @range 64_000

  @doc """
  Pack `paths` for `match/3` and `first/2`.

      iex> Geex.Finder.pack(["a.ex", "lib/b.ex"])
      "a.ex\\nlib/b.ex"
  """
  @spec pack([String.t()]) :: packed()
  def pack(paths), do: Enum.join(paths, "\n")

  @doc """
  The first `n` paths, in order.

      iex> Geex.Finder.first(Geex.Finder.pack(["a", "b", "c"]), 2)
      ["a", "b"]
  """
  @spec first(packed(), non_neg_integer()) :: [String.t()]
  def first(packed, n), do: first(packed, n, [])

  defp first(<<>>, _n, acc), do: Enum.reverse(acc)
  defp first(_rest, 0, acc), do: Enum.reverse(acc)

  defp first(rest, n, acc) do
    case :binary.split(rest, "\n") do
      [path, more] -> first(more, n - 1, [path | acc])
      [path] -> Enum.reverse([path | acc])
    end
  end

  @doc """
  The best `limit` of the `packed` paths for `query`, best first. A blank query keeps their order.

      iex> ["lib/geex/loop/keymap.ex", "lib/geex/loop.ex", "README.md"]
      ...> |> Geex.Finder.pack()
      ...> |> Geex.Finder.match("loop", 10)
      ["lib/geex/loop.ex", "lib/geex/loop/keymap.ex"]
  """
  @spec match(packed(), String.t(), pos_integer()) :: [String.t()]
  def match(packed, query, limit) do
    case String.trim(query) do
      "" ->
        first(packed, limit)

      q ->
        packed
        |> ranges()
        |> Task.async_stream(
          fn {start, len} ->
            packed |> binary_part(start, len) |> :binary.split("\n", [:global]) |> best(q, limit)
          end,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, ranked} -> ranked end)
        |> top(limit)
        |> Enum.map(fn {path, _score} -> path end)
    end
  end

  @doc """
  The score of `path` for `query` (higher is better), or `nil` when it doesn't match.

      iex> Geex.Finder.score("lib/geex/loop.ex", "loop") > Geex.Finder.score("lib/geex/loop/keymap.ex", "loop")
      true
      iex> Geex.Finder.score("lib/a.ex", "zz")
      nil
  """
  @spec score(String.t(), String.t()) :: non_neg_integer() | nil
  def score(path, query) do
    case Fuzzy.score(Path.basename(path), query) do
      nil -> Fuzzy.score(path, query)
      name -> name + @name_band
    end
  end

  # `{start, length}` byte ranges of about @range bytes, each ending at a line end.
  defp ranges(packed), do: ranges(packed, 0, byte_size(packed), [])

  defp ranges(_packed, start, total, acc) when start >= total, do: Enum.reverse(acc)

  defp ranges(packed, start, total, acc) do
    stop =
      if start + @range >= total do
        total
      else
        case :binary.match(packed, "\n", scope: {start + @range, total - start - @range}) do
          {pos, 1} -> pos
          :nomatch -> total
        end
      end

    ranges(packed, stop + 1, total, [{start, stop - start} | acc])
  end

  defp best(paths, q, limit) do
    paths
    |> Enum.flat_map(fn path ->
      case score(path, q) do
        nil -> []
        score -> [{path, score}]
      end
    end)
    |> top(limit)
  end

  defp top(scored, limit) do
    scored
    |> Enum.sort_by(fn {path, score} -> {-score, byte_size(path), path} end)
    |> Enum.take(limit)
  end
end
