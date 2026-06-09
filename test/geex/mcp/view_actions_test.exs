defmodule Geex.MCP.ViewActionsTest do
  # line/1 drives the app-global Session — not parallel-safe.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Session}
  alias Geex.MCP.ViewActions

  setup do
    buf = start_supervised!({Buffer, text: "one\ntwo\nthree\nfour"})
    Session.set_active_buffer(buf)
    on_exit(fn -> Session.set_active_buffer(nil) end)
    %{buf: buf}
  end

  defp cursor do
    {:ok, %{cursor: cursor}} = Session.snapshot()
    cursor
  end

  describe "tools/0 — the view-action descriptors (the fourth category, ADR-0030)" do
    test "exposes `line` with a field-spec-projected schema" do
      assert [%{"name" => "line", "inputSchema" => schema}] = ViewActions.tools()
      assert schema["required"] == ["line"]
      assert schema["properties"]["line"]["type"] == "integer"
    end
  end

  describe "line/1 — the one shared go-to-line resolution" do
    test "1-based: line 3 puts the cursor at the start of the third line" do
      assert {:ok, {2, 0}} = ViewActions.line(3)
      assert cursor() == {2, 0}
    end

    test "0 jumps to the last line" do
      assert {:ok, {3, 0}} = ViewActions.line(0)
      assert cursor() == {3, 0}
    end

    test "past the end clamps to the last line" do
      assert {:ok, {3, 0}} = ViewActions.line(99)
      assert cursor() == {3, 0}
    end

    test "negative is rejected without touching the cursor" do
      ViewActions.line(2)
      assert {:error, :negative_line} = ViewActions.line(-1)
      assert cursor() == {1, 0}
    end

    test "no active buffer is a clean error" do
      Session.set_active_buffer(nil)
      assert {:error, :no_active_buffer} = ViewActions.line(1)
    end
  end

  describe "call/2 — the tools/call surface" do
    test "valid args move the cursor and report the landing" do
      {:ok, action} = ViewActions.lookup("line")
      assert {:ok, "cursor at line 2, column 1"} = ViewActions.call(action, %{"line" => 2})
      assert cursor() == {1, 0}
    end

    test "missing/badly-typed args are invalid_args (the SEP-1303 self-correction path)" do
      {:ok, action} = ViewActions.lookup("line")
      assert {:invalid_args, _} = ViewActions.call(action, %{})
      assert {:invalid_args, _} = ViewActions.call(action, %{"line" => "three"})
    end

    test "a negative line is a clean error message" do
      {:ok, action} = ViewActions.lookup("line")
      assert {:error, message} = ViewActions.call(action, %{"line" => -2})
      assert message =~ "0 jumps to the last line"
    end

    test "lookup of an unknown view action is :error" do
      assert :error = ViewActions.lookup("scroll")
    end
  end
end
