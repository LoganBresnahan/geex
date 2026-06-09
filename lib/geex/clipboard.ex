defmodule Geex.Clipboard do
  @moduledoc """
  The clipboard — a **sibling subsystem**, not part of the replayable `EditorState`
  ([ADR-0015](../../doc/adr/0015-clipboard-subsystem.md)). It is a *selection source*
  like the cursor: copy/cut **push** text onto a register's **ring** (its own history,
  distinct from the document's undo history — Ctrl-Z doesn't un-copy), and paste reads
  the top and **bakes the literal text into an `insert` command** so it replays
  deterministically regardless of clipboard state.

  v0.1 ships the **global default register** — a single ring (newest first, capped).
  Named / buffer-local registers and yank-pop are the documented growth path
  ([ADR-0015](../../doc/adr/0015-clipboard-subsystem.md)); the ring shape already
  supports them.

  A tiny global GenServer (one per node), so an interactive copy and a later paste — or
  an agent's `paste` — share one clipboard. The server name defaults to the module; pass
  `:name` (and the matching `server` arg) to run an isolated instance in tests.
  """

  use GenServer

  # How many ring entries to keep (the kill-ring depth).
  @max_entries 100

  ## Public API

  @doc "Start the clipboard. `:name` overrides the registered name (default `#{inspect(__MODULE__)}`)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Push `text` onto the register's ring (the most-recent entry). Synchronous, so a copy is visible to an immediately following paste."
  @spec push(String.t(), GenServer.server()) :: :ok
  def push(text, server \\ __MODULE__) when is_binary(text), do: GenServer.call(server, {:push, text})

  @doc "The most-recent ring entry (what `paste` yanks), or `\"\"` when the ring is empty."
  @spec top(GenServer.server()) :: String.t()
  def top(server \\ __MODULE__), do: GenServer.call(server, :top)

  @doc "The whole ring, newest first (inspection / future yank-pop)."
  @spec ring(GenServer.server()) :: [String.t()]
  def ring(server \\ __MODULE__), do: GenServer.call(server, :ring)

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_call({:push, text}, _from, ring), do: {:reply, :ok, Enum.take([text | ring], @max_entries)}
  def handle_call(:top, _from, ring), do: {:reply, List.first(ring, ""), ring}
  def handle_call(:ring, _from, ring), do: {:reply, ring, ring}
end
