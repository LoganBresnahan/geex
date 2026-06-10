defmodule Geex.MCP.GridTest do
  # goto/copy drive the app-global Session + Clipboard — not parallel-safe.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Clipboard, Session}
  alias Geex.MCP.Grid

  setup do
    buf = start_supervised!({Buffer, text: "hello world\nsecond line\nthird"})
    Session.set_active_buffer(buf)
    on_exit(fn -> Session.set_active_buffer(nil) end)
    %{buf: buf}
  end

  defp cursor do
    {:ok, %{cursor: cursor}} = Session.snapshot()
    cursor
  end

  defp lookup!(name) do
    {:ok, spec} = Grid.lookup(name)
    spec
  end

  describe "tools/0 — the grid descriptors (ADR-0027 agent half)" do
    test "exposes goto (a :coord) and copy (a :coord_range), schema-projected as strings" do
      names = Grid.tools() |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["copy", "goto"]

      goto = Enum.find(Grid.tools(), &(&1["name"] == "goto"))
      assert goto["inputSchema"]["required"] == ["pos"]
      assert goto["inputSchema"]["properties"]["pos"]["type"] == "string"

      copy = Enum.find(Grid.tools(), &(&1["name"] == "copy"))
      assert copy["inputSchema"]["required"] == ["range"]
      assert copy["inputSchema"]["properties"]["range"]["type"] == "string"
    end
  end

  describe "goto — move the cursor by grapheme coordinate" do
    test "1-based x/y land the cursor at the 0-based caret" do
      assert {:ok, msg} = Grid.call(lookup!("goto"), %{"pos" => "x3 y2"})
      assert cursor() == {1, 2}
      assert msg =~ "line 2"
    end

    test "x past the line end clamps to the line end, and the message reports the resolved column" do
      # "third" (line 3) is 5 graphemes; x99 clamps to col 5 (1-based column 6 caret-after-end)
      assert {:ok, msg} = Grid.call(lookup!("goto"), %{"pos" => "x99 y3"})
      assert cursor() == {2, 5}
      assert msg =~ "column 6"
    end

    test "y past the last line is a clean error (isError-shaped), not a crash" do
      assert {:error, msg} = Grid.call(lookup!("goto"), %{"pos" => "x1 y9"})
      assert msg =~ "past the end"
    end

    test "a range where a point is wanted is an invalid-args error" do
      assert {:invalid_args, why} = Grid.call(lookup!("goto"), %{"pos" => "x1 y1 - x2 y1"})
      assert why =~ "single coordinate"
    end
  end

  describe "copy — push a coordinate range onto the shared clipboard" do
    test "copies the inclusive range text to the clipboard ring" do
      assert {:ok, msg} = Grid.call(lookup!("copy"), %{"range" => "x1 y1 - x5 y1"})
      assert Clipboard.top() == "hello"
      assert msg =~ "5 characters"
    end

    test "a multi-line range copies across the newline" do
      assert {:ok, _} = Grid.call(lookup!("copy"), %{"range" => "x7 y1 - x6 y2"})
      assert Clipboard.top() == "world\nsecond"
    end

    test "copy does not move the cursor or change the buffer" do
      before_cursor = cursor()
      {:ok, %{text: before_text}} = Session.snapshot()
      assert {:ok, _} = Grid.call(lookup!("copy"), %{"range" => "x1 y1 - x5 y1"})
      assert cursor() == before_cursor
      assert {:ok, %{text: ^before_text}} = Session.snapshot()
    end

    test "a range that collapses on a short line is a clean error, not an empty copy" do
      # line 3 "third" is 5 graphemes; x8-x12 both clamp to the end -> collapsed
      assert {:error, msg} = Grid.call(lookup!("copy"), %{"range" => "x8 y3 - x12 y3"})
      assert msg =~ "empty"
    end

    test "a point where a range is wanted is an invalid-args error" do
      assert {:invalid_args, why} = Grid.call(lookup!("copy"), %{"range" => "x1 y1"})
      assert why =~ "range"
    end
  end
end
