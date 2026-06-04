defmodule Geex.Dispatch do
  @moduledoc """
  The single shared path (ADR-0003, mcp-ai-integration.md §2), in two layers
  (ADR-0014).

  **Pure inner layer.** `apply_command/2` runs one already-stamped `%Command{}`
  against an `%Geex.EditorState{}` and returns `{:ok, state} | {:error, reason}`. It
  does not stamp provenance and touches no process — the transport stamps the command
  (via `Geex.Command.put_meta/2`) before it ever reaches here. `replay/2` folds a
  recorded command list over it; because it re-runs the recorded values without
  re-stamping (each command keeps its original `meta.at`), replay is deterministic —
  the free, no-LLM regression backbone (§15c). Both functions are pure and are the
  most valuable thing to unit-test.

  **Impure outer layer.** `run/1` is the public entry every actor uses (minibuffer,
  MCP tool-call, in-pane agent, remote peer). It takes a provenance-stamped command,
  resolves the **active buffer** from `Geex.Session`, and asks that `Geex.Buffer`
  process to **gather → apply → scatter → record**: gather its `EditorState`, apply
  the command, scatter the new state back, and append the command to its one undo
  history. The gather/scatter/record happens atomically inside the buffer process, so
  distributed state never spreads the pure runner across processes (ADR-0014).
  """

  alias Geex.EditorState

  @doc """
  Apply one (already provenance-stamped) command to `state`. Pure.

  Returns `{:ok, state}` or `{:error, reason}`. A command whose `run/2` returns an
  unexpected shape becomes `{:error, {:bad_run_return, other}}` rather than crashing
  the caller.
  """
  @spec apply_command(struct(), EditorState.t()) :: {:ok, EditorState.t()} | {:error, term()}
  def apply_command(command, %EditorState{} = state) when is_struct(command) do
    case command.__struct__.run(command, state) do
      {:ok, %EditorState{} = next} -> {:ok, next}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_run_return, other}}
    end
  end

  @doc """
  Re-apply a recorded command list to `state`, preserving each command's `meta`.

  Returns `{:ok, state}` or `{:error, {reason, command}}` for the first failure.
  Deterministic: it re-runs recorded values, it does not re-stamp them (§15c).
  """
  @spec replay(EditorState.t(), [struct()]) ::
          {:ok, EditorState.t()} | {:error, {term(), struct()}}
  def replay(%EditorState{} = state, commands) when is_list(commands) do
    Enum.reduce_while(commands, {:ok, state}, fn command, {:ok, acc} ->
      case apply_command(command, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {reason, command}}}
      end
    end)
  end

  @doc """
  Run a provenance-stamped `command` against the active buffer's `EditorState`,
  recording it in that buffer's one undo history. Returns `{:ok, snapshot}` (see
  `Geex.Buffer.snapshot/1`) or `{:error, reason}` — `{:error, :no_active_buffer}`
  if no buffer is active.

  The transport is expected to have stamped provenance (`Geex.Command.put_meta/2`)
  before calling this — `run/1` does not stamp.
  """
  @spec run(struct()) :: {:ok, map()} | {:error, term()}
  def run(command) when is_struct(command) do
    case Geex.Session.active_buffer() do
      {:ok, pid} -> Geex.Buffer.dispatch(pid, command)
      :error -> {:error, :no_active_buffer}
    end
  end
end
