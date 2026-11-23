defmodule Geex.Loop.Resolver do
  @moduledoc """
  Where each line of the output pane points, found off the key loop
  ([ADR-0042](../../../doc/adr/0042-shell-commands.md)'s 2026-11-23 amendment, [ADR-0035](../../../doc/adr/0035-the-loop-never-waits.md)).

  One process per output pane, started with it and stopped with it. The loop sends it batches of
  finished lines (`resolve/3`); it reads each line's location and asks the disk whether it names a
  regular file under the root, then answers `{:geex_links, pid, first, answers}`, one answer per
  line in order: a `t:Geex.Loop.Output.link/0`, or nil. A stat that never returns (a stalled
  network disk) holds this process, never the loop: the loop draws, opens and steps by the
  answers alone, and a line not answered yet is simply not a link.

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

  # Answers go back every this many lines, so a long batch shows its links as it goes.
  @chunk 200
  # Paths remembered per pane before the memory starts again.
  @memory 10_000

  @doc """
  Start a resolver for a pane of `kind` under `root`, answering `owner` (default the caller):
  `{pid, monitor}`. `:regular?` replaces `Geex.Disk.regular?/1` (tests: a disk that stalls).
  """
  @spec start(kind(), String.t(), keyword()) :: {pid(), reference()}
  def start(kind, root, opts \\ []) when kind in [:show, :search] do
    owner = Keyword.get(opts, :owner, self())
    regular? = Keyword.get(opts, :regular?, &Geex.Disk.regular?/1)
    spawn_monitor(fn -> init(kind, root, owner, regular?) end)
  end

  @doc "Ask where `lines`, numbered from `first`, point."
  @spec resolve(pid(), non_neg_integer(), [String.t()]) :: :ok
  def resolve(pid, first, lines) do
    send(pid, {:resolve, first, lines})
    :ok
  end

  @doc "Stop it now; any answer still on its way is the caller's to ignore."
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

  defp init(kind, root, owner, regular?) do
    Process.monitor(owner)
    loop(%{kind: kind, root: root, owner: owner, regular?: regular?, known: %{}})
  end

  defp loop(st) do
    receive do
      {:resolve, first, lines} ->
        st =
          lines
          |> Enum.chunk_every(@chunk)
          |> Enum.reduce({st, first}, fn chunk, {st, n} ->
            {answers, st} = Enum.map_reduce(chunk, st, &answer/2)
            send(st.owner, {:geex_links, self(), n, answers})
            {st, n + length(chunk)}
          end)
          |> elem(0)

        loop(st)

      {:DOWN, _ref, :process, owner, _reason} when owner == st.owner ->
        :ok

      _ ->
        loop(st)
    end
  end

  # One line's answer, asking the disk about each path once.
  defp answer(line, st) do
    st = if map_size(st.known) > @memory, do: %{st | known: %{}}, else: st

    Enum.reduce_while(readings(st.kind, line), {nil, st}, fn {at, len, path, l, col}, {_, st} ->
      case FileOps.resolve(path, st.root) do
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
