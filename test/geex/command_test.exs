defmodule Geex.CommandTest do
  use ExUnit.Case, async: true
  doctest Geex.Command.Meta

  alias Geex.Command.Field
  alias Geex.Commands.{Delete, Insert}

  describe "macro generates the command surface" do
    test "__command__/0 carries name, module, description" do
      assert %{name: :insert, module: Geex.Commands.Insert, description: desc} =
               Insert.__command__()

      assert is_binary(desc) and desc != ""
    end

    test "__fields__/0 is the neutral field-spec in declaration order" do
      assert [%Field{name: :line, type: :integer, required: true}, %Field{name: :col}, %Field{name: :text, type: :string}] =
               Insert.__fields__()
    end

    test "a defaulted arg is optional in the field-spec" do
      count = Enum.find(Delete.__fields__(), &(&1.name == :count))
      assert %Field{required: false, default: 1} = count
    end

    test "the struct has the arg fields plus :meta" do
      cmd = %Insert{}
      assert Map.keys(cmd) |> Enum.sort() == [:__struct__, :col, :line, :meta, :text]
      assert cmd.meta == nil
    end
  end

  describe "parse/1 (the one parser; minibuffer and MCP share it)" do
    test "casts string-keyed args (the MCP shape)" do
      assert {:ok, %Insert{line: 0, col: 5, text: "hi", meta: nil}} =
               Insert.parse(%{"line" => "0", "col" => "5", "text" => "hi"})
    end

    test "accepts atom-keyed args (the internal shape)" do
      assert {:ok, %Insert{line: 1, col: 2, text: "x"}} =
               Insert.parse(%{line: 1, col: 2, text: "x"})
    end

    test "applies defaults for absent optional args" do
      assert {:ok, %Delete{line: 1, col: 2, count: 1}} =
               Delete.parse(%{"line" => "1", "col" => "2"})
    end

    test "errors on a missing required arg" do
      assert {:error, "missing required arg: text"} =
               Insert.parse(%{"line" => "0", "col" => "0"})
    end

    test "errors with the arg name on a bad cast" do
      assert {:error, "arg line: " <> _} = Insert.parse(%{"line" => "abc", "col" => "0", "text" => "x"})
    end
  end
end
