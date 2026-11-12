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

    test "ESC ; is Alt+;, line end's key (ADR-0049)" do
      assert Parser.parse("\e;") == {[{:alt, ?;}], ""}
      assert Parser.parse("\e;x") == {[{:alt, ?;}, {:char, "x"}], ""}
    end

    test "ESC ` is Alt+`, read though unbound (ADR-0050, ADR-0051)" do
      assert Parser.parse("\e`") == {[{:alt, ?`}], ""}
      assert Parser.parse("a\e`b") == {[{:char, "a"}, {:alt, ?`}, {:char, "b"}], ""}
    end

    test "ESC < and ESC > are Alt+< and Alt+>, the pane keys (ADR-0051)" do
      assert Parser.parse("\e<") == {[{:alt, ?<}], ""}
      assert Parser.parse("\e>x\e<") == {[{:alt, ?>}, {:char, "x"}, {:alt, ?<}], ""}
      assert Parser.parse("\e>\e>") == {[{:alt, ?>}, {:alt, ?>}], ""}
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
            {"\eOD", :left},
            # Page Up/Down, for the markdown preview's scrolling (ADR-0043 §1).
            {"\e[5~", :page_up},
            {"\e[6~", :page_down}
          ] do
        assert Parser.parse(bytes) == {[{:key, key}], ""}, inspect(bytes)
      end
    end

    test "unsupported keys are dropped, never typed" do
      for bytes <- [
            # Modified Page Up/Down stay dropped.
            "\e[5;5~",
            "\e[6;2~",
            "\e[2~",
            "\e[1;5C",
            "\e[1;2A",
            "\e[3;5~",
            "\eOP",
            "\e[15~",
            "\e[<0;12M",
            "\e[<0;0;5M",
            "\e[201~"
          ] do
        assert Parser.parse(bytes) == {[], ""}, inspect(bytes)
      end
    end

    # ADR-0026's 2026-11-09 amendment: a bracketed paste is one event, its line breaks and
    # brackets text, not keys.
    test "a bracketed paste is one event, however it arrives" do
      assert Parser.parse("x\e[200~if (a) {\r  b\r}\e[201~y") ==
               {[{:char, "x"}, {:paste, "if (a) {\r  b\r}"}, {:char, "y"}], ""}

      assert {[], "\e[200~ab" = held} = Parser.parse("\e[200~ab")
      assert Parser.paste?(held)
      assert Parser.parse(held <> "c\e[201~z") == {[{:paste, "abc"}, {:char, "z"}], ""}
      # Its end never came: what came is the paste.
      assert Parser.flush("\e[200~half") == [{:paste, "half"}]
      # Not UTF-8: replaced, never a crash later.
      assert Parser.parse("\e[200~a" <> <<255>> <> "\e[201~") == {[{:paste, "a\uFFFD"}], ""}
    end

    test "Shift+Tab (back-tab, ESC [ Z) is a key (roadmap item 18.7)" do
      assert Parser.parse("\e[Z") == {[{:key, :shift_tab}], ""}
      assert Parser.parse("a\e[Zb") == {[{:char, "a"}, {:key, :shift_tab}, {:char, "b"}], ""}
    end

    test "Alt with an arrow is an Alt key (roadmap item 18.8); other modifiers stay dropped" do
      assert Parser.parse("\e[1;3A\e[1;3B\e[1;3C\e[1;3D") ==
               {[{:alt, :up}, {:alt, :down}, {:alt, :right}, {:alt, :left}], ""}

      assert Parser.parse("\e[1;3") == {[], "\e[1;3"}
      assert Parser.parse("\e[1;4A\e[1;7D") == {[], ""}
    end

    test "text around a dropped sequence survives" do
      assert Parser.parse("a\e[2~b\e[4~c") ==
               {[{:char, "a"}, {:char, "b"}, {:key, :end}, {:char, "c"}], ""}
    end

    test "ESC P is Alt+Shift+P, not the start of a DCS string (ADR-0043 §1)" do
      assert Parser.parse("\eP") == {[{:alt, ?P}], ""}
      assert Parser.parse("\ePx") == {[{:alt, ?P}, {:char, "x"}], ""}
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

    # mod-verify's review of ADR-0049: Alt+O is word forward, held down. With Caps Lock on, two
    # presses in one read were an SS3 (`ESC O ESC`) and an "O" typed; Alt+O then Down typed "[B".
    test "ESC O not followed by a final byte is Alt+Shift+O, and the rest is read again" do
      assert {[{:alt, ?O}, {:alt, ?O}], ""} = Parser.parse("\eO\eO")
      assert {[{:alt, ?O}, {:key, :down}], ""} = Parser.parse("\eO\e[B")
      assert {[{:alt, ?O}, {:key, :enter}], ""} = Parser.parse("\eO\r")
      assert {[{:alt, ?O}, {:alt, ?o}], ""} = Parser.parse("\eO\eo")
      assert {[{:alt, ?O}, {:char, "1"}], ""} = Parser.parse("\eO1")
    end

    test "an SS3 with parameter bytes is still one sequence" do
      assert Parser.parse("\eO2P") == {[], ""}
      assert {[{:key, :up}, {:key, :home}], ""} = Parser.parse("\eOA\eOH")
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
