defmodule Geex.Edit.FootprintTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer.Doc
  alias Geex.Commands.{Delete, Edit, Insert, Replace}
  alias Geex.Edit.Footprint

  defp doc(text), do: Doc.new(text)

  describe "of/2 — Insert" do
    test "byte offset at the position; added = byte_size(text), removed = 0" do
      d = doc("abc\ndef")
      assert Footprint.of(d, %Insert{line: 1, col: 1, text: "XY"}) == %{at: 5, removed: 0, added: 2}
    end

    test "multibyte text counts bytes, not graphemes" do
      d = doc("abc")
      # "中" is 3 bytes; inserted at col 3 (byte 3).
      assert Footprint.of(d, %Insert{line: 0, col: 3, text: "中"}) == %{at: 3, removed: 0, added: 3}
    end

    test "a multibyte glyph before the caret advances the byte offset by its byte size" do
      d = doc("中b")
      # caret after the wide glyph (grapheme col 1) is byte 3.
      assert Footprint.of(d, %Insert{line: 0, col: 1, text: "x"}) == %{at: 3, removed: 0, added: 1}
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
end
