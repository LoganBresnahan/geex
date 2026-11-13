defmodule Geex.MinibufferTest do
  use ExUnit.Case, async: true

  alias Geex.Minibuffer

  doctest Geex.Minibuffer

  test "ask/3 opens :confirm or :ask with its question as the prompt; close forgets it" do
    mb = Minibuffer.ask(:ask, "rename a.ex to: ", "a.ex")
    assert Minibuffer.active?(mb)

    assert {Minibuffer.prompt(mb), Minibuffer.value(mb), mb.cursor} ==
             {"rename a.ex to: ", "a.ex", 4}

    assert Minibuffer.close(mb).ask == nil
  end

  test "new/0 is inactive; open/1 activates it empty" do
    assert Minibuffer.active?(Minibuffer.new()) == false
    mb = Minibuffer.open(:command)
    assert Minibuffer.active?(mb)
    assert Minibuffer.value(mb) == ""
    assert mb.cursor == 0
    assert Minibuffer.prompt(mb) == "geex:"
  end

  test "the grid mode prompt is the colon-suffixed label" do
    assert Minibuffer.open(:grid) |> Minibuffer.prompt() == "grid:"
  end

  test "the palette mode prompt is the colon-suffixed label" do
    assert Minibuffer.open(:palette) |> Minibuffer.prompt() == "palette:"
  end

  test "open/2 pre-fills the input with the cursor at its end" do
    mb = Minibuffer.open(:command, "line ")
    assert Minibuffer.value(mb) == "line "
    assert mb.cursor == 5
  end

  test "editing the input resets the palette highlight to the top match" do
    mb = Minibuffer.open(:palette) |> Minibuffer.select(3)
    assert mb.sel == 3
    assert Minibuffer.insert(mb, "c").sel == 0

    assert Minibuffer.open(:palette)
           |> Minibuffer.select(2)
           |> Minibuffer.insert("x")
           |> Map.fetch!(:sel) == 0
  end

  test "backspace also resets the palette highlight" do
    mb = Minibuffer.open(:palette, "cop") |> Minibuffer.select(2)
    assert Minibuffer.backspace(mb).sel == 0
  end

  test "close/1 deactivates" do
    assert Minibuffer.open(:command) |> Minibuffer.close() |> Minibuffer.active?() == false
  end

  test "insert/2 types at the cursor and advances it" do
    mb = Minibuffer.open(:command) |> Minibuffer.insert("4") |> Minibuffer.insert("2")
    assert Minibuffer.value(mb) == "42"
    assert mb.cursor == 2
  end

  test "left/right move the cursor; insert lands mid-string" do
    mb =
      Minibuffer.open(:command)
      |> Minibuffer.insert("a")
      |> Minibuffer.insert("c")
      |> Minibuffer.left()
      |> Minibuffer.insert("b")

    assert Minibuffer.value(mb) == "abc"
    assert mb.cursor == 2
  end

  test "right clamps at the end, left clamps at the start" do
    mb = Minibuffer.open(:command) |> Minibuffer.insert("x")
    assert Minibuffer.right(mb).cursor == 1
    assert mb |> Minibuffer.left() |> Minibuffer.left() |> Map.fetch!(:cursor) == 0
  end

  test "backspace deletes before the cursor; a no-op at the start" do
    mb = Minibuffer.open(:command) |> Minibuffer.insert("a") |> Minibuffer.insert("b")
    assert mb |> Minibuffer.backspace() |> Minibuffer.value() == "a"
    assert Minibuffer.open(:command) |> Minibuffer.backspace() |> Minibuffer.value() == ""
  end

  test "backspace removes the grapheme before the cursor, not the last one" do
    mb =
      Minibuffer.open(:command)
      |> Minibuffer.insert("a")
      |> Minibuffer.insert("b")
      |> Minibuffer.insert("c")
      |> Minibuffer.left()
      |> Minibuffer.backspace()

    assert Minibuffer.value(mb) == "ac"
    assert mb.cursor == 1
  end

  describe "bytes that aren't UTF-8 (ADR-0053's 2026-11-13 amendment, mod-verify's R1)" do
    # A © right before a Latin-1 é is where String.graphemes/1 raises (BUG-15); a search pre-filled
    # from a selection in a Latin-1 file holds exactly that.
    @bad "©" <> <<0xE9>> <> "x"

    test "a pre-fill holding them opens, edits and moves without raising" do
      mb = Minibuffer.open(:command, @bad)
      assert {Minibuffer.value(mb), mb.cursor} == {@bad, 3}

      mb = mb |> Minibuffer.left() |> Minibuffer.insert("y")
      assert Minibuffer.value(mb) == "©" <> <<0xE9>> <> "yx"
      mb = Minibuffer.backspace(mb)
      assert Minibuffer.value(mb) == @bad
      mb = mb |> Minibuffer.backspace() |> Minibuffer.right() |> Minibuffer.right()
      assert {Minibuffer.value(mb), mb.cursor} == {"©x", 2}
    end

    test "right steps over the pair while it is still there" do
      mb = Minibuffer.open(:command, @bad) |> Minibuffer.left() |> Minibuffer.left()
      assert mb.cursor == 1
      mb = Minibuffer.right(mb)
      assert {Minibuffer.value(mb), mb.cursor} == {@bad, 2}
      assert Minibuffer.right(Minibuffer.right(mb)).cursor == 3
    end

    test "typing such a byte after an emoji, and deleting it" do
      mb = Minibuffer.open(:command, "👍") |> Minibuffer.insert(<<0xFF>>)
      assert {Minibuffer.value(mb), mb.cursor} == {"👍" <> <<0xFF>>, 2}
      assert Minibuffer.value(Minibuffer.backspace(mb)) == "👍"
    end
  end

  test "a pre-fill is cut at 4,096 graphemes, as a paste is" do
    mb = Minibuffer.open(:command, String.duplicate("é", 5_000))
    assert {Geex.Text.length(Minibuffer.value(mb)), mb.cursor} == {4096, 4096}
  end
end
