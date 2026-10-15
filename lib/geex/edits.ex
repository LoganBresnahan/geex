defmodule Geex.Edits do
  @moduledoc """
  The edits list behind the edits pane ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md)
  §6): who changed which file, and when, newest first. In memory and bounded (500 rows); the
  ledgers are the durable record.

  A row is `%{path, who, at, sha256, tool_use}`: `who` is `{:agent, %{harness, session, turn,
  tool_use}}`, `:you` or `:outside`; `at` is the local time geex learned of it; `sha256` is the
  file's content after the change (`nil` for a save).

  **Sources:**

    * an attestation that reached the intake (`attested/1`), for any file, open or not;
    * your save (`saved/1`);
    * a change on disk to an open file (`disk_changed/2`).

  A change and its attestation are one row, joined by `{path, sha256}`, whichever comes first:
  a disk change an attestation already explains adds nothing, and an `:outside` row becomes the
  agent's when its attestation arrives. The "disk is newer" rows aren't stored here: they are
  the open buffers that are behind, read when the pane is drawn.

  Subscribers get `{:geex_edits, :changed}` after each change, so the pane repaints.
  """

  use GenServer

  @max 500

  @type who :: {:agent, map()} | :you | :outside
  @type row :: %{
          path: String.t(),
          who: who(),
          at: NaiveDateTime.t(),
          sha256: String.t() | nil,
          tool_use: String.t() | nil
        }

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "An attestation reached the intake (a parsed `Geex.Attest` map)."
  @spec attested(map(), GenServer.server()) :: :ok
  def attested(attestation, server \\ __MODULE__),
    do: GenServer.cast(server, {:attested, attestation, now()})

  @doc "The file at `path` changed on disk to content hashing to `sha256`."
  @spec disk_changed(String.t(), String.t(), GenServer.server()) :: :ok
  def disk_changed(path, sha256, server \\ __MODULE__),
    do: GenServer.cast(server, {:disk_changed, path, sha256, now()})

  @doc "You saved `path`."
  @spec saved(String.t(), GenServer.server()) :: :ok
  def saved(path, server \\ __MODULE__), do: GenServer.cast(server, {:saved, path, now()})

  @doc "The rows, newest first."
  @spec rows(GenServer.server()) :: [row()]
  def rows(server \\ __MODULE__), do: GenServer.call(server, :rows)

  @doc "Send `pid` `{:geex_edits, :changed}` after each change. Monitored; dropped on exit."
  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(pid \\ self(), server \\ __MODULE__),
    do: GenServer.call(server, {:subscribe, pid})

  # Local wall-clock time: the pane shows HH:MM.
  defp now, do: NaiveDateTime.local_now()

  @impl true
  def init(opts), do: {:ok, %{rows: [], subscribers: %{}, max: Keyword.get(opts, :max, @max)}}

  @impl true
  def handle_cast({:attested, a, at}, state) do
    path = Path.expand(a.path)
    who = {:agent, Map.take(a, [:harness, :session, :turn, :tool_use])}

    rows =
      case find(state.rows, path, a.sha256) do
        # The disk change came first: it was this agent.
        {i, %{who: :outside}} ->
          List.update_at(state.rows, i, &%{&1 | who: who, tool_use: a.tool_use})

        # A repeat of an attestation already listed.
        {_i, %{who: {:agent, _}}} ->
          state.rows

        _ ->
          [row(path, who, at, a.sha256, a.tool_use) | state.rows]
      end

    {:noreply, changed(state, rows)}
  end

  def handle_cast({:disk_changed, path, sha256, at}, state) do
    path = Path.expand(path)

    rows =
      case find(state.rows, path, sha256) do
        nil -> [row(path, :outside, at, sha256, nil) | state.rows]
        _explained -> state.rows
      end

    {:noreply, changed(state, rows)}
  end

  def handle_cast({:saved, path, at}, state),
    do: {:noreply, changed(state, [row(Path.expand(path), :you, at, nil, nil) | state.rows])}

  @impl true
  def handle_call(:rows, _from, state), do: {:reply, state.rows, state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  defp row(path, who, at, sha256, tool_use),
    do: %{path: path, who: who, at: at, sha256: sha256, tool_use: tool_use}

  defp find(_rows, _path, nil), do: nil

  defp find(rows, path, sha256) do
    rows
    |> Enum.with_index()
    |> Enum.find_value(fn {r, i} -> if r.path == path and r.sha256 == sha256, do: {i, r} end)
  end

  defp changed(state, rows) do
    for {_ref, pid} <- state.subscribers, do: send(pid, {:geex_edits, :changed})
    %{state | rows: Enum.take(rows, state.max)}
  end
end
