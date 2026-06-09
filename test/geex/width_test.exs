defmodule Geex.WidthTest do
  use ExUnit.Case, async: true

  alias Geex.Width

  describe "cells/1 — column width of a grapheme" do
    test "ASCII printable is one column" do
      assert Width.cells("a") == 1
      assert Width.cells("Z") == 1
      assert Width.cells("0") == 1
      assert Width.cells(" ") == 1
      assert Width.cells("~") == 1
    end

    test "East-Asian wide characters are two columns" do
      # U+5B57 字, U+4E2D 中, U+FF21 fullwidth Latin capital A.
      assert Width.cells("\u{5B57}") == 2
      assert Width.cells("\u{4E2D}") == 2
      assert Width.cells("\u{FF21}") == 2
    end

    test "wide emoji is two columns" do
      # U+1F389 PARTY POPPER.
      assert Width.cells("\u{1F389}") == 2
    end

    test "a precomposed accented letter is one column" do
      # U+00E9 é.
      assert Width.cells("é") == 1
    end

    test "a base + combining mark is one grapheme, one column (the mark adds 0)" do
      # "e" + U+0301 COMBINING ACUTE ACCENT — one grapheme cluster.
      assert Width.cells("é") == 1
    end

    test "a lone non-spacing combining mark is zero columns" do
      # U+0301 COMBINING ACUTE ACCENT on its own.
      assert Width.cells("́") == 0
    end

    test "explicit zero-width format characters are zero columns" do
      assert Width.cells("​") == 0
      assert Width.cells("‍") == 0
      assert Width.cells("﻿") == 0
    end

    test "control codes are zero columns" do
      assert Width.cells("\t") == 0
      assert Width.cells("\n") == 0
      assert Width.cells("\e") == 0
    end

    test "the empty string is zero columns" do
      assert Width.cells("") == 0
    end
  end

  describe "string/1 — total column width of a string" do
    test "ASCII sums to its length" do
      assert Width.string("hello") == 5
      assert Width.string("") == 0
    end

    test "a wide glyph counts two" do
      # "a" (1) + U+4E2D 中 (2) + "b" (1) = 4 columns.
      assert Width.string("a\u{4E2D}b") == 4
    end

    test "a combining mark adds zero" do
      # "e" + U+0301 COMBINING ACUTE ACCENT is one grapheme, one column.
      assert Width.string("e\u{0301}") == 1
    end
  end

  describe "col_at_display/2 — display column to 1-based grapheme x (the grid ruler cast)" do
    test "ASCII: display column == grapheme x" do
      assert Width.col_at_display("abcdef", 1) == 1
      assert Width.col_at_display("abcdef", 4) == 4
    end

    test "a wide glyph owns two display columns, both mapping to its grapheme" do
      # "a中b": a=col1, 中=cols2-3 (grapheme 2), b=col4 (grapheme 3).
      line = "a\u{4E2D}b"
      assert Width.col_at_display(line, 1) == 1
      assert Width.col_at_display(line, 2) == 2
      assert Width.col_at_display(line, 3) == 2
      assert Width.col_at_display(line, 4) == 3
    end

    test "a zero-width grapheme owns no column (skipped in the display walk)" do
      # "e" + combining acute is one grapheme of width 1 -> col 1; the next char is col 2.
      line = "e\u{0301}x"
      assert Width.col_at_display(line, 1) == 1
      assert Width.col_at_display(line, 2) == 2
    end

    test "past the drawn width returns the caret after the last grapheme (clamped by the resolver)" do
      assert Width.col_at_display("abc", 99) == 4
      assert Width.col_at_display("", 1) == 1
    end
  end
end
