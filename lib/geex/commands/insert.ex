defmodule Geex.Commands.Insert do
  @moduledoc """
  Insert text at a `{line, col}` position. v0.1 built-in command exercising the
  full spine: macro → struct → field-spec → `parse/1` → `Geex.Dispatch` →
  `Geex.Buffer.Doc`.
  """

  use Geex.Command

  alias Geex.Buffer.Doc

  command :insert do
    description "Insert text at a (line, col) position"
    arg :line, :integer, description: "0-based line index"
    arg :col, :integer, description: "0-based column (grapheme) index"
    arg :text, :string, description: "Text to insert (may contain newlines)"

    run cmd, doc do
      Doc.insert(doc, {cmd.line, cmd.col}, cmd.text)
    end
  end
end
