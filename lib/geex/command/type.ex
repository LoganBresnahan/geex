defmodule Geex.Command.Type do
  @moduledoc """
  The argument-type table: coercion from raw input to a typed value.

  This is the **one place** argument types are defined (ADR-0004). The minibuffer
  hands raw strings; an MCP tool-call hands JSON scalars; both flow through
  `cast/2`, so the per-type parsing is shared. Adding a type (e.g. `:coord_range`
  for `"a1-g3"`, per mcp-ai-integration.md §3a) is a new clause here plus a row in
  the JSON-Schema mapping when that renderer is built — nothing else changes.

  v0.1 ships the scalar types the first commands need; richer editor types
  (`:coord`, `:coord_range`) land with the commands that use them.
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

  def cast(type, v), do: {:error, "cannot cast #{inspect(v)} to #{inspect(type)}"}
end
