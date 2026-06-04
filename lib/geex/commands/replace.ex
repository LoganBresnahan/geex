defmodule Geex.Commands.Replace do
  @moduledoc """
  Replace the text in a `{start_line, start_col}`–`{end_line, end_col}` range with new
  text (which may be empty or contain newlines). The general range edit: it subsumes
  multi-line delete (empty `text`), point insert (an empty range), and in-place edit —
  so the coordinate write vocabulary is essentially complete for contiguous edits
  ([ADR-0016](../../../doc/adr/0016-external-harness-integration.md) coverage gate).
  Coordinates are 0-based, `col` grapheme-indexed; `start` must not be after `end`.
  """

  use Geex.Command

  alias Geex.Buffer.Doc
  alias Geex.EditorState

  command :replace do
    description "Replace the text in a (line, col) range with new text (may be multi-line)"
    arg :start_line, :integer, description: "0-based start line"
    arg :start_col, :integer, description: "0-based start column (grapheme)"
    arg :end_line, :integer, description: "0-based end line"
    arg :end_col, :integer, description: "0-based end column (grapheme); == start for a point insert"
    arg :text, :string, description: "Replacement text (empty to delete; may contain newlines)"

    run cmd, state do
      range = {{cmd.start_line, cmd.start_col}, {cmd.end_line, cmd.end_col}}
      EditorState.update_doc(state, &Doc.replace(&1, range, cmd.text))
    end
  end
end
