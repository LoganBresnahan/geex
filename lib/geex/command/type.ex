defmodule Geex.Command.Type do
  @moduledoc """
  The argument-type table: coercion from raw input to a typed value.

  This is the **one place** argument types are defined (ADR-0004). The minibuffer
  hands raw strings; an MCP tool-call hands JSON scalars; both flow through
  `cast/2`, so the per-type parsing is shared. Adding a type (e.g. `:coord_range`
  for `"a1-g3"`, per mcp-ai-integration.md §3a) is a new clause here plus a row in
  the JSON-Schema mapping when that renderer is built — nothing else changes.

  v0.1 ships the scalar types the first commands need; richer editor types
  (`:coord`, `:coord_range`) land with the commands that use them. `:edits` (the
  structured search/replace array for the `edit` tool, ADR-0020) is the first
  non-scalar type — a JSON array of `{search, replace}` objects.
  """

  @type t :: atom()

  @doc """
  Coerce `raw` to type `t`. Returns `{:ok, value}` or `{:error, message}`.

      iex> Geex.Command.Type.cast(:integer, "42")
      {:ok, 42}

      iex> Geex.Command.Type.cast(:integer, "nope")
      {:error, "expected integer, got \\"nope\\""}

      iex> Geex.Command.Type.cast(:string, "hi")
      {:ok, "hi"}
  """
  @spec cast(t(), term()) :: {:ok, term()} | {:error, String.t()}
  def cast(:string, v) when is_binary(v), do: {:ok, v}
  def cast(:string, v) when is_integer(v) or is_float(v) or is_atom(v), do: {:ok, to_string(v)}

  def cast(:integer, v) when is_integer(v), do: {:ok, v}

  def cast(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> {:ok, i}
      _ -> {:error, "expected integer, got #{inspect(v)}"}
    end
  end

  def cast(:boolean, v) when is_boolean(v), do: {:ok, v}
  def cast(:boolean, "true"), do: {:ok, true}
  def cast(:boolean, "false"), do: {:ok, false}

  # A search/replace array (the `edit` tool, ADR-0020) — the first non-scalar type.
  # Each element is an object with string `search` + `replace` (and optional
  # `description`); normalized to an atom-keyed map. Validation fails loudly so a
  # malformed block becomes a parse error (an isError tool result), not a crash.
  #
  # An empty array is rejected here rather than running as a no-op edit (which would
  # still record a phantom history entry and dirty the buffer) — a clean isError the
  # model can self-correct.
  def cast(:edits, []), do: {:error, "edits must contain at least one block"}

  def cast(:edits, list) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn element, {:ok, acc} ->
        case cast_edit_block(element) do
          {:ok, block} -> {:cont, {:ok, [block | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, blocks} -> {:ok, Enum.reverse(blocks)}
      {:error, _} = error -> error
    end
  end

  def cast(:edits, _), do: {:error, "expected an array of {search, replace} edit blocks"}

  def cast(type, v), do: {:error, "cannot cast #{inspect(v)} to #{inspect(type)}"}

  defp cast_edit_block(block) when is_map(block) do
    with {:ok, search} <- fetch_string(block, "search"),
         {:ok, replace} <- fetch_string(block, "replace") do
      {:ok,
       %{search: search, replace: replace, description: optional_string(block, "description")}}
    end
  end

  defp cast_edit_block(_),
    do: {:error, ~s(each edit block must be an object with "search" and "replace")}

  # Edit-block keys are a fixed literal set, so `:"#{key}"` cannot blow up the atom table.
  defp fetch_string(map, key) do
    case Map.get(map, key) || Map.get(map, :"#{key}") do
      v when is_binary(v) -> {:ok, v}
      nil -> {:error, ~s(edit block missing required string "#{key}")}
      _ -> {:error, ~s(edit block "#{key}" must be a string)}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) || Map.get(map, :"#{key}") do
      v when is_binary(v) -> v
      _ -> ""
    end
  end
end
