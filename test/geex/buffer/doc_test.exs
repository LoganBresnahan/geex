defmodule Geex.Buffer.DocTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer.Doc

  describe "new/1 and text/1" do
    test "round-trips text through lines" do
      assert Doc.new("a\nb\nc") |> Doc.text() == "a\nb\nc"
    end

    test "empty text is a single empty line" do
      doc = Doc.new("")
      assert doc.lines == [""]
      assert Doc.line_count(doc) == 1
    end

    test "line/2 returns the line or nil out of range" do
      doc = Doc.new("first\nsecond")
      assert Doc.line(doc, 1) == "second"
      assert Doc.line(doc, 9) == nil
    end
  end

  describe "insert/3" do
    test "inserts within a line" do
      assert {:ok, doc} = Doc.insert(Doc.new("hello"), {0, 5}, " world")
      assert Doc.text(doc) == "hello world"
    end

    test "inserts in the middle of a line (grapheme col)" do
      assert {:ok, doc} = Doc.insert(Doc.new("hllo"), {0, 1}, "e")
      assert Doc.text(doc) == "hello"
    end

    test "inserted newlines split the line" do
      assert {:ok, doc} = Doc.insert(Doc.new("ac"), {0, 1}, "b\nB")
      assert doc.lines == ["ab", "Bc"]
    end

    test "is UTF-8 / grapheme correct" do
      assert {:ok, doc} = Doc.insert(Doc.new("café"), {0, 4}, "!")
      assert Doc.text(doc) == "café!"
    end

    test "rejects out-of-range row and col" do
      assert {:error, :row_out_of_range} = Doc.insert(Doc.new("x"), {5, 0}, "y")
      assert {:error, :col_out_of_range} = Doc.insert(Doc.new("x"), {0, 9}, "y")
    end
  end

  describe "delete/3" do
    test "deletes within a line" do
      assert {:ok, doc} = Doc.delete(Doc.new("hello world"), {0, 5}, 6)
      assert Doc.text(doc) == "hello"
    end

    test "clamps a count past the end of the line" do
      assert {:ok, doc} = Doc.delete(Doc.new("hi"), {0, 1}, 99)
      assert Doc.text(doc) == "h"
    end

    test "rejects out-of-range row and col" do
      assert {:error, :row_out_of_range} = Doc.delete(Doc.new("x"), {5, 0}, 1)
      assert {:error, :col_out_of_range} = Doc.delete(Doc.new("x"), {0, 9}, 1)
    end
  end

  describe "replace/3 — the general range edit" do
    test "replaces within a single line" do
      assert {:ok, doc} = Doc.replace(Doc.new("hello world"), {{0, 6}, {0, 11}}, "there")
      assert Doc.text(doc) == "hello there"
    end

    test "an empty range is a point insert" do
      assert {:ok, doc} = Doc.replace(Doc.new("ac"), {{0, 1}, {0, 1}}, "b")
      assert Doc.text(doc) == "abc"
    end

    test "an empty text deletes the range (multi-line)" do
      assert {:ok, doc} = Doc.replace(Doc.new("aaa\nbbb\nccc"), {{0, 1}, {2, 1}}, "")
      assert Doc.text(doc) == "acc"
    end

    test "replaces a multi-line range with multi-line text" do
      assert {:ok, doc} = Doc.replace(Doc.new("one\ntwo\nthree"), {{0, 1}, {2, 2}}, "X\nY")
      # "o" + "X\nY" + "ree"  →  "oX" / "Yree"
      assert Doc.text(doc) == "oX\nYree"
    end

    test "collapses a multi-line range to one line when text has no newline" do
      assert {:ok, doc} = Doc.replace(Doc.new("ab\ncd\nef"), {{0, 1}, {2, 1}}, "-")
      assert Doc.text(doc) == "a-f"
    end

    test "replaces an entire single line" do
      assert {:ok, doc} = Doc.replace(Doc.new("a\nb\nc"), {{1, 0}, {1, 1}}, "BBB")
      assert Doc.text(doc) == "a\nBBB\nc"
    end

    test "is grapheme-aware (combining/multibyte)" do
      assert {:ok, doc} = Doc.replace(Doc.new("café au lait"), {{0, 3}, {0, 4}}, "X")
      assert Doc.text(doc) == "cafX au lait"
    end

    test "rejects a reversed range" do
      assert {:error, :range_reversed} = Doc.replace(Doc.new("abc\ndef"), {{1, 0}, {0, 0}}, "x")
      assert {:error, :range_reversed} = Doc.replace(Doc.new("abc"), {{0, 2}, {0, 1}}, "x")
    end

    test "rejects out-of-range rows and cols" do
      assert {:error, :row_out_of_range} = Doc.replace(Doc.new("x"), {{0, 0}, {5, 0}}, "y")
      assert {:error, :col_out_of_range} = Doc.replace(Doc.new("x"), {{0, 0}, {0, 9}}, "y")
      assert {:error, :col_out_of_range} = Doc.replace(Doc.new("x"), {{0, 9}, {0, 9}}, "y")
    end
  end

  describe "slice/2 — read a range (the sibling of replace/3)" do
    test "a single-line, half-open range returns the graphemes in [c1, c2)" do
      assert {:ok, "ell"} = Doc.slice(Doc.new("hello"), {{0, 1}, {0, 4}})
    end

    test "an empty range yields an empty string" do
      assert {:ok, ""} = Doc.slice(Doc.new("hello"), {{0, 2}, {0, 2}})
    end

    test "a whole single line" do
      assert {:ok, "hello"} = Doc.slice(Doc.new("hello\nworld"), {{0, 0}, {0, 5}})
    end

    test "a multi-line range joins the tail of the first line, full middle lines, and the head of the last" do
      doc = Doc.new("hello\nbig\nworld")
      assert {:ok, "llo\nbig\nwo"} = Doc.slice(doc, {{0, 2}, {2, 2}})
    end

    test "an adjacent-line range has no middle lines" do
      assert {:ok, "lo\nwo"} = Doc.slice(Doc.new("hello\nworld"), {{0, 3}, {1, 2}})
    end

    test "slice is grapheme-correct for multibyte content" do
      assert {:ok, "中文"} = Doc.slice(Doc.new("a中文b"), {{0, 1}, {0, 3}})
    end

    test "slice then replace-with-empty over the same range is a cut (round-trips)" do
      doc = Doc.new("hello\nworld")
      range = {{0, 2}, {1, 3}}
      assert {:ok, cut_text} = Doc.slice(doc, range)
      assert {:ok, after_cut} = Doc.replace(doc, range, "")
      # what was sliced out, plus what remains, reconstructs the original around the cut
      assert cut_text == "llo\nwor"
      assert Doc.text(after_cut) == "held"
    end

    test "rejects reversed and out-of-range" do
      assert {:error, :range_reversed} = Doc.slice(Doc.new("ab"), {{0, 2}, {0, 0}})
      assert {:error, :row_out_of_range} = Doc.slice(Doc.new("ab"), {{0, 0}, {5, 0}})
      assert {:error, :col_out_of_range} = Doc.slice(Doc.new("ab"), {{0, 0}, {0, 9}})
    end
  end

  describe "byte_offset/2" do
    test "counts bytes before a caret, with one byte per newline" do
      d = Doc.new("ab\ncd\nef")
      assert Doc.byte_offset(d, {0, 0}) == 0
      assert Doc.byte_offset(d, {0, 2}) == 2
      assert Doc.byte_offset(d, {1, 0}) == 3
      assert Doc.byte_offset(d, {2, 1}) == 7
    end

    test "counts bytes, not graphemes, for multibyte content" do
      d = Doc.new("a中b")
      assert Doc.byte_offset(d, {0, 1}) == 1
      assert Doc.byte_offset(d, {0, 2}) == 4
      assert Doc.byte_offset(d, {0, 3}) == 5
    end

    test "clamps an out-of-range row/col to the document end" do
      d = Doc.new("ab\ncd")
      assert Doc.byte_offset(d, {9, 0}) == 3
      assert Doc.byte_offset(d, {0, 99}) == 2
    end
  end
end
