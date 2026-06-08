defmodule Geex.Highlight.ReactorSupervisor do
  @moduledoc """
  DynamicSupervisor for `Geex.Highlight.Reactor` processes — one per highlighted
  buffer ([ADR-0022](../../../doc/adr/0022-capability-reactor.md)).

  Always present in the tree (cheap when empty); reactors are started on demand by
  `Geex.Highlight.Reactor.watch/2` from `Geex.Session.open_file/1`, gated by
  `:start_highlight`. A reactor is `:temporary` and monitors its buffer, so it is
  not restarted here — it lives and dies with the buffer.
  """

  use DynamicSupervisor

  @max_reactors 1024

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a reactor for `buffer` in `language`. Idempotent: a reactor already running
  for the buffer collapses back to `{:ok, pid}` (the per-buffer registration rejects
  the duplicate).
  """
  @spec start_reactor(pid(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start_reactor(buffer, language) when is_pid(buffer) and is_binary(language) do
    spec = {Geex.Highlight.Reactor, buffer: buffer, language: language}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_reactors)
  end
end
