defmodule Geex.BufferSupervisor do
  @moduledoc """
  DynamicSupervisor for `Geex.Buffer` processes — one child per open file.

  Each buffer is **registered by its path** in `Geex.Registry` (a `:unique`
  process registry), so the multi-buffer / active-buffer model (ADR-0019) can
  *find-or-start* the buffer for a path. `Geex.Session.open_file/1` is the public
  orchestrator; this module owns the start + registration mechanics.

  In-memory / test buffers started directly (`{Geex.Buffer, text: …}`) carry no
  `:path` and are not registered here — only path-backed buffers are addressable.
  """

  use DynamicSupervisor

  # A generous ceiling on simultaneously-open buffers. `close_file` frees a slot
  # (`Session.close_file/1` → `terminate/1`), but a harness need not close, so buffers
  # can still accumulate; the cap turns a runaway open-loop into a clean
  # `{:error, :max_children}` (surfaced as an isError tool result via `Session.open_file`)
  # instead of unbounded memory growth.
  @max_buffers 1024

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a buffer for `path`, registered under that path in `Geex.Registry`.

  Returns `{:ok, pid}`, or `{:error, {:already_started, pid}}` if a buffer for that
  path is already running (the `:unique` registry rejects the duplicate name).
  `path` is expected to be already normalized by the caller (`Geex.Session`).
  """
  def start_buffer(path) when is_binary(path) do
    DynamicSupervisor.start_child(__MODULE__, {Geex.Buffer, path: path, name: via(path)})
  end

  @doc """
  Start a new empty, pathless **scratch** buffer (not registered: it has no path). What
  `Geex.run/1` opens with no file, and what `Geex.Session.close_active/0` falls back to.
  """
  @spec start_scratch() :: DynamicSupervisor.on_start_child()
  def start_scratch, do: DynamicSupervisor.start_child(__MODULE__, {Geex.Buffer, text: ""})

  @doc "The running buffer for `path`, or `:error` if none is open."
  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(path) when is_binary(path) do
    case Registry.lookup(Geex.Registry, path) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Terminate (close) an open buffer process — the mechanics behind
  `Geex.Session.close_file/1` / `delete_file/1`. The buffer is `:temporary`, so it
  stays down; its `Geex.Registry` entry clears on death (the registry monitors it),
  freeing the path for a future re-open. Returns `:ok`, or `{:error, :not_found}` if
  `pid` is not a current child (e.g. it already died).
  """
  @spec terminate(pid()) :: :ok | {:error, :not_found}
  def terminate(pid) when is_pid(pid),
    do: DynamicSupervisor.terminate_child(__MODULE__, pid)

  defp via(path), do: {:via, Registry, {Geex.Registry, path}}

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_buffers)
  end
end
