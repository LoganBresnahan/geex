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
      assert {:edit, %Replace{start_line: 0, start_col: 2, end_line: 1, end_col: 0, text: ""},
              {0, 2}} =
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

  describe "goal column — sticky vertical motion" do
    test "vertical?/1 flags up/down and Alt+W/S, nothing else" do
      assert Keymap.vertical?({:key, :up})
      assert Keymap.vertical?({:key, :down})
      assert Keymap.vertical?({:alt, ?w})
      assert Keymap.vertical?({:alt, ?S})
      refute Keymap.vertical?({:key, :left})
      refute Keymap.vertical?({:alt, ?d})
      refute Keymap.vertical?({:char, "x"})
    end

    test "goal_column/2 is the column mid-line, :eol at the line end" do
      text = "hello\nhi"
      assert Keymap.goal_column({0, 2}, text) == 2
      assert Keymap.goal_column({0, 5}, text) == :eol
      # an empty line: column 0 is already the end
      assert Keymap.goal_column({1, 2}, "ab\n") == :eol
    end

    test "apply_goal/3 keeps a numeric column, clamped to the target line" do
      text = "0123456789\nhi\nlong enough line"
      # goal 7 on a long line lands at 7; on the 2-char line clamps to 2 (its end)
      assert Keymap.apply_goal({0, 0}, 7, text) == {0, 7}
      assert Keymap.apply_goal({1, 0}, 7, text) == {1, 2}
      assert Keymap.apply_goal({2, 0}, 7, text) == {2, 7}
    end

    test "apply_goal/3 with :eol tracks the end of each line (empty lines included)" do
      text = "hello\n\ngoodbye world"
      assert Keymap.apply_goal({0, 0}, :eol, text) == {0, 5}
      assert Keymap.apply_goal({1, 0}, :eol, text) == {1, 0}
      assert Keymap.apply_goal({2, 0}, :eol, text) == {2, 13}
    end

    test "the goal survives a short line: down through 'hi' and back to a long line restores the column" do
      text = "0123456789\nhi\nABCDEFGHIJ"
      goal = Keymap.goal_column({0, 7}, text)
      # down to the short line clamps, but the goal is unchanged, so down again restores col 7
      assert Keymap.apply_goal({1, 0}, goal, text) == {1, 2}
      assert Keymap.apply_goal({2, 0}, goal, text) == {2, 7}
    end
  end

  describe "resolve/3 — control" do
    test "Ctrl-X / Ctrl-Q / Ctrl-C all quit (flow-control/signal-robust)" do
      assert :quit = Keymap.resolve({:ctrl, ?x}, {0, 0}, "")
      assert :quit = Keymap.resolve({:ctrl, ?q}, {0, 0}, "")
      assert :quit = Keymap.resolve({:ctrl, ?c}, {0, 0}, "")
    end

    test "Ctrl-O saves (ADR-0026's reserved save chord — Ctrl-S is XOFF)" do
      assert :save = Keymap.resolve({:ctrl, ?o}, {0, 0}, "")
      assert :save = Keymap.resolve({:ctrl, ?O}, {0, 0}, "")
    end

    test "an unknown key is ignored" do
      assert :ignore = Keymap.resolve({:ctrl, ?z}, {0, 0}, "")
    end
  end

  describe "resolve/3 — selection (ADR-0029)" do
    test "Alt+H starts a selection, Alt+B selects all, Alt+N / Esc clear" do
      assert :select_start = Keymap.resolve({:alt, ?h}, {0, 0}, "abc")
      assert :select_start = Keymap.resolve({:alt, ?H}, {0, 0}, "abc")
      assert :select_all = Keymap.resolve({:alt, ?b}, {0, 0}, "abc")
      assert :select_all = Keymap.resolve({:alt, ?B}, {0, 0}, "abc")
      assert :select_clear = Keymap.resolve({:alt, ?n}, {0, 0}, "abc")
      assert :select_clear = Keymap.resolve({:key, :esc}, {0, 0}, "abc")
    end

    test "Alt+C / Alt+X / Alt+V are copy / cut / paste (Alt+X distinct from Ctrl-X quit)" do
      assert :copy = Keymap.resolve({:alt, ?c}, {0, 0}, "abc")
      assert :cut = Keymap.resolve({:alt, ?x}, {0, 0}, "abc")
      assert :paste = Keymap.resolve({:alt, ?v}, {0, 0}, "abc")
      assert :quit = Keymap.resolve({:ctrl, ?x}, {0, 0}, "abc")
    end
  end

  describe "resolve/3 — undo/redo (ADR-0031)" do
    test "Alt+Z undoes, Alt+Shift+Z redoes — case-sensitive (the one shift-distinct Alt chord)" do
      assert :undo = Keymap.resolve({:alt, ?z}, {0, 0}, "abc")
      assert :redo = Keymap.resolve({:alt, ?Z}, {0, 0}, "abc")
    end
  end

  describe "resolve/3 — Alt chords" do
    test "Alt+M opens the minibuffer" do
      assert :minibuffer = Keymap.resolve({:alt, ?m}, {0, 0}, "")
      assert :minibuffer = Keymap.resolve({:alt, ?M}, {0, 0}, "")
    end

    test "Alt+WASD moves like the arrows (arrow-key alternative)" do
      text = "abc\ndef"

      assert Keymap.resolve({:alt, ?d}, {0, 0}, text) ==
               Keymap.resolve({:key, :right}, {0, 0}, text)

      assert Keymap.resolve({:alt, ?a}, {0, 1}, text) ==
               Keymap.resolve({:key, :left}, {0, 1}, text)

      assert Keymap.resolve({:alt, ?w}, {1, 1}, text) == Keymap.resolve({:key, :up}, {1, 1}, text)

      assert Keymap.resolve({:alt, ?s}, {0, 1}, text) ==
               Keymap.resolve({:key, :down}, {0, 1}, text)
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

    test "Alt+G opens grid mode (ADR-0027)" do
      assert :grid = Keymap.resolve({:alt, ?g}, {0, 0}, "abc")
      assert :grid = Keymap.resolve({:alt, ?G}, {0, 0}, "abc")
    end

    test "Alt+P opens the command palette (ADR-0028 §3)" do
      assert :palette = Keymap.resolve({:alt, ?p}, {0, 0}, "abc")
      assert :palette = Keymap.resolve({:alt, ?P}, {0, 0}, "abc")
    end

    test "the retired ERTYUIOP letters and other unbound Alt letters are ignored" do
      assert :ignore = Keymap.resolve({:alt, ?t}, {0, 0}, "abc")
      assert :ignore = Keymap.resolve({:alt, ?y}, {0, 0}, "abc")
      assert :ignore = Keymap.resolve({:alt, ?o}, {0, 0}, "abc")
      assert :ignore = Keymap.resolve({:alt, ?j}, {0, 0}, "abc")
    end
  end

  describe "Home, End, Delete" do
    test "Home and End go to the line's start and end" do
      assert {:move, {1, 0}} = Keymap.resolve({:key, :home}, {1, 2}, "ab\ncdef")
      assert {:move, {1, 4}} = Keymap.resolve({:key, :end}, {1, 2}, "ab\ncdef")
    end

    test "Delete removes the grapheme under the cursor and stays put" do
      assert {:edit, %Delete{line: 0, col: 1, count: 1}, {0, 1}} =
               Keymap.resolve({:key, :delete}, {0, 1}, "abc")
    end

    test "Delete at a line's end joins the next line" do
      assert {:edit, %Replace{start_line: 0, start_col: 2, end_line: 1, end_col: 0, text: ""},
              {0, 2}} = Keymap.resolve({:key, :delete}, {0, 2}, "ab\ncd")
    end

    test "Delete at the very end of the buffer is ignored" do
      assert :ignore = Keymap.resolve({:key, :delete}, {1, 2}, "ab\ncd")
    end
  end
end
