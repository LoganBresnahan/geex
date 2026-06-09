defmodule Geex.Edit.FootprintTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer.Doc
  alias Geex.Commands.{Delete, Edit, Insert, Replace}
  alias Geex.Edit.Footprint

  defp doc(text), do: Doc.new(text)

  describe "of/2 — Insert" do
    test "byte offset at the position; added = byte_size(text), removed = 0" do
      d = doc("abc\ndef")

      assert Footprint.of(d, %Insert{line: 1, col: 1, text: "XY"}) == %{
               at: 5,
               removed: 0,
               added: 2
             }
    end

    test "multibyte text counts bytes, not graphemes" do
      d = doc("abc")
      # "中" is 3 bytes; inserted at col 3 (byte 3).
      assert Footprint.of(d, %Insert{line: 0, col: 3, text: "中"}) == %{
               at: 3,
               removed: 0,
               added: 3
             }
    end

    test "a multibyte glyph before the caret advances the byte offset by its byte size" do
      d = doc("中b")
      # caret after the wide glyph (grapheme col 1) is byte 3.
      assert Footprint.of(d, %Insert{line: 0, col: 1, text: "x"}) == %{
               at: 3,
               removed: 0,
               added: 1
             }
    end
  end

  describe "of/2 — Delete" do
    test "removed = byte span of the deleted graphemes; added = 0" do
      d = doc("abcdef")
      assert Footprint.of(d, %Delete{line: 0, col: 2, count: 3}) == %{at: 2, removed: 3, added: 0}
    end

    test "deleting a multibyte grapheme removes its bytes" do
      d = doc("a中b")
      # delete the 中 (grapheme col 1): at byte 1, removed 3 bytes.
      assert Footprint.of(d, %Delete{line: 0, col: 1, count: 1}) == %{at: 1, removed: 3, added: 0}
    end
  end

  describe "of/2 — Replace" do
    test "at = start byte, removed = range byte length, added = byte_size(text)" do
      d = doc("hello world")
      cmd = %Replace{start_line: 0, start_col: 0, end_line: 0, end_col: 5, text: "goodbye"}
      assert Footprint.of(d, cmd) == %{at: 0, removed: 5, added: 7}
    end

    test "a cross-line range counts the newline byte" do
      d = doc("ab\ncd")
      cmd = %Replace{start_line: 0, start_col: 1, end_line: 1, end_col: 1, text: ""}
      # from byte 1 to byte 4 ("b\nc" = 3 bytes) removed, nothing added.
      assert Footprint.of(d, cmd) == %{at: 1, removed: 3, added: 0}
    end
  end

  test "of/2 — a non-contiguous command (Edit) is :unknown" do
    d = doc("abc")
    assert Footprint.of(d, %Edit{edits: [%{search: "a", replace: "b"}]}) == :unknown
  end

  describe "between/2 — the splice between two texts (undo/redo, ADR-0031)" do
    test "an appended insert: removed = 0, added = the new bytes, at = common prefix" do
      assert Footprint.between("hello", "hello world") == %{at: 5, removed: 0, added: 6}
    end

    test "its inverse (the undo) is the mirror delete" do
      assert Footprint.between("hello world", "hello") == %{at: 5, removed: 6, added: 0}
    end

    test "a change in the middle: common prefix AND suffix bound the splice" do
      assert Footprint.between("abcXYZdef", "abcdef") == %{at: 3, removed: 3, added: 0}
      assert Footprint.between("abcdef", "abcXYZdef") == %{at: 3, removed: 0, added: 3}
    end

    test "a same-length in-place replace" do
      assert Footprint.between("hello", "help!") == %{at: 3, removed: 2, added: 2}
    end

    test "counts bytes, not graphemes" do
      assert Footprint.between("a", "a中") == %{at: 1, removed: 0, added: 3}
    end

    test "the prefix and suffix never overlap (repeated bytes)" do
      # "aa" -> "aaa": prefix is 2, so the suffix is capped to 0 — an insert of 1 byte at 2,
      # not a double-counted overlap.
      assert Footprint.between("aa", "aaa") == %{at: 2, removed: 0, added: 1}
    end

    test "empty edges" do
      assert Footprint.between("", "x") == %{at: 0, removed: 0, added: 1}
      assert Footprint.between("x", "") == %{at: 0, removed: 1, added: 0}
    end
  end
end
