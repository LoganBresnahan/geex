defmodule Geex.CommandRegistry do
  @moduledoc """
  Runtime registry of command modules: name → module (mcp-ai-integration.md §4).

  Distinct from `Geex.Registry` (the process `Registry` for buffers/panes). This
  holds command *definitions*. It is a GenServer because the command set is
  **dynamic** — plugins register commands at runtime (§10), which is what later
  drives `notifications/tools/list_changed` (§13). The `tools/list` MCP projection
  and the minibuffer completion both read from here.

  Commands register themselves via `register/2` (or are seeded with `:commands` at
  start). v0.1 does not yet wire this into the supervision tree — it is started by
  whoever needs it (a test, or the app once the dispatch entry point is wired).
  """

  use GenServer

  @type info :: %{name: atom(), module: module(), description: String.t()}

  @doc "Start a registry. `:name` defaults to the module; `:commands` seeds modules."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a command module (idempotent on its declared name)."
  @spec register(GenServer.server(), module()) :: :ok
  def register(server \\ __MODULE__, module), do: GenServer.call(server, {:register, module})

  @doc "Look up a command module by name."
  @spec lookup(GenServer.server(), atom()) :: {:ok, module()} | :error
  def lookup(server \\ __MODULE__, name), do: GenServer.call(server, {:lookup, name})

  @doc "All registered commands as `__command__/0` info maps."
  @spec all(GenServer.server()) :: [info()]
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  @impl true
  def init(opts) do
    table =
      opts
      |> Keyword.get(:commands, [])
      |> Map.new(fn module -> {module.__command__().name, module} end)

    {:ok, %{by_name: table}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    name = module.__command__().name
    {:reply, :ok, put_in(state.by_name[name], module)}
  end

  def handle_call({:lookup, name}, _from, state) do
    {:reply, Map.fetch(state.by_name, name), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, Enum.map(state.by_name, fn {_name, module} -> module.__command__() end), state}
  end
end
