defmodule Geex.Command.Field do
  @moduledoc """
  One entry in a command's **serialization-neutral field-spec** (ADR-0004,
  mcp-ai-integration.md §3a).

  The `Geex.Command` macro emits a list of these from its `arg` declarations.
  Renderers *project* the list to each consumer — the minibuffer parser, the
  argument validator, and (later) the MCP `inputSchema` JSON-Schema. The macro
  knows nothing about JSON-Schema; this neutral term is the single source, so
  schema / parser / validator cannot drift.

    * `name`        — the argument name (atom), also the struct field
    * `type`        — a `Geex.Command.Type` atom (`:string`, `:integer`, …)
    * `required`    — true unless the `arg` declared a `:default`
    * `default`     — value used when the argument is absent (`nil` if required)
    * `description` — human/LLM-facing help text
  """

  @enforce_keys [:name, :type]
  defstruct [:name, :type, :description, required: true, default: nil]

  @type t :: %__MODULE__{
          name: atom(),
          type: atom(),
          required: boolean(),
          default: term(),
          description: String.t() | nil
        }
end
