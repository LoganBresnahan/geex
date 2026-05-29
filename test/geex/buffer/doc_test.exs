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
end
