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
    test "Ctrl-X / Ctrl-Q / Ctrl-C all quit (flow-control/signal-robust)" do
      assert :quit = Keymap.resolve({:ctrl, ?x}, {0, 0}, "")
      assert :quit = Keymap.resolve({:ctrl, ?q}, {0, 0}, "")
      assert :quit = Keymap.resolve({:ctrl, ?c}, {0, 0}, "")
    end

    test "an unknown key is ignored" do
      assert :ignore = Keymap.resolve({:key, :esc}, {0, 0}, "")
      assert :ignore = Keymap.resolve({:ctrl, ?z}, {0, 0}, "")
    end
  end

  describe "resolve/3 — Alt chords" do
    test "Alt+M opens the minibuffer" do
      assert :minibuffer = Keymap.resolve({:alt, ?m}, {0, 0}, "")
      assert :minibuffer = Keymap.resolve({:alt, ?M}, {0, 0}, "")
    end

    test "Alt+WASD moves like the arrows (arrow-key alternative)" do
      text = "abc\ndef"
      assert Keymap.resolve({:alt, ?d}, {0, 0}, text) == Keymap.resolve({:key, :right}, {0, 0}, text)
      assert Keymap.resolve({:alt, ?a}, {0, 1}, text) == Keymap.resolve({:key, :left}, {0, 1}, text)
      assert Keymap.resolve({:alt, ?w}, {1, 1}, text) == Keymap.resolve({:key, :up}, {1, 1}, text)
      assert Keymap.resolve({:alt, ?s}, {0, 1}, text) == Keymap.resolve({:key, :down}, {0, 1}, text)
    end

    test "Alt+R/F jump to line start / end" do
      text = "foo bar baz"
      assert {:move, {0, 0}} = Keymap.resolve({:alt, ?r}, {0, 5}, text)
      assert {:move, {0, 11}} = Keymap.resolve({:alt, ?f}, {0, 5}, text)
    end

    test "Alt+Q/E move by word (whitespace-delimited, clamped to the line)" do
      text = "foo bar baz"
      # forward (E) from start / mid-word → start of "bar"
      assert {:move, {0, 4}} = Keymap.resolve({:alt, ?e}, {0, 0}, text)
      assert {:move, {0, 4}} = Keymap.resolve({:alt, ?e}, {0, 1}, text)
      # backward (Q) from "baz" → start of "bar"
      assert {:move, {0, 4}} = Keymap.resolve({:alt, ?q}, {0, 8}, text)
      # forward at the last word clamps to the line end; backward at the first clamps to col 0
      assert {:move, {0, 11}} = Keymap.resolve({:alt, ?e}, {0, 8}, text)
      assert {:move, {0, 0}} = Keymap.resolve({:alt, ?q}, {0, 2}, text)
    end

    test "the retired ERTYUIOP letters and other Alt letters are ignored" do
      assert :ignore = Keymap.resolve({:alt, ?t}, {0, 0}, "abc")
      assert :ignore = Keymap.resolve({:alt, ?y}, {0, 0}, "abc")
      assert :ignore = Keymap.resolve({:alt, ?o}, {0, 0}, "abc")
      assert :ignore = Keymap.resolve({:alt, ?z}, {0, 0}, "abc")
    end
  end
end
