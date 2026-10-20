defmodule Geex.Loop.VerbsTest do
  use ExUnit.Case, async: true

  alias Geex.Loop.Verbs

  describe "parse/1 — go-to-line (ADR-0030 `line` view action + bare-number sugar)" do
    test "a bare number and `line N` parse the same" do
      assert Verbs.parse("42") == {:line, 42}
      assert Verbs.parse("line 42") == {:line, 42}
    end

    test "0 is the jump-to-last-line convention" do
      assert Verbs.parse("0") == {:line, 0}
      assert Verbs.parse("line 0") == {:line, 0}
    end

    test "whitespace is tolerated" do
      assert Verbs.parse("  7  ") == {:line, 7}
      assert Verbs.parse("line   7") == {:line, 7}
    end

    test "negative, trailing-junk, and malformed numbers are unknown" do
      assert Verbs.parse("-3") == :unknown
      assert Verbs.parse("line -3") == :unknown
      assert Verbs.parse("4 5") == :unknown
      assert Verbs.parse("line4") == :unknown
      assert Verbs.parse("line") == :unknown
    end

    test "signed numbers are rejected, not interpreted (`-0` must not mean last-line)" do
      assert Verbs.parse("-0") == :unknown
      assert Verbs.parse("+5") == :unknown
      assert Verbs.parse("+0") == :unknown
      assert Verbs.parse("line +5") == :unknown
      assert Verbs.parse("line -0") == :unknown
    end
  end

  describe "parse/1 — the verb twins of the chords (ADR-0028 parity)" do
    test "clipboard verbs (= Alt+C/X/V)" do
      assert Verbs.parse("copy") == {:action, :copy}
      assert Verbs.parse("cut") == {:action, :cut}
      assert Verbs.parse("paste") == {:action, :paste}
    end

    test "history operations (= Alt+Z / Alt+Shift+Z, ADR-0031)" do
      assert Verbs.parse("undo") == {:action, :undo}
      assert Verbs.parse("redo") == {:action, :redo}
    end

    test "selection verbs (= Alt+H / Alt+B, ADR-0029)" do
      assert Verbs.parse("highlight") == {:action, :select_start}
      assert Verbs.parse("select") == {:action, :select_start}
      assert Verbs.parse("highlight all") == {:action, :select_all}
      assert Verbs.parse("select all") == {:action, :select_all}
    end

    test "save (= Ctrl-O) and quit/exit (= Ctrl-X)" do
      assert Verbs.parse("save") == {:action, :save}
      assert Verbs.parse("quit") == {:action, :quit}
      assert Verbs.parse("exit") == {:action, :quit}
    end

    test "verbs are case-insensitive" do
      assert Verbs.parse("COPY") == {:action, :copy}
      assert Verbs.parse("Line 3") == {:line, 3}
    end
  end

  describe "parse_grid/1 — grid-mode coordinate commands (ADR-0027)" do
    alias Geex.Coord

    test "copy/cut take a range" do
      assert {:copy, %Coord.Range{from: %Coord{x: 5, y: 7}, to: %Coord{x: 12, y: 9}}} =
               Verbs.parse_grid("copy x5 y7 - x12 y9")

      assert {:cut, %Coord.Range{}} = Verbs.parse_grid("cut x1 y1 - x3 y1")
    end

    test "goto and a bare coordinate both jump to a single coordinate" do
      assert {:goto, %Coord{x: 5, y: 7}} = Verbs.parse_grid("goto x5 y7")
      assert {:goto, %Coord{x: 5, y: 7}} = Verbs.parse_grid("x5 y7")
    end

    test "the wrong shape for the verb is unknown" do
      # copy needs a range, not a single coord
      assert Verbs.parse_grid("copy x5 y7") == :unknown
      # goto needs a single coord, not a range
      assert Verbs.parse_grid("goto x5 y7 - x9 y7") == :unknown
    end

    test "reversed / empty / malformed coordinates are unknown" do
      assert Verbs.parse_grid("copy x9 y1 - x2 y1") == :unknown
      assert Verbs.parse_grid("copy x5 y7 - x5 y7") == :unknown
      assert Verbs.parse_grid("frob") == :unknown
    end

    test "`no` / empty cancels" do
      assert Verbs.parse_grid("no") == :cancel
      assert Verbs.parse_grid("") == :cancel
    end
  end

  describe "parse/1 — cancel and unknown" do
    test "`no` is the true Alt+N twin (clears a selection); an empty line cancels" do
      assert Verbs.parse("no") == {:action, :select_clear}
      assert Verbs.parse("") == :cancel
      assert Verbs.parse("   ") == :cancel
    end

    test "anything else is unknown (a no-op until the catalog backs the parser)" do
      assert Verbs.parse("frobnicate") == :unknown
      assert Verbs.parse("copy that") == :unknown
    end
  end

  describe "parse/1 — the file operations (ADR-0019's 2026-10-19 amendment)" do
    doctest Geex.Loop.Verbs

    test "new, mkdir and rename/mv take a path, which keeps its case and spaces" do
      assert Verbs.parse("new lib/My File.ex") == {:new, "lib/My File.ex"}
      assert Verbs.parse("NEW  README.md ") == {:new, "README.md"}
      assert Verbs.parse("mkdir Docs/") == {:mkdir, "Docs"}
      assert Verbs.parse("rename lib/B.ex") == {:rename, "lib/B.ex"}
      assert Verbs.parse("mv ~/x.txt") == {:rename, "~/x.txt"}
    end

    test "new with a trailing / makes a directory; / alone is still a path" do
      assert Verbs.parse("new a/b/") == {:mkdir, "a/b"}
      assert Verbs.parse("new /") == {:mkdir, "/"}
    end

    test "delete and a bare rename/mv act on the current file; a bare new or mkdir is unknown" do
      assert Verbs.parse("delete") == {:action, :delete_file}
      assert Verbs.parse("rename") == {:action, :rename_file}
      assert Verbs.parse("mv") == {:action, :rename_file}
      assert Verbs.parse("new") == :unknown
      assert Verbs.parse("mkdir") == :unknown
      assert Verbs.parse("delete it") == :unknown
    end
  end
end
