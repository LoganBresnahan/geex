defmodule Geex.Edit.LineDiffTest do
  use ExUnit.Case, async: true
  doctest Geex.Edit.LineDiff

  alias Geex.Edit.LineDiff

  # spans/2 must reproduce `new` exactly, and every span must be one hunk.
  defp roundtrip(old, new) do
    assert {:ok, spans} = LineDiff.spans(old, new)
    assert LineDiff.apply_spans(old, spans) == {:ok, new}
    spans
  end

  describe "hunks/2" do
    test "equal texts have no hunks" do
      assert LineDiff.hunks("a\nb\n", "a\nb\n") == []
    end

    test "separate changes are separate hunks, top to bottom, in old coordinates" do
      old = "a\nb\nc\nd\ne"
      new = "a\nB\nc\nd\nE\nF"

      assert LineDiff.hunks(old, new) == [
               %{line: 1, removed: 1, added: ["B"]},
               %{line: 4, removed: 1, added: ["E", "F"]}
             ]
    end

    test "a pure insert removes nothing; a pure delete adds nothing" do
      assert LineDiff.hunks("a\nc", "a\nb\nc") == [%{line: 1, removed: 0, added: ["b"]}]
      assert LineDiff.hunks("a\nb\nc", "a\nc") == [%{line: 1, removed: 1, added: []}]
    end
  end

  describe "spans/2" do
    test "equal texts give no spans" do
      assert LineDiff.spans("same\n", "same\n") == {:ok, []}
    end

    test "a changed line is replaced in place, leaving its newline alone" do
      assert roundtrip("a\nb\nc\n", "a\nB\nc\n") == [{{{1, 0}, {1, 1}}, "B"}]
    end

    test "inserts and deletes at the top, middle and end of the document" do
      for {old, new} <- [
            {"b\nc", "a\nb\nc"},
            {"a\nc", "a\nb\nc"},
            {"a\nb", "a\nb\nc"},
            {"a\nb\nc", "b\nc"},
            {"a\nb\nc", "a\nc"},
            {"a\nb\nc", "a\nb"}
          ] do
        assert [_one] = roundtrip(old, new)
      end
    end

    test "trailing newline added and removed" do
      roundtrip("a\nb", "a\nb\n")
      roundtrip("a\nb\n", "a\nb")
    end

    test "to and from the empty document" do
      roundtrip("", "hello\n")
      roundtrip("delete me\n", "")
      roundtrip("x", "")
    end

    test "multiple hunks come bottom-up, so each range is valid as applied" do
      spans = roundtrip("1\n2\n3\n4\n5\n6", "1\nTWO\n3\n4\n5\nSIX")
      assert [{{{5, 0}, _}, "SIX"}, {{{1, 0}, _}, "TWO"}] = spans
    end

    test "columns are graphemes; \\r is content (CRLF lines diff as text)" do
      assert [{{{1, 0}, {1, 3}}, "中文é"}] = roundtrip("x\n中文!\nz", "x\n中文é\nz")
      roundtrip("a\r\nb\r\n", "a\r\nB\r\n")
    end

    test "randomized round-trip over a small alphabet (fixed seed)" do
      :rand.seed(:exsss, {1, 2, 3})
      pool = ["a", "b", "", "x\r", "é", "中文", "  indented"]
      text = fn -> Enum.map_join(0..:rand.uniform(7), "\n", fn _ -> Enum.random(pool) end) end

      for _ <- 1..500 do
        old = text.()
        new = text.()
        assert {:ok, spans} = LineDiff.spans(old, new), "no spans for #{inspect({old, new})}"
        assert LineDiff.apply_spans(old, spans) == {:ok, new}
      end
    end
  end
end
