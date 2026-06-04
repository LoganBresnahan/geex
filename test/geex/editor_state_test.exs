defmodule Geex.EditorStateTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer.Doc
  alias Geex.EditorState

  describe "construction & accessors" do
    test "new/1 wraps text into a Doc and round-trips" do
      state = EditorState.new("a\nb\nc")
      assert EditorState.text(state) == "a\nb\nc"
      assert EditorState.lines(state) == ["a", "b", "c"]
      assert EditorState.line_count(state) == 3
    end

    test "new/0 defaults to one empty line" do
      assert EditorState.text(EditorState.new()) == ""
      assert EditorState.lines(EditorState.new()) == [""]
    end

    test "from_doc/1 wraps an existing Doc" do
      doc = Doc.new("wrapped")
      assert EditorState.doc(EditorState.from_doc(doc)) == doc
    end
  end

  describe "update_doc/2 — threads a Doc op back into the state" do
    test "threads an :ok result into a new state" do
      assert {:ok, state} =
               EditorState.update_doc(EditorState.new("hi"), &Doc.insert(&1, {0, 2}, "!"))

      assert EditorState.text(state) == "hi!"
    end

    test "propagates an :error result unchanged" do
      assert {:error, :col_out_of_range} =
               EditorState.update_doc(EditorState.new("hi"), &Doc.insert(&1, {0, 9}, "!"))
    end
  end
end
