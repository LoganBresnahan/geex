defmodule Geex.CoordTest do
  use ExUnit.Case, async: true

  alias Geex.Coord
  alias Geex.Coord.Range
  alias Geex.Buffer.Doc

  defp doc(text), do: Doc.new(text)

  describe "parse/1 — a single coordinate" do
    test "x then y, 1-based" do
      assert Coord.parse("x5 y7") == {:ok, %Coord{x: 5, y: 7}}
    end

    test "case-insensitive and whitespace-tolerant" do
      assert Coord.parse("  X5   Y7 ") == {:ok, %Coord{x: 5, y: 7}}
    end

    test "0 or a sign is rejected (coordinates are 1-based)" do
      assert Coord.parse("x0 y1") == {:error, :bad_coord}
      assert Coord.parse("x1 y0") == {:error, :bad_coord}
      assert Coord.parse("x-1 y2") == {:error, :bad_coord}
    end

    test "missing axis / wrong order / junk is a bad coord" do
      assert Coord.parse("x5") == {:error, :bad_coord}
      assert Coord.parse("y7 x5") == {:error, :bad_coord}
      assert Coord.parse("5 7") == {:error, :bad_coord}
      assert Coord.parse("x5 y7 z9") == {:error, :bad_coord}
    end
  end

  describe "parse/1 — a linear range" do
    test "from - to, both inclusive" do
      assert Coord.parse("x5 y7 - x12 y9") ==
               {:ok, %Range{from: %Coord{x: 5, y: 7}, to: %Coord{x: 12, y: 9}, kind: :linear}}
    end

    test "tolerates spacing around the dash" do
      assert {:ok, %Range{}} = Coord.parse("x1 y1-x2 y1")
    end

    test "a reversed range errors" do
      assert Coord.parse("x12 y9 - x5 y7") == {:error, :reversed}
      assert Coord.parse("x9 y1 - x2 y1") == {:error, :reversed}
    end

    test "an empty range (from == to) errors" do
      assert Coord.parse("x5 y7 - x5 y7") == {:error, :empty_range}
    end

    test "a bad endpoint propagates the error" do
      assert Coord.parse("x5 y7 - junk") == {:error, :bad_coord}
    end
  end

  describe "to_caret/2 — a coordinate to a grapheme caret (goto)" do
    test "1-based coord to 0-based caret" do
      assert Coord.to_caret(%Coord{x: 3, y: 2}, doc("aaa\nbbb\nccc")) == {:ok, {1, 2}}
    end

    test "x past the line end clamps to the line end" do
      assert Coord.to_caret(%Coord{x: 99, y: 1}, doc("abc\nd")) == {:ok, {0, 3}}
    end

    test "y past EOF is a hard error" do
      assert Coord.to_caret(%Coord{x: 1, y: 9}, doc("a\nb")) == {:error, :line_out_of_range}
    end
  end

  describe "to_span/2 — a range to a half-open grapheme span" do
    test "inclusive end becomes the half-open caret after it" do
      # "abcdef": x2 y1 - x4 y1 includes graphemes 2,3,4 (b,c,d) -> caret span {0,1}-{0,4}
      r = %Range{from: %Coord{x: 2, y: 1}, to: %Coord{x: 4, y: 1}}
      assert {:ok, {{0, 1}, {0, 4}}} = Coord.to_span(r, doc("abcdef"))
    end

    test "the resolved span slices the intended text" do
      d = doc("abcdef")
      {:ok, span} = Coord.to_span(%Range{from: %Coord{x: 2, y: 1}, to: %Coord{x: 4, y: 1}}, d)
      assert Doc.slice(d, span) == {:ok, "bcd"}
    end

    test "x past the line end clamps to the line end (to-end-of-line)" do
      d = doc("abcdef")
      {:ok, span} = Coord.to_span(%Range{from: %Coord{x: 2, y: 1}, to: %Coord{x: 99, y: 1}}, d)
      assert span == {{0, 1}, {0, 6}}
      assert Doc.slice(d, span) == {:ok, "bcdef"}
    end

    test "a multi-line range" do
      d = doc("one\ntwo\nthree")
      {:ok, span} = Coord.to_span(%Range{from: %Coord{x: 2, y: 1}, to: %Coord{x: 3, y: 3}}, d)
      assert span == {{0, 1}, {2, 3}}
      assert Doc.slice(d, span) == {:ok, "ne\ntwo\nthr"}
    end

    test "y past EOF is a hard error" do
      r = %Range{from: %Coord{x: 1, y: 1}, to: %Coord{x: 1, y: 9}}
      assert Coord.to_span(r, doc("a\nb")) == {:error, :line_out_of_range}
    end
  end
end
