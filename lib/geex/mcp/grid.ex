defmodule Geex.MCP.Grid do
  @moduledoc """
  The **grid command** tool surface — the agent's coordinate-addressed mirror of the human's
  `:grid` mode ([ADR-0027](../../doc/adr/0027-grid-command-addressing.md), the deferred
  agent half now built).

  A human picks coordinates off the **display ruler**, so their `x` is a *display* column the
  loop casts to a grapheme. An agent has no screen — it reads buffer *text*, so its `x` is
  already a **grapheme**. Both speak the identical `"x5 y7"` grammar (`Geex.Coord`, via the
  `:coord` / `:coord_range` argument types); only the resolution differs, and on this surface
  there is no display cast at all — `Geex.Coord.to_caret/2` and `to_span/2` resolve the agent's
  grapheme coordinates straight against the active buffer's `Geex.Buffer.Doc`.

  Members, unified by being coordinate-addressed (so they spread across the ADR-0030 categories,
  exactly as the human grid mode does):

    * **`goto`** — move the active cursor to `x y` (a *view action*: cursor only, not recorded —
      the 2-D sibling of `line`, [ADR-0030](../../doc/adr/0030-view-action-tool-category.md)).
    * **`copy`** — push the text of a coordinate **range** onto the shared clipboard ring
      ([ADR-0015](../../doc/adr/0015-clipboard-subsystem.md)) — a read with a clipboard
      side-effect, no buffer change. The ring is the *same* one the human pastes from (`Alt+V`),
      so an agent `copy` and a human paste meet on one surface.

  **Deferred** (same spirit as the human side): **`cut`** (= `copy` + a recorded `replace` over
  the range — composable from primitives the agent already has, so a dedicated atomic verb waits
  for a workflow that wants it) and a coordinate **`select`** (the live selection is loop-local;
  an agent-set selection needs a notify path that arrives with the pane model).

  Like the operation / view-action tools, each member carries a **field-spec**, so the same
  `Geex.MCP.Schema` projects its `inputSchema` and the same `Geex.Command.cast_args/2` validates
  arguments. A view action targets **the active view** (ADR-0030 §4 — multi-view waits for panes).
  """

  alias Geex.{Clipboard, Coord, Session}
  alias Geex.Buffer.Doc
  alias Geex.Command.Field
  alias Geex.MCP.Schema

  @type result :: {:ok, String.t()} | {:error, String.t()} | {:invalid_args, String.t()}
  @type spec :: %{name: String.t(), description: String.t(), fields: [Field.t()]}

  @grid_commands [
    %{
      name: "goto",
      description:
        "Move the active view's cursor to a grid coordinate. Coordinates are buffer-absolute " <>
          "graphemes (NOT display columns): x is the 1-based grapheme column, y the 1-based line. " <>
          "x past a line's end clamps to the line end; y past the last line errors. A view action: " <>
          "it moves the cursor only — not an edit, not recorded, not undoable.",
      fields: [
        %Field{
          name: :pos,
          type: :coord,
          required: true,
          description: ~s(The target coordinate, e.g. "x5 y7".)
        }
      ]
    },
    %{
      name: "copy",
      description:
        "Copy the text of a coordinate range onto the shared clipboard (the same ring the editor " <>
          "pastes from). Coordinates are buffer-absolute graphemes; the range is inclusive of both " <>
          "endpoints. Does not change the buffer.",
      fields: [
        %Field{
          name: :range,
          type: :coord_range,
          required: true,
          description: ~s(The coordinate range to copy, e.g. "x5 y7 - x12 y9".)
        }
      ]
    }
  ]

  @doc "MCP tool descriptors for every grid command — merged into the `tools/list` payload."
  @spec tools() :: [map()]
  def tools, do: Enum.map(@grid_commands, &descriptor/1)

  @doc "Look up a grid command by name."
  @spec lookup(String.t()) :: {:ok, spec()} | :error
  def lookup(name) when is_binary(name) do
    case Enum.find(@grid_commands, &(&1.name == name)) do
      nil -> :error
      command -> {:ok, command}
    end
  end

  @doc """
  Validate `args` against `command`'s field-spec and run it. Same result contract as the
  operation / view-action tools: `{:invalid_args, why}` / `{:ok, text}` / `{:error, message}`.
  """
  @spec call(spec(), map()) :: result()
  def call(%{fields: fields, name: name}, args) when is_map(args) do
    case Geex.Command.cast_args(fields, args) do
      {:error, why} -> {:invalid_args, why}
      {:ok, parsed} -> run(name, parsed)
    end
  end

  defp run("goto", %{pos: %Coord{} = coord}) do
    with {:ok, %{text: text}} <- snapshot(),
         {:ok, {line0, col0} = caret} <- Coord.to_caret(coord, Doc.new(text)) do
      Session.set_cursor(caret)
      # Report the *resolved* column, not the requested x — past-the-end x clamps to the line
      # end, and the truthful position tells the agent the line was short.
      {:ok, "cursor at line #{line0 + 1}, column #{col0 + 1}"}
    else
      {:error, :line_out_of_range} -> {:error, "line #{coord.y} is past the end of the buffer"}
      {:error, :no_active_buffer} -> {:error, ":no_active_buffer (open a file first)"}
    end
  end

  defp run("copy", %{range: %Coord.Range{} = range}) do
    with {:ok, %{text: text}} <- snapshot(),
         doc = Doc.new(text),
         {:ok, {from, to} = span} <- Coord.to_span(range, doc) do
      if from == to do
        {:error, "the range is empty (both ends clamped to the same point on a short line)"}
      else
        {:ok, copied} = Doc.slice(doc, span)
        Clipboard.push(copied)
        {:ok, "copied #{String.length(copied)} characters to the clipboard"}
      end
    else
      {:error, :line_out_of_range} -> {:error, "the range extends past the end of the buffer"}
      {:error, :no_active_buffer} -> {:error, ":no_active_buffer (open a file first)"}
    end
  end

  # Session.snapshot, narrowed to the shape `run/2` needs.
  defp snapshot do
    case Session.snapshot() do
      {:ok, %{text: text}} -> {:ok, %{text: text}}
      {:error, :no_active_buffer} -> {:error, :no_active_buffer}
    end
  end

  defp descriptor(command) do
    %{
      "name" => command.name,
      "description" => command.description,
      "inputSchema" => Schema.from_fields(command.fields)
    }
  end
end
