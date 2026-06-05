defmodule Geex.MCP.Operations do
  @moduledoc """
  The **operation tool** surface — the third MCP tool category (ADR-0019).

  The MCP server exposes three kinds of tool:

    * **edit tools** (`insert`/`delete`/`replace`) — macro-projected from the
      field-spec, routed through `Geex.Dispatch.run/1` into the undo history;
    * **read tools** — the read-only query surface (§15b);
    * **operation tools** (`open_file`/`save_file`) — *this module*: hand-written
      handlers that act on `Geex.Session` / disk and are **not** recorded as edits
      (you don't "undo a save"; loading is not a content mutation — ADR-0003).

  Operation tools are not commands: they have no `%Command{}`, never reach
  `Geex.Dispatch`, and never enter a buffer's history. But they still carry a
  **field-spec** (`[Geex.Command.Field.t()]`), so the same `Geex.MCP.Schema`
  renderer projects their `inputSchema` for `tools/list` (no hand-synced JSON), and
  the same `Geex.Command.cast_args/2` validates their arguments (same required /
  cast rules as edit tools — ADR-0004).

  `Geex.MCP.Protocol` routes a `tools/call` to an operation when `lookup/1` matches,
  and turns `call/2`'s result into a tool result. This module is otherwise free of
  protocol/frame knowledge — it returns plain `{:ok, text}` / `{:error, message}` /
  `{:invalid_args, why}`.
  """

  alias Geex.{Buffer, Session}
  alias Geex.Command.Field
  alias Geex.MCP.Schema

  @type result :: {:ok, String.t()} | {:error, String.t()} | {:invalid_args, String.t()}
  @type spec :: %{name: String.t(), description: String.t(), fields: [Field.t()]}

  @operations [
    %{
      name: "open_file",
      description:
        "Open a file by path, load-or-reuse its buffer, and make it the active buffer. " <>
          "Subsequent edits target it. Returns the buffer's current text. Not an edit " <>
          "(does not enter the undo history).",
      fields: [
        %Field{
          name: :path,
          type: :string,
          required: true,
          description: "Path to the file to open (created on first save if it does not exist)"
        }
      ]
    },
    %{
      name: "save_file",
      description:
        "Write the active buffer's current text back to its file on disk and clear the " <>
          "dirty flag. Not an edit (does not enter the undo history).",
      fields: []
    }
  ]

  @doc "MCP tool descriptors for every operation tool — merged into the `tools/list` payload."
  @spec tools() :: [map()]
  def tools, do: Enum.map(@operations, &descriptor/1)

  @doc "Look up an operation tool by name."
  @spec lookup(String.t()) :: {:ok, spec()} | :error
  def lookup(name) when is_binary(name) do
    case Enum.find(@operations, &(&1.name == name)) do
      nil -> :error
      op -> {:ok, op}
    end
  end

  @doc """
  Validate `args` against `op`'s field-spec and run the operation.

  Returns `{:invalid_args, why}` (bad/missing args — the protocol surfaces this as an
  `isError` tool result so the model self-corrects, SEP-1303), `{:ok, text}` on
  success, or `{:error, message}` on a clean operation failure (no path, no active
  buffer, a posix write error). A dependency process being *down* is not handled here
  — it raises/exits and the protocol boundary contains it as `-32603`.
  """
  @spec call(spec(), map()) :: result()
  def call(%{fields: fields, name: name}, args) when is_map(args) do
    case Geex.Command.cast_args(fields, args) do
      {:error, why} -> {:invalid_args, why}
      {:ok, parsed} -> run(name, parsed)
    end
  end

  defp run("open_file", %{path: path}) do
    case Session.open_file(path) do
      {:ok, pid} -> {:ok, Buffer.get_text(pid)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp run("save_file", _args) do
    case Session.active_buffer() do
      {:ok, pid} ->
        # Buffer.save/1 returns the path it wrote, so the confirmation needs no second
        # round-trip (and no window where a successful save reports as an error).
        case Buffer.save(pid) do
          {:ok, path} -> {:ok, "saved #{path}"}
          {:error, reason} -> {:error, inspect(reason)}
        end

      :error ->
        {:error, ":no_active_buffer"}
    end
  end

  defp descriptor(op) do
    %{
      "name" => op.name,
      "description" => op.description,
      "inputSchema" => Schema.from_fields(op.fields)
    }
  end
end
