defmodule Geex.Edit.GitMergeTest do
  # `git merge-file` as geex calls it (ADR-0034 §2): outside any repository, labelled sides,
  # the exit code as the conflict count. Not async: the temp-file check below must not see
  # another test's merge in flight.
  use ExUnit.Case, async: false
  doctest Geex.Edit.GitMerge

  alias Geex.Edit.GitMerge

  test "a clean merge has both sides' changes" do
    assert GitMerge.merge("1\n2\n3\n4\n5\n", "ONE\n2\n3\n4\n5\n", "1\n2\n3\n4\nFIVE\n") ==
             {:ok, "ONE\n2\n3\n4\nFIVE\n", 0}
  end

  test "an overlap is git's labelled block, counted" do
    assert {:ok, merged, 1} = GitMerge.merge("a\nb\n", "a\nmine\n", "a\ndisk\n")
    assert merged == "a\n<<<<<<< buffer\nmine\n=======\ndisk\n>>>>>>> disk\n"
    assert GitMerge.unresolved(merged) == 1
  end

  test "a missing final newline survives a clean merge" do
    assert GitMerge.merge("a\nb\nc\nd", "A\nb\nc\nd", "a\nb\nc\nD") == {:ok, "A\nb\nc\nD", 0}
  end

  test "a CRLF file's blocks end in CRLF, and are still found" do
    assert {:ok, merged, 1} = GitMerge.merge("a\r\nb\r\n", "a\r\nY\r\n", "a\r\nX\r\n")
    assert merged =~ "<<<<<<< buffer\r\n"
    assert GitMerge.unresolved(merged) == 1
  end

  test "a binary file is an error, for the caller's fallback" do
    assert {:error, {:git_merge_file, _status}} = GitMerge.merge("x\0y", "x\0z", "x\0w")
  end

  test "leaves no temp files behind" do
    before = File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "geex-merge-"))
    {:ok, _, _} = GitMerge.merge("a\n", "b\n", "c\n")
    later = File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "geex-merge-"))
    assert later -- before == []
  end
end
