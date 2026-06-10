defmodule Geex.Command.Catalog.Entry do
  @moduledoc """
  One command-catalog entry ([ADR-0028](../../../../doc/adr/0028-editor-shell-and-minibuffer.md)
  §3): a `name`, a human `description`, and how to `invoke` it — a zero-arg `{:action, atom}`
  dispatched through the loop's shared action vocabulary, or a `{:typed, prefix}` that pre-fills
  `:command` mode so the user can supply the verb's argument.
  """
  @enforce_keys [:name, :description, :invoke]
  defstruct [:name, :description, :invoke]

  @type invoke :: {:action, atom()} | {:typed, String.t()}
  @type t :: %__MODULE__{name: String.t(), description: String.t(), invoke: invoke()}
end
