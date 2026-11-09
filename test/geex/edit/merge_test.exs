defmodule Geex.Edit.MergeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  doctest Geex.Edit.Merge

  alias Geex.Edit.Merge
  alias Geex.Gen

  @base "1\n2\n3\n4\n5\n"

  test "disjoint changes: both kept, no conflict" do
    assert Merge.merge(@base, "1\nMINE\n3\n4\n5\n", "1\n2\n3\n4\nDISK\n") ==
             {"1\nMINE\n3\n4\nDISK\n", 0}
  end

  test "changes to adjacent lines don't conflict" do
    assert Merge.merge(@base, "1\nMINE\n3\n4\n5\n", "1\n2\nDISK\n4\n5\n") ==
             {"1\nMINE\nDISK\n4\n5\n", 0}
  end

  test "an overlapping hunk takes the disk version; the rest of yours is kept" do
    ours = "1\nMINE\n3\n4\nmine too\n"
    theirs = "1\nDISK\n3\n4\n5\n"
    assert Merge.merge(@base, ours, theirs) == {"1\nDISK\n3\n4\nmine too\n", 1}
  end

  test "the identical change on both sides is not a conflict" do
    assert Merge.merge(@base, "1\nX\n3\n4\n5\n", "1\nX\n3\n4\n5\n") == {"1\nX\n3\n4\n5\n", 0}
  end

  test "disk deleting a line you edited: the delete wins, counted" do
    assert Merge.merge("a\nb\nc", "a\nb!\nc", "a\nc") == {"a\nc", 1}
  end

  test "both inserting at the same point conflicts; disk's insert wins" do
    assert Merge.merge("a\nc", "a\nmine\nc", "a\ndisk\nc") == {"a\ndisk\nc", 1}
  end

  test "inserts at different points both land" do
    assert Merge.merge("1\n2\n3", "1\n2\n3\nmine", "0\n1\n2\n3") == {"0\n1\n2\n3\nmine", 0}
  end

  # ADR-0044: the merge's identities, for any two texts.
  property "identities: no disk change keeps yours; no unsaved edits takes disk" do
    check all(base <- Gen.text(), other <- Gen.text()) do
      assert Merge.merge(base, other, base) == {other, 0}
      assert Merge.merge(base, base, other) == {other, 0}
    end
  end
end
