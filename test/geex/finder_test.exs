defmodule Geex.FinderTest do
  use ExUnit.Case, async: true
  doctest Geex.Finder

  alias Geex.Finder

  # The same ranking, done the slow obvious way: every path scored, sorted once.
  defp reference(paths, query, limit) do
    paths
    |> Enum.map(&{&1, Finder.score(&1, query)})
    |> Enum.reject(fn {_path, score} -> is_nil(score) end)
    |> Enum.sort_by(fn {path, score} -> {-score, byte_size(path), path} end)
    |> Enum.take(limit)
    |> Enum.map(fn {path, _score} -> path end)
  end

  defp paths(n) do
    for i <- 1..n,
        do:
          "dir#{rem(i, 37)}/sub#{rem(i, 11)}/file_#{i}#{Enum.at(~w(.ex .exs .md .txt), rem(i, 4))}"
  end

  test "across many byte ranges, the best matches are the reference ranking's" do
    all = paths(30_000)
    packed = Finder.pack(all)
    assert byte_size(packed) > 10 * 64_000

    for query <- ["file_1", "d3s5", "md", "x9", "zzz"] do
      assert Finder.match(packed, query, 100) == reference(all, query, 100), query
    end
  end

  test "a blank query keeps the files' order; `first/2` stops at the end" do
    packed = Finder.pack(["b", "a", "c"])
    assert Finder.match(packed, "  ", 2) == ["b", "a"]
    assert Finder.first(packed, 10) == ["b", "a", "c"]
    assert Finder.first("", 10) == []
    assert Finder.match("", "a", 10) == []
  end

  test "a match in the file name beats one across directories; ties go to the shorter path" do
    packed = Finder.pack(["loop/x.ex", "lib/geex/loop.ex", "a/loop.ex", "l/o/o/p.ex"])

    assert Finder.match(packed, "loop", 4) ==
             ["a/loop.ex", "lib/geex/loop.ex", "loop/x.ex", "l/o/o/p.ex"]
  end
end
