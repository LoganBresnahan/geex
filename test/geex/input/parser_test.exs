defmodule Geex.Input.ParserTest do
  use ExUnit.Case, async: true
  doctest Geex.Input.Parser

  alias Geex.Input.Parser

  describe "single bytes" do
    test "plain ASCII char" do
      assert {[{:char, "a"}], ""} = Parser.parse("a")
    end

    test "carriage return is enter" do
      assert {[{:key, :enter}], ""} = Parser.parse("\r")
    end

    test "newline is enter" do
      assert {[{:key, :enter}], ""} = Parser.parse("\n")
    end

    test "tab" do
      assert {[{:key, :tab}], ""} = Parser.parse("\t")
    end

    test "DEL (127) is backspace" do
      assert {[{:key, :backspace}], ""} = Parser.parse(<<127>>)
    end

    test "Ctrl-c" do
      assert {[{:ctrl, ?c}], ""} = Parser.parse(<<3>>)
    end

    test "Ctrl-a" do
      assert {[{:ctrl, ?a}], ""} = Parser.parse(<<1>>)
    end
  end

  describe "arrow keys" do
    test "up" do
      assert {[{:key, :up}], ""} = Parser.parse("\e[A")
    end

    test "down" do
      assert {[{:key, :down}], ""} = Parser.parse("\e[B")
    end

    test "right" do
      assert {[{:key, :right}], ""} = Parser.parse("\e[C")
    end

    test "left" do
      assert {[{:key, :left}], ""} = Parser.parse("\e[D")
    end
  end

  describe "partial escape sequences become leftover" do
    test "lone ESC" do
      assert {[], "\e"} = Parser.parse("\e")
    end

    test "ESC [ without final byte" do
      assert {[], "\e["} = Parser.parse("\e[")
    end

    test "leftover chains with next chunk" do
      {events1, leftover} = Parser.parse("\e[")
      assert events1 == []
      assert {[{:key, :up}], ""} = Parser.parse(leftover <> "A")
    end
  end

  describe "mixed input in a single chunk" do
    test "chars + arrow + chars" do
      assert {[{:char, "a"}, {:char, "b"}, {:key, :right}, {:char, "d"}], ""} =
               Parser.parse("ab\e[Cd")
    end

    test "two arrows back to back" do
      assert {[{:key, :up}, {:key, :down}], ""} = Parser.parse("\e[A\e[B")
    end

    test "trailing partial escape preserved" do
      assert {[{:char, "x"}], "\e["} = Parser.parse("x\e[")
    end
  end

  describe "UTF-8" do
    test "single multi-byte grapheme" do
      assert {[{:char, "é"}], ""} = Parser.parse("é")
    end

    test "emoji as single char event" do
      assert {[{:char, "😀"}], ""} = Parser.parse("😀")
    end
  end
end
