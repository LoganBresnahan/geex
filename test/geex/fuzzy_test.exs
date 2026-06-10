defmodule Geex.FuzzyTest do
  use ExUnit.Case, async: true

  alias Geex.Fuzzy

  describe "match?/2" do
    test "a subsequence matches; a non-subsequence does not" do
      assert Fuzzy.match?("select all", "sa")
      assert Fuzzy.match?("copy", "cp")
      refute Fuzzy.match?("copy", "cz")
      refute Fuzzy.match?("copy", "copye")
    end

    test "case-insensitive" do
      assert Fuzzy.match?("Copy", "CO")
      assert Fuzzy.match?("COPY", "py")
    end

    test "the empty query matches anything" do
      assert Fuzzy.match?("anything", "")
      assert Fuzzy.match?("", "")
    end

    test "a non-empty query never matches the empty candidate" do
      refute Fuzzy.match?("", "x")
    end
  end

  describe "score/2 ranking" do
    test "no match is nil; the empty query is 0" do
      assert Fuzzy.score("copy", "z") == nil
      assert Fuzzy.score("copy", "") == 0
    end

    test "a contiguous prefix outranks a scattered subsequence" do
      contiguous = Fuzzy.score("copy", "cop")
      scattered = Fuzzy.score("c-o-p-y", "cop")
      assert contiguous > scattered
    end

    test "a match at a word boundary outscores the same letter mid-word" do
      # 'b' lands after a space (a boundary) vs immediately after 'a' (mid-word)
      assert Fuzzy.score("a b", "b") > Fuzzy.score("ab", "b")
    end

    test "a contiguous prefix outranks a same-letter acronym across words" do
      # typing "sa" should float "save" (prefix) above "select all" (word-start acronym),
      # i.e. contiguity dominates the boundary bonus
      assert Fuzzy.score("save", "sa") > Fuzzy.score("select all", "sa")
    end

    test "a longer contiguous run scores higher than a shorter one" do
      assert Fuzzy.score("undo", "und") > Fuzzy.score("undo", "un")
    end
  end
end
