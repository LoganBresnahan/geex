defmodule Geex.MCP.ViewActions do
  @moduledoc """
  The **view-action tool** surface — the fourth MCP tool category
  ([ADR-0030](../../doc/adr/0030-view-action-tool-category.md)).

  View actions mutate **view-local, ephemeral** state — the cursor (and later
  scroll / a coordinate-built selection) — and are therefore *not* recorded:
  no `%Command{}`, never through `Geex.Dispatch`, never in a buffer's history
  (moving the cursor is not an edit, ADR-0014). Like the operation tools they
  carry a **field-spec**, so the same `Geex.MCP.Schema` projects their
  `inputSchema` into `tools/list` and the same `Geex.Command.cast_args/2`
  validates their arguments.

  First member: **`line`** (go-to-line) — which retires the loop's hardcoded
  bare-number hack. The typed `line 42`, the bare `42` minibuffer sugar, and an
  agent's `tools/call line` all converge on `line/1` here (ADR-0003: one path
  per capability). 1-based; **`0` jumps to the last line**; out-of-range clamps.

  `scroll`, a coordinate `select`, and the grid `goto x y`
  ([ADR-0027](../../doc/adr/0027-grid-command-addressing.md)) are the next
  members. Today a view action targets **the active view** (ADR-0030 §4 —
  multi-view targeting waits for panes).
  """

  alias Geex.Session
  alias Geex.Command.Field
  alias Geex.MCP.Schema

  @type result :: {:ok, String.t()} | {:error, String.t()} | {:invalid_args, String.t()}
  @type spec :: %{name: String.t(), description: String.t(), fields: [Field.t()]}

  @view_actions [
    %{
      name: "line",
      description:
        "Move the active view's cursor to the start of a line. 1-based (the number shown " <>
          "in the gutter); 0 jumps to the last line; past-the-end clamps to the last line. " <>
          "A view action: it moves the cursor only — not an edit, not recorded, not undoable.",
      fields: [
        %Field{
          name: :line,
          type: :integer,
          required: true,
          description: "1-based line number (0 = last line; clamped to the buffer)"
        }
      ]
    }
  ]

  @doc "MCP tool descriptors for every view action — merged into the `tools/list` payload."
  @spec tools() :: [map()]
  def tools, do: Enum.map(@view_actions, &descriptor/1)

  @doc "Look up a view action by name."
  @spec lookup(String.t()) :: {:ok, spec()} | :error
  def lookup(name) when is_binary(name) do
    case Enum.find(@view_actions, &(&1.name == name)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  @doc """
  Validate `args` against `action`'s field-spec and run it. The same result contract
  as `Geex.MCP.Operations.call/2`: `{:invalid_args, why}` / `{:ok, text}` /
  `{:error, message}` — protocol-frame-free.
  """
  @spec call(spec(), map()) :: result()
  def call(%{fields: fields, name: name}, args) when is_map(args) do
    case Geex.Command.cast_args(fields, args) do
      {:error, why} -> {:invalid_args, why}
      {:ok, parsed} -> run(name, parsed)
    end
  end

  @doc """
  Go to line `n` (1-based; `0` = the last line; clamped) in the active view — **the**
  go-to-line resolution both surfaces share: the minibuffer (`Geex.Loop.Verbs` parses
  `line 42` / bare `42` to this) and `tools/call line` (via `call/2`, which wraps it).
  Sets the cursor to the start of the resolved line and returns it, so the caller
  (the loop) can refresh its goal column. `{:error, :negative_line}` below 0;
  `{:error, :no_active_buffer}` with nothing open.
  """
  @spec line(integer()) ::
          {:ok, {non_neg_integer(), 0}} | {:error, :negative_line | :no_active_buffer}
  def line(n) when is_integer(n) and n < 0, do: {:error, :negative_line}

  def line(n) when is_integer(n) do
    case Session.snapshot() do
      {:ok, %{text: text}} ->
        last = max(line_count(text) - 1, 0)
        cursor = {if(n == 0, do: last, else: min(n - 1, last)), 0}
        Session.set_cursor(cursor)
        {:ok, cursor}

      {:error, :no_active_buffer} ->
        {:error, :no_active_buffer}
    end
  end

  defp run("line", %{line: n}) do
    case line(n) do
      {:ok, {line0, _col}} -> {:ok, "cursor at line #{line0 + 1}, column 1"}
      {:error, :negative_line} -> {:error, "line must be >= 0 (0 jumps to the last line)"}
      {:error, :no_active_buffer} -> {:error, ":no_active_buffer (open a file first)"}
    end
  end

  defp line_count(text), do: text |> String.split("\n") |> length()

  defp descriptor(action) do
    %{
      "name" => action.name,
      "description" => action.description,
      "inputSchema" => Schema.from_fields(action.fields)
    }
  end
end
