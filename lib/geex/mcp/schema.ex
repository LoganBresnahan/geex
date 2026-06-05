defmodule Geex.MCP.Schema do
  @moduledoc """
  Projects a command's neutral field-spec into an MCP **tool descriptor** — the
  `tools/list` payload, for free, with no hand-sync (ADR-0004,
  mcp-ai-integration.md §3a / §4).

  This is the first `Geex.MCP.*` module and the JSON-Schema **renderer** the
  field-spec was designed for: `Geex.Command` emits a list of
  `Geex.Command.Field` from one `arg` block, and this module is the *only* place
  that knows how those map to JSON-Schema. Because the schema, the parser
  (`parse/1`), and the struct all derive from that one list, they cannot drift —
  geex structurally avoids pharos's most-cited bug.

  Output is plain maps with **string keys**, matching the MCP wire shape
  (`name` / `description` / `inputSchema`, the last a JSON-Schema object). It is
  pure and dependency-free — `Geex.MCP.Protocol` and the transport layers consume
  it; nothing here touches a process or a socket.
  """

  alias Geex.Command.Field

  @doc "MCP tool descriptors for a list of command modules — the `tools/list` payload."
  @spec tools([module()]) :: [map()]
  def tools(modules) when is_list(modules), do: Enum.map(modules, &tool/1)

  @doc """
  The MCP tool descriptor for one command module: `name`, `description`, and the
  `inputSchema` projected from its field-spec.
  """
  @spec tool(module()) :: map()
  def tool(module) when is_atom(module) do
    info = module.__command__()

    %{
      "name" => to_string(info.name),
      "description" => info.description,
      "inputSchema" => input_schema(module)
    }
  end

  @doc """
  Project `module`'s field-spec into a JSON-Schema object (the MCP `inputSchema`):
  an `object` whose `properties` are the args, with the required (non-defaulted)
  args listed and `additionalProperties` disallowed.
  """
  @spec input_schema(module()) :: map()
  def input_schema(module) when is_atom(module), do: from_fields(module.__fields__())

  @doc "The pure projector: a list of `Geex.Command.Field` → a JSON-Schema object."
  @spec from_fields([Field.t()]) :: map()
  def from_fields(fields) when is_list(fields) do
    properties = Map.new(fields, fn %Field{} = f -> {to_string(f.name), property(f)} end)
    required = for %Field{required: true} = f <- fields, do: to_string(f.name)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp property(%Field{} = f) do
    schema = json_type(f.type)

    case f.description do
      desc when is_binary(desc) and desc != "" -> Map.put(schema, "description", desc)
      _ -> schema
    end
  end

  # The JSON-Schema row for each Geex.Command.Type — the mapping Type's moduledoc
  # anticipates. Unknown types fail loudly: a type added to Geex.Command.Type
  # without a row here is a bug we want surfaced, not silently rendered as "any".
  defp json_type(:string), do: %{"type" => "string"}
  defp json_type(:integer), do: %{"type" => "integer"}
  defp json_type(:boolean), do: %{"type" => "boolean"}

  # The `edit` tool's search/replace array (ADR-0020): an array of objects, each with
  # the verbatim text to find and its replacement.
  defp json_type(:edits) do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "search" => %{
            "type" => "string",
            "description" =>
              "Exact text to find, quoted verbatim from the buffer with a few lines of " <>
                "surrounding context so it is unique."
          },
          "replace" => %{
            "type" => "string",
            "description" => "The new text to put in its place (empty to delete)."
          },
          "description" => %{
            "type" => "string",
            "description" => "Optional summary of this block's change."
          }
        },
        "required" => ["search", "replace"],
        "additionalProperties" => false
      }
    }
  end

  defp json_type(other) do
    raise ArgumentError,
          "no JSON-Schema mapping for command arg type #{inspect(other)} — " <>
            "add a clause to Geex.MCP.Schema.json_type/1 (and Geex.Command.Type.cast/2)"
  end
end
