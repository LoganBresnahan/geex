defmodule Geex.Command do
  @moduledoc """
  The command DSL: one macro block generates everything (ADR-0002, ADR-0004,
  mcp-ai-integration.md §3a/§4).

  A command module `use`s `Geex.Command` and declares one `command` block. From
  that single block the macro generates:

    * a **struct** with the declared arg fields plus `:meta` (provenance) —
      the command *is a value* (ADR-0002);
    * `__fields__/0` — the **neutral field-spec** (`[Geex.Command.Field.t()]`),
      from which renderers project the parser, the validator, and (later) the
      MCP JSON-Schema (ADR-0004);
    * `__command__/0` — `%{name, module, description}` for the registry;
    * `parse/1` — coerce an args map (string- or atom-keyed) into the struct,
      the **one parser** the minibuffer and an MCP tool-call both use (§1);
    * `run/2` — the body from the `run` block, `run(command, doc) -> {:ok, doc}
      | {:error, reason}`.

  ## Example

      defmodule Geex.Commands.Insert do
        use Geex.Command

        command :insert do
          description "Insert text at a position"
          arg :line, :integer, description: "0-based line"
          arg :col,  :integer, description: "0-based column"
          arg :text, :string,  description: "Text to insert"

          run cmd, doc do
            Geex.Buffer.Doc.insert(doc, {cmd.line, cmd.col}, cmd.text)
          end
        end
      end

  Because the schema, parser, and struct are all generated from the one `arg`
  list, they cannot drift — geex structurally avoids pharos's most-cited bug.
  """

  alias Geex.Command.{Field, Meta, Type}

  defmacro __using__(_opts) do
    quote do
      import Geex.Command, only: [command: 2, arg: 2, arg: 3, description: 1, run: 3]
      Module.register_attribute(__MODULE__, :geex_args, accumulate: true)
      @geex_command_desc ""
      @before_compile Geex.Command
    end
  end

  @doc "Open a command definition named `name`; the block holds `arg`/`description`/`run`."
  defmacro command(name, do: block) do
    quote do
      @geex_command_name unquote(name)
      unquote(block)
    end
  end

  @doc "Declare an argument: `arg :name, :type, description: \"...\", default: ...`."
  defmacro arg(name, type, opts \\ []) do
    quote bind_quoted: [name: name, type: type, opts: opts] do
      @geex_args %Field{
        name: name,
        type: type,
        required: not Keyword.has_key?(opts, :default),
        default: Keyword.get(opts, :default),
        description: Keyword.get(opts, :description, "")
      }
    end
  end

  @doc "Set the command's human/LLM-facing description."
  defmacro description(text) do
    quote do: @geex_command_desc(unquote(text))
  end

  @doc "Define the runner: `run command_pattern, doc_pattern do ... end`."
  defmacro run(cmd_pattern, doc_pattern, do: body) do
    quote do
      def run(unquote(cmd_pattern), unquote(doc_pattern)), do: unquote(body)
    end
  end

  defmacro __before_compile__(env) do
    fields = env.module |> Module.get_attribute(:geex_args) |> Enum.reverse()
    name = Module.get_attribute(env.module, :geex_command_name)
    desc = Module.get_attribute(env.module, :geex_command_desc) || ""
    struct_fields = [:meta | Enum.map(fields, & &1.name)]
    escaped_fields = Macro.escape(fields)

    quote do
      defstruct unquote(struct_fields)

      @doc false
      def __command__, do: %{name: unquote(name), module: __MODULE__, description: unquote(desc)}

      @doc false
      def __fields__, do: unquote(escaped_fields)

      @doc "Coerce an args map (string- or atom-keyed) into a `#{inspect(__MODULE__)}` struct."
      def parse(args) when is_map(args),
        do: Geex.Command.__parse__(__MODULE__, unquote(escaped_fields), args)
    end
  end

  @doc false
  @spec __parse__(module(), [Field.t()], map()) :: {:ok, struct()} | {:error, String.t()}
  def __parse__(module, fields, args) when is_map(args) do
    result =
      Enum.reduce_while(fields, {:ok, %{}}, fn %Field{} = f, {:ok, acc} ->
        case fetch_arg(args, f.name) do
          :__missing__ when f.required ->
            {:halt, {:error, "missing required arg: #{f.name}"}}

          :__missing__ ->
            {:cont, {:ok, Map.put(acc, f.name, f.default)}}

          raw ->
            case Type.cast(f.type, raw) do
              {:ok, val} -> {:cont, {:ok, Map.put(acc, f.name, val)}}
              {:error, why} -> {:halt, {:error, "arg #{f.name}: #{why}"}}
            end
        end
      end)

    case result do
      {:ok, map} -> {:ok, struct(module, map)}
      {:error, _} = e -> e
    end
  end

  @doc "Stamp provenance onto a command value (ADR-0005)."
  @spec put_meta(struct(), Meta.t()) :: struct()
  def put_meta(cmd, %Meta{} = meta) when is_struct(cmd), do: %{cmd | meta: meta}

  defp fetch_arg(args, name) do
    cond do
      Map.has_key?(args, name) -> Map.get(args, name)
      Map.has_key?(args, Atom.to_string(name)) -> Map.get(args, Atom.to_string(name))
      true -> :__missing__
    end
  end
end
