defmodule Geex.Commands.Delete do
  @moduledoc """
  Delete up to `count` graphemes starting at `{line, col}` (v0.1: single-line).
  `count` defaults to 1, which also exercises field-spec defaults / optional args.
  """

  use Geex.Command

  alias Geex.Buffer.Doc

  command :delete do
    description "Delete count graphemes starting at a (line, col) position"
    arg :line, :integer, description: "0-based line index"
    arg :col, :integer, description: "0-based column (grapheme) index"
    arg :count, :integer, default: 1, description: "Number of graphemes to delete"

    run cmd, doc do
      Doc.delete(doc, {cmd.line, cmd.col}, cmd.count)
    end
  end
end
