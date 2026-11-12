defmodule Geex.Command.Catalog.Entry do
  @moduledoc """
  One command-catalog entry ([ADR-0028](../../../../doc/adr/0028-editor-shell-and-minibuffer.md)
  §3): a `name`, a human `description`, and how to `invoke` it — a zero-arg `{:action, atom}`
  dispatched through the loop's shared action vocabulary (or one with its argument fixed, like
  `{:action, {:theme, "terminal"}}`), or a `{:typed, prefix}` that pre-fills `:command` mode so
  the user can supply the verb's argument.

  `usage` is how it is typed when it takes an argument (`new PATH`; `nil` when the name is
  all), and `aliases` the other names the minibuffer takes for it (`exit` for `quit`). The
  settings view's Commands tab shows both (roadmap item 18.6).

  A `{:command, command}` runs as its key does in the editor, on the file you were last in
  (ADR-0047 §6). `binds` lists the commands an entry's keys are found by when that isn't
  its invoke (`tab N` is the keys of tab 1 … tab 9, none by default); `nil` reads them from
  the invoke.
  """
  @enforce_keys [:name, :description, :invoke]
  defstruct [:name, :description, :invoke, usage: nil, aliases: [], binds: nil]

  @type invoke ::
          {:action, atom() | {:theme, String.t()}}
          | {:typed, String.t()}
          | {:command, term()}
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          invoke: invoke(),
          usage: String.t() | nil,
          aliases: [String.t()],
          binds: [term()] | nil
        }
end
