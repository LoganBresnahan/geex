defmodule Geex.MCP.SchemaTest do
  use ExUnit.Case, async: true

  alias Geex.Command.Field
  alias Geex.Commands.{Delete, Insert}
  alias Geex.MCP.Schema

  describe "input_schema/1 over real commands" do
    test "projects Insert's field-spec into a JSON-Schema object" do
      assert Schema.input_schema(Insert) == %{
               "type" => "object",
               "additionalProperties" => false,
               "required" => ["line", "col", "text"],
               "properties" => %{
                 "line" => %{"type" => "integer", "description" => "0-based line index"},
                 "col" => %{
                   "type" => "integer",
                   "description" => "0-based column (grapheme) index"
                 },
                 "text" => %{
                   "type" => "string",
                   "description" => "Text to insert (may contain newlines)"
                 }
               }
             }
    end

    test "a defaulted arg is NOT required (Delete.count)" do
      schema = Schema.input_schema(Delete)
      assert schema["required"] == ["line", "col"]

      assert schema["properties"]["count"] == %{
               "type" => "integer",
               "description" => "Number of graphemes to delete"
             }
    end
  end

  describe "tool/1 and tools/1 — the tools/list payload" do
    test "tool/1 yields name + description + inputSchema" do
      tool = Schema.tool(Insert)
      assert tool["name"] == "insert"
      assert tool["description"] == "Insert text at a (line, col) position"
      assert tool["inputSchema"] == Schema.input_schema(Insert)
    end

    test "tools/1 maps a list of modules" do
      assert [%{"name" => "insert"}, %{"name" => "delete"}] = Schema.tools([Insert, Delete])
    end

    test "the projected schema is valid, wire-stable JSON" do
      schema = Schema.tool(Insert)
      assert schema |> JSON.encode!() |> JSON.decode!() == schema
    end
  end

  describe "from_fields/1 — the pure projector" do
    test "type mapping covers the v0.1 scalar types" do
      fields = [
        %Field{name: :s, type: :string},
        %Field{name: :i, type: :integer},
        %Field{name: :b, type: :boolean}
      ]

      assert Schema.from_fields(fields)["properties"] == %{
               "s" => %{"type" => "string"},
               "i" => %{"type" => "integer"},
               "b" => %{"type" => "boolean"}
             }
    end

    test "a field with no description omits the description key" do
      schema = Schema.from_fields([%Field{name: :x, type: :string, description: nil}])
      assert schema["properties"]["x"] == %{"type" => "string"}
    end

    test "an empty-string description is treated as absent" do
      schema = Schema.from_fields([%Field{name: :x, type: :string, description: ""}])
      assert schema["properties"]["x"] == %{"type" => "string"}
    end

    test "required lists only non-defaulted fields, in declaration order" do
      fields = [
        %Field{name: :a, type: :string, required: true},
        %Field{name: :b, type: :integer, required: false, default: 0},
        %Field{name: :c, type: :boolean, required: true}
      ]

      assert Schema.from_fields(fields)["required"] == ["a", "c"]
    end

    test "an unknown arg type fails loudly (drift between Type and Schema)" do
      assert_raise ArgumentError,
                   ~r/no JSON-Schema mapping for command arg type :coord_range/,
                   fn ->
                     Schema.from_fields([%Field{name: :r, type: :coord_range}])
                   end
    end

    test ":edits projects to an array of {search, replace} objects" do
      schema = Schema.from_fields([%Field{name: :edits, type: :edits}])
      edits = schema["properties"]["edits"]

      assert edits["type"] == "array"
      assert edits["items"]["type"] == "object"
      assert edits["items"]["required"] == ["search", "replace"]
      assert edits["items"]["additionalProperties"] == false
      assert edits["items"]["properties"]["search"]["type"] == "string"
      assert edits["items"]["properties"]["replace"]["type"] == "string"
    end

    test "the real Edit command projects a wire-stable schema" do
      schema = Schema.tool(Geex.Commands.Edit)
      assert schema["name"] == "edit"
      assert schema["inputSchema"]["required"] == ["edits"]
      assert schema |> JSON.encode!() |> JSON.decode!() == schema
    end
  end
end
