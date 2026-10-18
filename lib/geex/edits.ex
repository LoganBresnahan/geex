defmodule Geex.Edits do
  @moduledoc """
  The edits list behind the edits pane ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md)
  §6): who changed which file, and when, newest first. This run's rows are bounded (500); the
  rows from earlier runs come from the list's file (`Geex.Edits.Log`), when it has one.

  A row is `%{path, who, at, sha256, tool_use}`: `who` is `{:agent, %{harness, session, turn,
  tool_use}}`, `:you` or `:outside`; `at` is the local time geex learned of it; `sha256` is the
  file's content after the change (`nil` for a save). A row from an earlier run also has
  `earlier: true`.

  **Sources:**

    * an attestation that reached the intake (`attested/1`), for any file, open or not;
    * your save (`saved/1`);
    * a change on disk to an open file (`disk_changed/2`).

  A change and its attestation are one row, joined by `{path, sha256}`, whichever comes first:
  a disk change an attestation already explains adds nothing, and an `:outside` row becomes the
  agent's when its attestation arrives (`add/2`). The "disk is newer" rows aren't stored here:
  they are the open buffers that are behind, read when the pane is drawn.

  **Kept** (amended 2026-10-18): each row added or upgraded is appended to the file as it
  happens. On start the file is read in the background (`handle_continue/2`), folded through
  `add/2` as the rows first were, and its rows become the earlier ones. A row that can't be
  written is logged once, and the list carries on in memory.

  Subscribers get `{:geex_edits, :changed}` after each change, so the pane repaints.
  """

  use GenServer

  alias Geex.Edits.Log

  require Logger

  @max 500

  @type who :: {:agent, map()} | :you | :outside
  @type row :: %{
          required(:path) => String.t(),
          required(:who) => who(),
          required(:at) => NaiveDateTime.t(),
          required(:sha256) => String.t() | nil,
          required(:tool_use) => String.t() | nil,
          optional(:earlier) => true
        }

  @doc """
  Options: `:name`; `:max` (this run's rows); `:file`, the list's file (`nil`, the default:
  in memory only).
  """
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

  @doc "The rows, newest first: this run's, then the earlier ones."
  @spec rows(GenServer.server()) :: [row()]
  def rows(server \\ __MODULE__), do: GenServer.call(server, :rows)

  @doc "Send `pid` `{:geex_edits, :changed}` after each change. Monitored; dropped on exit."
  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(pid \\ self(), server \\ __MODULE__),
    do: GenServer.call(server, {:subscribe, pid})

  @doc """
  `row` added to `rows` (newest first): `{:added, rows, row}`, `{:upgraded, rows, row}` when it
  is the attestation of an `:outside` row (which becomes the agent's, keeping its place and
  time), or `:same` when the list already says it. Pure.

      iex> at = ~N[2026-10-18 14:46:00]
      iex> outside = %{path: "/a", who: :outside, at: at, sha256: "h", tool_use: nil}
      iex> {:added, rows, _} = Geex.Edits.add([], outside)
      iex> agent = %{outside | who: {:agent, %{harness: "claude-code", session: "s"}}, tool_use: "t"}
      iex> {:upgraded, [row], written} = Geex.Edits.add(rows, %{agent | at: ~N[2026-10-18 14:47:00]})
      iex> row == written
      true
      iex> {row.who, row.at, row.tool_use}
      {{:agent, %{harness: "claude-code", session: "s"}}, ~N[2026-10-18 14:46:00], "t"}
      iex> Geex.Edits.add([row], outside)
      :same
  """
  @spec add([row()], row()) :: {:added | :upgraded, [row()], row()} | :same
  def add(rows, %{who: {:agent, _}} = row) do
    case find(rows, row.path, row.sha256) do
      # The disk change came first: it was this agent.
      {i, %{who: :outside} = was} ->
        up = %{was | who: row.who, tool_use: row.tool_use}
        {:upgraded, List.replace_at(rows, i, up), up}

      # A repeat of an attestation already listed.
      {_i, %{who: {:agent, _}}} ->
        :same

      _ ->
        {:added, [row | rows], row}
    end
  end

  def add(rows, %{who: :outside} = row) do
    case find(rows, row.path, row.sha256) do
      nil -> {:added, [row | rows], row}
      _explained -> :same
    end
  end

  def add(rows, %{who: :you} = row), do: {:added, [row | rows], row}

  @doc """
  The rows `loaded` (oldest first) added in turn, as `add/2` would leave them, newest first.
  Without `add/2`'s walk of the whole list for each row: the row a later one joins is found by
  its `{path, sha256}`. Pure.
  """
  @spec fold([row()]) :: [row()]
  def fold(loaded) do
    {rows, _keys, _n} =
      Enum.reduce(loaded, {%{}, %{}, 0}, fn row, {rows, keys, n} ->
        key = row.sha256 && {row.path, row.sha256}

        case key && Map.get(keys, key) do
          nil ->
            keys = if key, do: Map.put(keys, key, n), else: keys
            {Map.put(rows, n, row), keys, n + 1}

          i ->
            case {row.who, rows[i]} do
              {{:agent, _}, %{who: :outside} = was} ->
                {%{rows | i => %{was | who: row.who, tool_use: row.tool_use}}, keys, n}

              _said ->
                {rows, keys, n}
            end
        end
      end)

    rows |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))
  end

  # Local wall-clock time: the pane shows HH:MM.
  defp now, do: NaiveDateTime.local_now()

  @impl true
  def init(opts) do
    state = %{
      rows: [],
      earlier: [],
      subscribers: %{},
      max: Keyword.get(opts, :max, @max),
      file: Keyword.get(opts, :file)
    }

    if state.file, do: {:ok, state, {:continue, :load}}, else: {:ok, state}
  end

  # Read the file off the caller's path: the supervisor goes on starting geex meanwhile, and a
  # `rows/1` call waits for it.
  @impl true
  def handle_continue(:load, state) do
    {loaded, bad} = Log.load(state.file)

    if bad > 0,
      do: Logger.warning("geex edits: skipped #{bad} unreadable line(s) in #{state.file}")

    earlier = loaded |> fold() |> Enum.map(&Map.put(&1, :earlier, true))
    {:noreply, changed(%{state | earlier: earlier})}
  rescue
    e ->
      Logger.warning("geex edits: couldn't read #{state.file}: #{Exception.message(e)}")
      {:noreply, state}
  end

  @impl true
  def handle_cast({:attested, a, at}, state) do
    row = row(Path.expand(a.path), {:agent, Geex.Attest.who(a)}, at, a.sha256, a.tool_use)
    {:noreply, put(state, row)}
  end

  def handle_cast({:disk_changed, path, sha256, at}, state),
    do: {:noreply, put(state, row(Path.expand(path), :outside, at, sha256, nil))}

  def handle_cast({:saved, path, at}, state),
    do: {:noreply, put(state, row(Path.expand(path), :you, at, nil, nil))}

  @impl true
  def handle_call(:rows, _from, state), do: {:reply, state.rows ++ state.earlier, state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  defp row(path, who, at, sha256, tool_use),
    do: %{path: path, who: who, at: at, sha256: sha256, tool_use: tool_use}

  defp put(state, row) do
    case add(state.rows, row) do
      {_how, rows, written} -> state |> keep(written) |> Map.put(:rows, rows) |> changed()
      :same -> state
    end
  end

  # Append the row to the list's file. One that can't be written stops the writing, said once.
  defp keep(%{file: nil} = state, _row), do: state

  defp keep(state, row) do
    case Log.append(state.file, row) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning(
          "geex edits: not keeping the edits list in #{state.file}: #{inspect(reason)}"
        )

        %{state | file: nil}
    end
  end

  defp find(_rows, _path, nil), do: nil

  defp find(rows, path, sha256) do
    rows
    |> Enum.with_index()
    |> Enum.find_value(fn {r, i} -> if r.path == path and r.sha256 == sha256, do: {i, r} end)
  end

  defp changed(state) do
    for {_ref, pid} <- state.subscribers, do: send(pid, {:geex_edits, :changed})
    %{state | rows: Enum.take(state.rows, state.max)}
  end
end
