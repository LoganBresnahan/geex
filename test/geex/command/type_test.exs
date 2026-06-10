defmodule Geex.Command.TypeTest do
  use ExUnit.Case, async: true
  doctest Geex.Command.Type

  alias Geex.Command.Type

  test "string casts scalars" do
    assert Type.cast(:string, "hi") == {:ok, "hi"}
    assert Type.cast(:string, 42) == {:ok, "42"}
  end

  test "integer casts ints and numeric strings, rejects junk" do
    assert Type.cast(:integer, 7) == {:ok, 7}
    assert Type.cast(:integer, "7") == {:ok, 7}
    assert {:error, _} = Type.cast(:integer, "7x")
    assert {:error, _} = Type.cast(:integer, "nope")
  end

  test "boolean casts bools and the two strings" do
    assert Type.cast(:boolean, true) == {:ok, true}
    assert Type.cast(:boolean, "false") == {:ok, false}
    assert {:error, _} = Type.cast(:boolean, "yes")
  end

  test "unknown type is an error, not a crash" do
    assert {:error, _} = Type.cast(:coord_range, "a1-g3")
  end

  describe ":edits (the search/replace array)" do
    test "normalizes string-keyed blocks, defaulting description" do
      assert Type.cast(:edits, [%{"search" => "a", "replace" => "b"}]) ==
               {:ok, [%{search: "a", replace: "b", description: ""}]}
    end

    test "accepts atom-keyed blocks and a description" do
      assert Type.cast(:edits, [%{search: "a", replace: "b", description: "why"}]) ==
               {:ok, [%{search: "a", replace: "b", description: "why"}]}
    end

    test "preserves order across multiple blocks" do
      assert {:ok, [%{search: "1"}, %{search: "2"}]} =
               Type.cast(:edits, [
                 %{"search" => "1", "replace" => "x"},
                 %{"search" => "2", "replace" => "y"}
               ])
    end

    test "rejects a non-list, a non-object block, and a missing field" do
      assert {:error, _} = Type.cast(:edits, "nope")
      assert {:error, _} = Type.cast(:edits, ["not an object"])
      assert {:error, _} = Type.cast(:edits, [%{"search" => "a"}])
      assert {:error, _} = Type.cast(:edits, [%{"search" => "a", "replace" => 5}])
    end
  end

  describe ":coord / :coord_range — the grid coordinate types (ADR-0027 agent half)" do
    alias Geex.Coord

    test ":coord parses a single coordinate via the shared Geex.Coord grammar" do
      assert Type.cast(:coord, "x5 y7") == {:ok, %Coord{x: 5, y: 7}}
    end

    test ":coord rejects a range with a shape error (not a generic parse error)" do
      assert {:error, msg} = Type.cast(:coord, "x5 y7 - x9 y7")
      assert msg =~ "single coordinate"
    end

    test ":coord_range parses a range" do
      assert {:ok, %Coord.Range{from: %Coord{x: 5, y: 7}, to: %Coord{x: 9, y: 7}}} =
               Type.cast(:coord_range, "x5 y7 - x9 y7")
    end

    test ":coord_range rejects a single point with a shape error" do
      assert {:error, msg} = Type.cast(:coord_range, "x5 y7")
      assert msg =~ "range"
    end

    test "a reversed / empty range gives a specific message" do
      assert {:error, msg} = Type.cast(:coord_range, "x9 y7 - x5 y7")
      assert msg =~ "before its start"
      assert {:error, e} = Type.cast(:coord_range, "x5 y7 - x5 y7")
      assert e =~ "same point"
    end

    test "garbage is a coordinate-shaped error" do
      assert {:error, msg} = Type.cast(:coord, "nope")
      assert msg =~ ~s("x5 y7")
    end

    test "a non-binary value falls through to the generic cast error" do
      assert {:error, _} = Type.cast(:coord, 42)
    end
  end
end
