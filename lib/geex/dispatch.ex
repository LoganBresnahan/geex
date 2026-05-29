defmodule Geex.Dispatch do
  @moduledoc """
  The single shared path (ADR-0003, mcp-ai-integration.md §2).

  Every command — from the minibuffer, an MCP tool-call, an in-pane agent, or a
  remote peer — runs through `run/3` into the same buffer and the same undo
  history. `run/3` stamps provenance (ADR-0005), invokes the command's `run/2`
  against the document, and returns the document plus the provenance-stamped
  command so the caller (a `Geex.Buffer` process) can record it in history.

  `replay/2` re-applies a recorded command list to an initial document. It does
  **not** re-stamp — recorded commands keep their original `meta` (including
  `at`), so replay is deterministic (§15c). This is the free, no-LLM regression
  test: record a `%Command{}` sequence, replay it, assert the document.

  In v0.1 the document is passed in explicitly (`run/3` is pure over a `Doc`).
  The process-resident entry point — `run(%Command{})` resolving the active
  buffer — wires on top of this when `Geex.Session`/`Geex.Buffer` are connected.
  """

  alias Geex.Buffer.Doc
  alias Geex.Command.Meta

  @doc """
  Run `command` against `doc`, stamping `meta`. Returns `{:ok, new_doc,
  stamped_command}` (record the command in history) or `{:error, reason}`.
  """
  @spec run(struct(), Doc.t(), Meta.t()) ::
          {:ok, Doc.t(), struct()} | {:error, term()}
  def run(command, %Doc{} = doc, %Meta{} = meta) when is_struct(command) do
    command = Geex.Command.put_meta(command, meta)

    case command.__struct__.run(command, doc) do
      {:ok, %Doc{} = new_doc} -> {:ok, new_doc, command}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_run_return, other}}
    end
  end

  @doc """
  Re-apply a recorded command list to `doc`, preserving each command's `meta`.
  Returns `{:ok, doc}` or `{:error, {reason, command}}` for the first failure.
  """
  @spec replay(Doc.t(), [struct()]) :: {:ok, Doc.t()} | {:error, {term(), struct()}}
  def replay(%Doc{} = doc, commands) when is_list(commands) do
    Enum.reduce_while(commands, {:ok, doc}, fn command, {:ok, acc} ->
      case command.__struct__.run(command, acc) do
        {:ok, %Doc{} = next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {reason, command}}}
        other -> {:halt, {:error, {{:bad_run_return, other}, command}}}
      end
    end)
  end
end
