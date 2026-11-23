defmodule Geex.Loop.Resolver do
  @moduledoc """
  Where each line of the output pane points, found off the key loop
  ([ADR-0042](../../../doc/adr/0042-shell-commands.md)'s 2026-11-23 amendment, [ADR-0035](../../../doc/adr/0035-the-loop-never-waits.md)).

  **One process for the loop's life**, not one per pane. The loop sends it batches of finished
  lines (`resolve/6`), each tagged with the pane they came from; it reads each line's location
  and asks the disk whether it names a regular file under the root, then answers
  `{:geex_links, pid, pane, first, answers}`, one answer per line in order: a
  `t:Geex.Loop.Output.link/0`, or nil. The loop keeps only answers for the pane it shows.

  Why one: a stat that never returns (a stalled network disk) holds its process, and a killed
  process still holds one of the VM's dirty I/O schedulers until the call returns (10 by
  default). One resolver per pane, each killed and replaced, took one more with every pane, and
  with all ten held the terminal's own writes waited (geex-verifier's FUSE probe, 2026-11-23).
  With one resolver, a stalled disk holds one scheduler at most; the panes opened meanwhile get
  their links when the disk answers, and nothing else waits: the loop draws, opens and steps by
  the answers alone, and a line not answered yet is simply not a link.

  A new pane is announced (`pane/2`) before its first batch: work still queued for an older pane
  is dropped between chunks, and what was learnt about the disk is forgotten (a file may have
  come or gone since).

  - **`:show`** (a `!`, or a `|`'s stderr): the first location the line names, read as Enter
    reads it (`Geex.Shell.Text.location_span/1`).
  - **`:search`** (a project search's results, ADR-0053): the first reading of `path:line:text`
    that names a file (`Geex.Search.Project.locations/1`, R13), the `path:line` drawn as the link.

  A path is from the root (`Geex.Loop.FileOps.resolve/2`), and only a regular file is a link: a
  clock (`10:16:05`), an address (`localhost:5173`) or a path from another directory names no
  file there. Each path is asked about once per pane (a checker names the same file many times).
  The process ends when its owner does.
  """

  alias Geex.Loop.{FileOps, Output}
  alias Geex.Search.Project
  alias Geex.Shell.Text

  @type kind :: :show | :search

  # Answers go back every this many lines, so a long batch shows its links as it goes, and a new
  # pane is noticed between chunks.
  @chunk 200
  # Paths remembered per pane before the memory starts again.
  @memory 10_000

  @doc """
  Start the resolver, answering `owner` (default the caller): `{pid, monitor}`. `:regular?`
  replaces `Geex.Disk.regular?/1` (tests: a disk that stalls).
  """
  @spec start(keyword()) :: {pid(), reference()}
  def start(opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    regular? = Keyword.get(opts, :regular?, &Geex.Disk.regular?/1)
    spawn_monitor(fn -> init(owner, regular?) end)
  end

  @doc "Pane `id` is the one shown from now on (ids only grow): older panes' work is dropped."
  @spec pane(pid(), non_neg_integer()) :: :ok
  def pane(pid, id) do
    send(pid, {:pane, id})
    :ok
  end

  @doc "Ask where `lines` of pane `id` (a `kind` pane under `root`), numbered from `first`, point."
  @spec resolve(pid(), non_neg_integer(), kind(), String.t(), non_neg_integer(), [String.t()]) ::
          :ok
  def resolve(pid, id, kind, root, first, lines) when kind in [:show, :search] do
    send(pid, {:resolve, id, kind, root, first, lines})
    :ok
  end

  @doc """
  Stop it now; any answer still on its way is the caller's to ignore. A process held by a disk
  that never answers ends at once, but the call holding it keeps its dirty I/O scheduler until
  the disk answers.
  """
  @spec stop(pid(), reference()) :: :ok
  def stop(pid, ref) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  @doc """
  What `line` could point at, in the order to try: each `{at, len, path, line, col}`. Pure.

      iex> Geex.Loop.Resolver.readings(:show, "lib/a.ex:3:2: warning")
      [{0, 12, "lib/a.ex", 3, 2}]
      iex> Geex.Loop.Resolver.readings(:search, "notes:12:7:text")
      [{0, 8, "notes", 12, nil}, {0, 10, "notes:12", 7, nil}]
      iex> Geex.Loop.Resolver.readings(:show, "all good")
      []
  """
  @spec readings(kind(), String.t()) ::
          [{non_neg_integer(), pos_integer(), String.t(), pos_integer(), pos_integer() | nil}]
  def readings(:show, line) do
    case Text.location_span(line) do
      nil -> []
      {at, len, {path, l, col}} -> [{at, len, path, l, col}]
    end
  end

  def readings(:search, line) do
    for {path, l} <- Project.locations(line),
        do: {0, byte_size(path) + 1 + byte_size(Integer.to_string(l)), path, l, nil}
  end

  @doc """
  Where `line` points: the first reading whose path, from `root`, `file?` says is a regular file.
  `file?` gets the full path. Pure but for `file?`.

      iex> Geex.Loop.Resolver.find(:show, "lib/a.ex:3: x", "/r", &(&1 == "/r/lib/a.ex"))
      %{at: 0, len: 10, full: "/r/lib/a.ex", path: "lib/a.ex", line: 3, col: nil}
      iex> Geex.Loop.Resolver.find(:show, "at 10:16:05", "/r", fn _ -> false end)
      nil
  """
  @spec find(kind(), String.t(), String.t(), (String.t() -> boolean())) :: Output.link() | nil
  def find(kind, line, root, file?) do
    Enum.find_value(readings(kind, line), fn {at, len, path, l, col} ->
      with {:ok, full} <- FileOps.resolve(path, root),
           true <- file?.(full),
           do: %{at: at, len: len, full: full, path: path, line: l, col: col},
           else: (_ -> nil)
    end)
  end

  defp init(owner, regular?) do
    Process.monitor(owner)
    loop(%{owner: owner, regular?: regular?, pane: -1, known: %{}})
  end

  defp loop(st) do
    receive do
      {:pane, id} ->
        loop(shown(st, id))

      {:resolve, id, kind, root, first, lines} ->
        st = shown(st, id)
        loop(if id == st.pane, do: batch(st, {id, kind, root}, first, lines), else: st)

      {:DOWN, _ref, :process, owner, _reason} when owner == st.owner ->
        :ok

      _ ->
        loop(st)
    end
  end

  # A batch, a chunk at a time; between chunks a newer pane ends it.
  defp batch(st, _job, _first, []), do: st

  defp batch(st, {id, kind, root} = job, first, lines) do
    st = newer_panes(st)

    if st.pane == id do
      {chunk, rest} = Enum.split(lines, @chunk)
      {answers, st} = Enum.map_reduce(chunk, st, &answer(&1, kind, root, &2))
      send(st.owner, {:geex_links, self(), id, first, answers})
      batch(st, job, first + length(chunk), rest)
    else
      st
    end
  end

  defp newer_panes(st) do
    receive do
      {:pane, id} -> newer_panes(shown(st, id))
    after
      0 -> st
    end
  end

  # A newer pane: what was learnt about the disk is forgotten.
  defp shown(st, id) when id > st.pane, do: %{st | pane: id, known: %{}}
  defp shown(st, _id), do: st

  # One line's answer, asking the disk about each path once.
  defp answer(line, kind, root, st) do
    st = if map_size(st.known) > @memory, do: %{st | known: %{}}, else: st

    Enum.reduce_while(readings(kind, line), {nil, st}, fn {at, len, path, l, col}, {_, st} ->
      case FileOps.resolve(path, root) do
        {:ok, full} ->
          {file?, st} = known(st, full)

          if file?,
            do: {:halt, {%{at: at, len: len, full: full, path: path, line: l, col: col}, st}},
            else: {:cont, {nil, st}}

        _ ->
          {:cont, {nil, st}}
      end
    end)
  end

  defp known(st, full) do
    case st.known do
      %{^full => file?} ->
        {file?, st}

      known ->
        file? = st.regular?.(full)
        {file?, %{st | known: Map.put(known, full, file?)}}
    end
  end
end
