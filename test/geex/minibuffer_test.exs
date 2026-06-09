defmodule Geex.MinibufferTest do
  use ExUnit.Case, async: true

  alias Geex.Minibuffer

  test "new/0 is inactive; open/1 activates it empty" do
    assert Minibuffer.active?(Minibuffer.new()) == false
    mb = Minibuffer.open(:command)
    assert Minibuffer.active?(mb)
    assert Minibuffer.value(mb) == ""
    assert mb.cursor == 0
    assert Minibuffer.prompt(mb) == ":"
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
end
