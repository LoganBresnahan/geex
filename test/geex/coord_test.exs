defmodule Geex.CoordTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.{Coord, Gen}
  alias Geex.Coord.Range
  alias Geex.Buffer.Doc
  alias Geex.Loop.Verbs

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

    test "both endpoints overshooting a short line clamp to a collapsed span (the caller must guard)" do
      # `x5 y1 - x9 y1` parses (5 < 9), but on "ab" both x clamp to the line end (2), so the span
      # collapses to a point — the loop's grid_clip treats this as a no-op, not a phantom selection.
      r = %Range{from: %Coord{x: 5, y: 1}, to: %Coord{x: 9, y: 1}}
      assert {:ok, {{0, 2}, {0, 2}}} = Coord.to_span(r, doc("ab"))
    end
  end

  # ADR-0044 §8.3, ADR-0027 §7: a range resolves inside the document, and covers exactly the
  # graphemes between its ends, inclusive. In coordinates, a line's newline sits at x = length + 1;
  # a start past the line's end starts at its newline, an end past it stops at its last grapheme.
  property "to_span/2 stays inside the document and covers the range, inclusive" do
    check all(
            text <- Gen.text(),
            lines = String.split(text, "\n"),
            widest = lines |> Enum.map(&String.length/1) |> Enum.max(),
            a <- coord(length(lines) + 1, widest + 2),
            b <- coord(length(lines) + 1, widest + 2),
            a != b
          ) do
      [from, to] = Enum.sort_by([a, b], &{&1.y, &1.x})
      doc = Doc.new(text)

      case Coord.to_span(%Range{from: from, to: to}, doc) do
        {:error, :line_out_of_range} ->
          assert to.y > length(lines)

        {:ok, {{r1, c1} = start, {r2, c2} = stop} = span} ->
          assert to.y <= length(lines)
          assert start <= stop
          assert c1 <= String.length(Enum.at(lines, r1))
          assert c2 <= String.length(Enum.at(lines, r2))

          len = fn y -> String.length(Enum.at(lines, y - 1)) end
          first = {from.y, min(from.x, len.(from.y) + 1)}
          last = {to.y, min(to.x, len.(to.y))}

          expected =
            for {line, y} <- Enum.with_index(lines, 1),
                {g, x} <- Enum.with_index(String.graphemes(line) ++ ["\n"], 1),
                {y, x} >= first and {y, x} <= last,
                into: "",
                do: g

          assert Doc.slice(doc, span) == {:ok, expected}
      end
    end
  end

  # ADR-0044 §8.3: a human's grid line (`Verbs.parse_grid/1`, display columns) and an agent's grid
  # argument (the `goto`/`copy` tools' field-specs, graphemes) speak one grammar, so the same
  # text parses to the same coordinates on both surfaces, in any case and spacing, and both
  # refuse the same lines (a zero, an empty or reversed range).
  property "a human's grid line and an agent's grid argument parse to the same coordinates" do
    {:ok, %{fields: goto}} = Geex.MCP.Grid.lookup("goto")
    {:ok, %{fields: copy}} = Geex.MCP.Grid.lookup("copy")

    check all(
            a <- coord(30, 30, 0),
            b <- coord(30, 30, 0),
            style_a <- style(),
            style_b <- style(),
            dash <- member_of(["-", " - ", "  -\t"]),
            verb <- member_of(["copy", "COPY", "Copy"])
          ) do
      point = render(a, style_a)
      range = render(a, style_a) <> dash <> render(b, style_b)
      valid? = fn c -> c.x >= 1 and c.y >= 1 end

      if valid?.(a) do
        assert Verbs.parse_grid("goto " <> point) == {:goto, a}
        assert Verbs.parse_grid(point) == {:goto, a}
        assert Geex.Command.cast_args(goto, %{"pos" => point}) == {:ok, %{pos: a}}
      else
        assert Verbs.parse_grid("goto " <> point) == :unknown
        assert {:error, _} = Geex.Command.cast_args(goto, %{"pos" => point})
      end

      if valid?.(a) and valid?.(b) and {a.y, a.x} < {b.y, b.x} do
        expected = %Range{from: a, to: b}
        assert Verbs.parse_grid(verb <> " " <> range) == {:copy, expected}
        assert Geex.Command.cast_args(copy, %{"range" => range}) == {:ok, %{range: expected}}
      else
        assert Verbs.parse_grid(verb <> " " <> range) == :unknown
        assert {:error, _} = Geex.Command.cast_args(copy, %{"range" => range})
      end
    end
  end

  # A coordinate with y in min..max_y and x in min..max_x (a `min` of 0 makes invalid ones).
  defp coord(max_y, max_x, min \\ 1) do
    gen all(y <- integer(min..max_y), x <- integer(min..max_x)) do
      %Coord{x: x, y: y}
    end
  end

  defp style do
    tuple(
      {member_of(["x", "X"]), member_of(["y", "Y"]), member_of([" ", "  ", "\t"]),
       member_of(["", " "]), member_of(["", " "])}
    )
  end

  defp render(%Coord{x: x, y: y}, {xs, ys, gap, before, after_}),
    do: "#{before}#{xs}#{x}#{gap}#{ys}#{y}#{after_}"
end
