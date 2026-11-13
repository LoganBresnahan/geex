defmodule Geex.CommandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  doctest Geex.Command.Meta

  alias Geex.{CommandRegistry, Gen}
  alias Geex.Command.Field
  alias Geex.Commands.{Delete, Insert}

  describe "macro generates the command surface" do
    test "__command__/0 carries name, module, description" do
      assert %{name: :insert, module: Geex.Commands.Insert, description: desc} =
               Insert.__command__()

      assert is_binary(desc) and desc != ""
    end

    test "__fields__/0 is the neutral field-spec in declaration order" do
      assert [
               %Field{name: :line, type: :integer, required: true},
               %Field{name: :col},
               %Field{name: :text, type: :string}
             ] =
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
      assert {:error, "arg line: " <> _} =
               Insert.parse(%{"line" => "abc", "col" => "0", "text" => "x"})
    end
  end

  # ADR-0044 §8.3, testing.md's layer-2 promise (§1): `parse/1` is the one parser every surface
  # uses, so the same arguments parse to the same struct whichever form they arrive in: native
  # values under atom keys (the keymap builds commands so), the raw strings a typed surface hands
  # over, and JSON as an MCP `tools/call` delivers it (string keys, decoded scalars). Over every
  # registered command; a new argument type without a generator below fails here, by name.
  property "every command parses native, raw-string and JSON arguments to one struct" do
    modules = Enum.map(CommandRegistry.all(), & &1.module)
    assert modules != []

    check all(module <- member_of(modules), values <- args_for(module.__fields__())) do
      expected =
        struct(module, Map.new(module.__fields__(), &{&1.name, expected(&1, values)}))

      assert module.parse(values) == {:ok, expected}

      json =
        values
        |> Map.new(fn {name, value} -> {Atom.to_string(name), json_value(value)} end)
        |> JSON.encode!()
        |> JSON.decode!()

      assert module.parse(json) == {:ok, expected}

      # an array has no typed form; every scalar does
      unless Enum.any?(values, fn {_name, value} -> is_list(value) end) do
        raw = Map.new(values, fn {name, value} -> {name, raw_string(value)} end)
        assert module.parse(raw) == {:ok, expected}
      end
    end
  end

  # A value for every required field, and for each optional one, sometimes.
  defp args_for(fields) do
    fields
    |> Enum.map(fn %Field{} = f ->
      value = map(value_for(f.type), &{f.name, &1})
      if f.required, do: value, else: one_of([constant(nil), value])
    end)
    |> fixed_list()
    |> map(fn pairs -> pairs |> Enum.reject(&is_nil/1) |> Map.new() end)
  end

  defp value_for(:integer), do: integer()

  # JSON strings are UTF-8 by definition, so an argument that round-trips through an MCP call's JSON
  # can't hold an invalid byte: `invalid: false` (ADR-0044's 2026-11-12 amendment).
  defp value_for(:string), do: Gen.text(invalid: false)
  defp value_for(:boolean), do: boolean()

  defp value_for(:edits) do
    block =
      gen all(
            search <- Gen.text(invalid: false),
            replace <- Gen.text(invalid: false),
            description <- one_of([constant(nil), Gen.text(invalid: false)])
          ) do
        %{search: search, replace: replace, description: description}
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
      end

    list_of(block, min_length: 1, max_length: 3)
  end

  defp value_for(type), do: raise("no generator for argument type #{inspect(type)}: add one here")

  # What the parsed struct holds: the value given (an edit block's missing description as ""),
  # or the field's default.
  defp expected(%Field{name: name, default: default}, values) do
    case Map.fetch(values, name) do
      {:ok, blocks} when is_list(blocks) -> Enum.map(blocks, &Map.put_new(&1, :description, ""))
      {:ok, value} -> value
      :error -> default
    end
  end

  defp json_value(blocks) when is_list(blocks),
    do: Enum.map(blocks, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))

  defp json_value(value), do: value

  defp raw_string(value) when is_integer(value), do: Integer.to_string(value)
  defp raw_string(value) when is_boolean(value), do: to_string(value)
  defp raw_string(value) when is_binary(value), do: value
end
