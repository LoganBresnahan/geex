defmodule Geex.Loop.KeymapTest do
  use ExUnit.Case, async: true

  alias Geex.Loop.Keymap
  alias Geex.Commands.{Delete, Insert, Replace}

  describe "resolve/3 — edits on the one shared path" do
    test "a printable char inserts it and advances the cursor" do
      assert {:edit, %Insert{line: 0, col: 2, text: "x"}, {0, 3}} =
               Keymap.resolve({:char, "x"}, {0, 2}, "ab")
    end

    test "a wide char advances one grapheme column (screen width is the renderer's job)" do
      assert {:edit, %Insert{text: "中"}, {0, 1}} =
               Keymap.resolve({:char, "中"}, {0, 0}, "")
    end

    test "Enter inserts a newline and moves to the next line start" do
      assert {:edit, %Insert{line: 1, col: 3, text: "\n"}, {2, 0}} =
               Keymap.resolve({:key, :enter}, {1, 3}, "a\nbcd\ne")
    end

    test "Tab inserts two spaces" do
      assert {:edit, %Insert{text: "  "}, {0, 2}} = Keymap.resolve({:key, :tab}, {0, 0}, "")
    end

    test "Backspace mid-line deletes the grapheme before the cursor" do
      assert {:edit, %Delete{line: 0, col: 1, count: 1}, {0, 1}} =
               Keymap.resolve({:key, :backspace}, {0, 2}, "abc")
    end

    test "Backspace at column 0 joins onto the previous line (Replace across the boundary)" do
      assert {:edit, %Replace{start_line: 0, start_col: 2, end_line: 1, end_col: 0, text: ""}, {0, 2}} =
               Keymap.resolve({:key, :backspace}, {1, 0}, "ab\ncd")
    end

    test "Backspace at the very start of the buffer is ignored" do
      assert :ignore = Keymap.resolve({:key, :backspace}, {0, 0}, "abc")
    end
  end

  describe "resolve/3 — cursor motion (clamped, wrapping)" do
    test "left within a line" do
      assert {:move, {0, 1}} = Keymap.resolve({:key, :left}, {0, 2}, "abc")
    end

    test "left at column 0 wraps to the end of the previous line" do
      assert {:move, {0, 2}} = Keymap.resolve({:key, :left}, {1, 0}, "ab\ncd")
    end

    test "left at the very start stays put" do
      assert {:move, {0, 0}} = Keymap.resolve({:key, :left}, {0, 0}, "abc")
    end

    test "right within a line" do
      assert {:move, {0, 2}} = Keymap.resolve({:key, :right}, {0, 1}, "abc")
    end

    test "right at the line end wraps to the next line start" do
      assert {:move, {1, 0}} = Keymap.resolve({:key, :right}, {0, 2}, "ab\ncd")
    end

    test "right at the buffer end stays put" do
      assert {:move, {0, 3}} = Keymap.resolve({:key, :right}, {0, 3}, "abc")
    end

    test "up keeps the column, clamped to the shorter line" do
      assert {:move, {0, 2}} = Keymap.resolve({:key, :up}, {1, 4}, "ab\ncdef")
    end

    test "down past the last line stays on it" do
      assert {:move, {1, 0}} = Keymap.resolve({:key, :down}, {1, 0}, "ab\ncd")
    end
  end

  describe "resolve/3 — control" do
    test "Ctrl-Q quits" do
      assert :quit = Keymap.resolve({:ctrl, ?q}, {0, 0}, "")
    end

    test "an unknown key is ignored" do
      assert :ignore = Keymap.resolve({:key, :esc}, {0, 0}, "")
      assert :ignore = Keymap.resolve({:ctrl, ?z}, {0, 0}, "")
    end
  end
end
