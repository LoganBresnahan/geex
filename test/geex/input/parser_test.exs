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

    # With the tty's signal keys off (BUG-3), Ctrl-\ arrives as byte 28; it and its neighbours
    # must not be typed into the buffer as text.
    test "Ctrl-@, Ctrl-\\, Ctrl-], Ctrl-^ and Ctrl-_ are Ctrl keys, not text" do
      assert {[{:ctrl, ?@}, {:ctrl, ?\\}, {:ctrl, ?]}, {:ctrl, ?^}, {:ctrl, ?_}], ""} =
               Parser.parse(<<0, 28, 29, 30, 31>>)
    end

    test "Ctrl-z and Ctrl-s are Ctrl keys" do
      assert {[{:ctrl, ?z}, {:ctrl, ?s}], ""} = Parser.parse(<<26, 19>>)
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

  describe "Alt/Meta-letter (ESC-prefixed)" do
    test "ESC + lowercase letter" do
      assert {[{:alt, ?m}], ""} = Parser.parse("\em")
    end

    test "ESC + uppercase letter" do
      assert {[{:alt, ?M}], ""} = Parser.parse("\eM")
    end

    test "an Alt chord followed by typing parses both" do
      assert {[{:alt, ?d}, {:char, "x"}], ""} = Parser.parse("\edx")
    end

    test "CSI still wins over Alt (the `[` is not a letter)" do
      assert {[{:key, :up}], ""} = Parser.parse("\e[A")
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

  # Every special key a terminal sends is read as one unit: mapped, or dropped. None of it may
  # reach the buffer as text (pressing End in tmux once typed "[4~" into the file).
  describe "whole control sequences" do
    test "Home, End and Delete, in the xterm, VT220 and SS3 forms" do
      for {bytes, key} <- [
            {"\e[H", :home},
            {"\e[1~", :home},
            {"\e[7~", :home},
            {"\eOH", :home},
            {"\e[F", :end},
            {"\e[4~", :end},
            {"\e[8~", :end},
            {"\eOF", :end},
            {"\e[3~", :delete},
            {"\eOA", :up},
            {"\eOD", :left}
          ] do
        assert Parser.parse(bytes) == {[{:key, key}], ""}, inspect(bytes)
      end
    end

    test "unsupported keys are dropped, never typed" do
      for bytes <- [
            "\e[5~",
            "\e[6~",
            "\e[2~",
            "\e[1;5C",
            "\e[1;2A",
            "\e[3;5~",
            "\eOP",
            "\e[15~",
            "\e[<0;12M",
            "\e[<0;0;5M",
            "\e[200~"
          ] do
        assert Parser.parse(bytes) == {[], ""}, inspect(bytes)
      end
    end

    test "text around a dropped sequence survives" do
      assert Parser.parse("a\e[5~b\e[4~c") ==
               {[{:char, "a"}, {:char, "b"}, {:key, :end}, {:char, "c"}], ""}
    end

    test "an incomplete sequence waits for the rest, across chunks" do
      assert {[], "\e[1;5"} = Parser.parse("\e[1;5")
      assert {[], ""} = Parser.parse("\e[1;5" <> "C")
      assert {[{:key, :delete}], ""} = Parser.parse("\e[3" <> "~")
    end

    test "garbage that never finishes isn't held forever" do
      assert {[], ""} = Parser.parse("\e[" <> String.duplicate("1", 40))
    end

    test "ESC [ followed by a control byte wasn't a sequence: the rest is re-read" do
      assert {[{:key, :enter}], ""} = Parser.parse("\e[\r")
    end

    test "a lone ESC O at the end of a chunk is Alt+Shift+O" do
      assert {[{:alt, ?O}], ""} = Parser.parse("\eO")
    end
  end

  # Esc, then "[", then "a", typed as separate keystrokes: the leftover Esc joined the "[" and
  # the "a" closed a CSI that was dropped, losing all three. TerminalIO now flushes a leftover
  # that nothing followed within 40 ms.
  describe "flush/1: a leftover nothing followed was typed" do
    test "a bare Esc is the Esc key; what follows it is ordinary input" do
      assert Parser.flush("\e") == [{:key, :esc}]
      assert Parser.flush("\e[") == [{:key, :esc}, {:char, "["}]

      assert Parser.flush("\e[1;5") ==
               Enum.concat([[{:key, :esc}], Enum.map(~w([ 1 ; 5), &{:char, &1})])
    end

    test "every Esc counts" do
      assert Parser.flush("\e\e") == [{:key, :esc}, {:key, :esc}]
    end

    test "Esc, [ and a as separate keystrokes all arrive" do
      {[], left} = Parser.parse("\e")
      events = Parser.flush(left)
      {more, ""} = Parser.parse("[")
      {last, ""} = Parser.parse("a")
      assert events ++ more ++ last == [{:key, :esc}, {:char, "["}, {:char, "a"}]
    end
  end

  # Mouse reports (ADR-0039): SGR mode 1006, and the old `ESC [ M` form for terminals without it.
  describe "mouse reports" do
    defp m(action, button, x, y, mods \\ []),
      do: {:mouse, %{action: action, button: button, x: x, y: y, mods: mods}}

    test "SGR press, release and drag, 1-based coordinates made 0-based" do
      assert Parser.parse("\e[<0;10;5M") == {[m(:press, :left, 9, 4)], ""}
      assert Parser.parse("\e[<0;10;5m") == {[m(:release, :left, 9, 4)], ""}
      assert Parser.parse("\e[<1;1;1M") == {[m(:press, :middle, 0, 0)], ""}
      assert Parser.parse("\e[<2;1;1M") == {[m(:press, :right, 0, 0)], ""}
      assert Parser.parse("\e[<32;3;4M") == {[m(:drag, :left, 2, 3)], ""}
      assert Parser.parse("\e[<35;3;4M") == {[m(:move, :none, 2, 3)], ""}
      assert Parser.parse("\e[MCAA") == {[m(:move, :none, 32, 32)], ""}
    end

    test "coordinates past 223, which the old form can't carry" do
      assert Parser.parse("\e[<0;224;300M") == {[m(:press, :left, 223, 299)], ""}
      assert Parser.parse("\e[<32;1000;1000M") == {[m(:drag, :left, 999, 999)], ""}
    end

    test "the wheel, four ways" do
      assert Parser.parse("\e[<64;5;6M") == {[m(:wheel, :up, 4, 5)], ""}
      assert Parser.parse("\e[<65;5;6M") == {[m(:wheel, :down, 4, 5)], ""}
      assert Parser.parse("\e[<66;5;6M") == {[m(:wheel, :wheel_left, 4, 5)], ""}
      assert Parser.parse("\e[<67;5;6M") == {[m(:wheel, :wheel_right, 4, 5)], ""}
    end

    test "Shift, Alt and Ctrl" do
      assert Parser.parse("\e[<4;2;2M") == {[m(:press, :left, 1, 1, [:shift])], ""}
      assert Parser.parse("\e[<8;2;2M") == {[m(:press, :left, 1, 1, [:alt])], ""}
      assert Parser.parse("\e[<16;2;2M") == {[m(:press, :left, 1, 1, [:ctrl])], ""}
      assert Parser.parse("\e[<36;2;2M") == {[m(:drag, :left, 1, 1, [:shift])], ""}
      assert Parser.parse("\e[<68;2;2M") == {[m(:wheel, :up, 1, 1, [:shift])], ""}
    end

    test "extra buttons" do
      assert Parser.parse("\e[<128;1;1M") == {[m(:press, 8, 0, 0)], ""}
      assert Parser.parse("\e[<129;1;1m") == {[m(:release, 9, 0, 0)], ""}
    end

    test "a report split across reads waits for the rest; text around it survives" do
      assert {[{:char, "a"}], "\e[<0;12"} = Parser.parse("a\e[<0;12")
      assert Parser.parse("\e[<0;12" <> ";5Mb") == {[m(:press, :left, 11, 4), {:char, "b"}], ""}
    end

    test "the old form: ESC [ M and three bytes, each value plus 32" do
      assert Parser.parse("\e[M !\"") == {[m(:press, :left, 0, 1)], ""}
      assert Parser.parse("\e[M#!!") == {[m(:release, :none, 0, 0)], ""}
      assert Parser.parse("\e[M`!!") == {[m(:wheel, :up, 0, 0)], ""}
      assert Parser.parse(<<"\e[M", 32, 255, 255>>) == {[m(:press, :left, 222, 222)], ""}
      # Its bytes never land in the buffer, even split across reads.
      assert {[], "\e[M "} = Parser.parse("\e[M ")
      assert Parser.parse("\e[M " <> "!!x") == {[m(:press, :left, 0, 0), {:char, "x"}], ""}
    end
  end

  # ADR-0040 §1: the terminal's answer to OSC 11, read as one event, never as keys.
  describe "OSC answers" do
    @answer "11;rgb:1e1e/1e1e/2e2e"

    test "ended by BEL or by ST, with keys around it" do
      assert Parser.parse("\e]" <> @answer <> "\a") == {[{:osc, "11", "rgb:1e1e/1e1e/2e2e"}], ""}

      assert Parser.parse("a\e]" <> @answer <> "\e\\b") ==
               {[{:char, "a"}, {:osc, "11", "rgb:1e1e/1e1e/2e2e"}, {:char, "b"}], ""}
    end

    test "split across reads anywhere, it is held and then read whole" do
      whole = "\e]" <> @answer <> "\e\\"

      for at <- 1..(byte_size(whole) - 1) do
        <<first::binary-size(at), second::binary>> = whole
        {[], leftover} = Parser.parse(first)
        assert Parser.parse(leftover <> second) == {[{:osc, "11", "rgb:1e1e/1e1e/2e2e"}], ""}
      end
    end

    test "an answer that comes late is still an answer; another OSC is read too" do
      assert {[{:key, :down}, {:osc, "11", _}], ""} =
               Parser.parse("\e[B\e]" <> @answer <> "\a")

      assert Parser.parse("\e]10;rgb:ff/ff/ff\a") == {[{:osc, "10", "rgb:ff/ff/ff"}], ""}
    end

    test "typed Alt+] stays keys: held only until the caller flushes it" do
      assert Parser.parse("\e]") == {[], "\e]"}
      assert Parser.flush("\e]") == [{:key, :esc}, {:char, "]"}]
      # An ESC that isn't ST inside: not an OSC, so Esc, `]` and the rest, as typed.
      assert Parser.parse("\e]x\e[A") ==
               {[{:key, :esc}, {:char, "]"}, {:char, "x"}, {:key, :up}], ""}

      assert Parser.parse("\e]\e[A") == {[{:key, :esc}, {:char, "]"}, {:key, :up}], ""}
      # Alt+] then Ctrl-G (BEL), or then `ESC \`: no number, so not an OSC either.
      assert Parser.parse("\e]\a") == {[{:key, :esc}, {:char, "]"}, {:ctrl, ?g}], ""}
    end

    test "past its cap it isn't held: it was typed (a paste after Alt+] keeps its text)" do
      paste = String.duplicate("x", 300)
      {events, ""} = Parser.parse("\e]" <> paste)
      assert [{:key, :esc}, {:char, "]"} | chars] = events
      assert Enum.map_join(chars, &elem(&1, 1)) == paste
    end
  end
end
