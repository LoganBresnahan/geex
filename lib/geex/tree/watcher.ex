defmodule Geex.Tree.Watcher do
  @moduledoc """
  Tells the loop when files under the tree's root are created, deleted or renamed, so the tree
  and the finder follow them by themselves ([ADR-0034](../../../doc/adr/0034-panes-tree-edits-hold.md)
  §5, amended).

  Each read of the tree (`Geex.Loop`'s reader process) hands over the directories that hold the
  files it listed, with `watch/4`. This process watches those, the root, and each one's
  immediate subdirectories but dot-directories, **without** recursion: an ignored tree like
  `_build/`, `deps/` or `.git/` is never descended into, while a new directory beside the files
  is seen as soon as it is made, and watched from the next read. A create, delete or move
  there sends the loop `{:geex_tree_changed, root}` once, `delay_ms` after the first event of a
  burst; the loop reads the files again, off the loop (ADR-0035), and that read hands over the
  new directories. Changes to a file's content don't move the tree and are not reported.

  The watch is one `:file_system` worker (`inotifywait`) over every directory. When the set
  changes, a new worker starts before the old one stops, so nothing falls in between. If the
  backend is missing (`inotify-tools`), the tree is re-read only on `Alt+O`/`Alt+T`, as before,
  and the log says so once. A root with more than 4096 such directories is watched at the root
  and its own subdirectories only.
  """

  use GenServer
  require Logger

  @max_dirs 4096
  @default_delay_ms 150
  @tree_events [:created, :deleted, :moved_to, :moved_from]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Watch `root`, given the directories (relative to it, `"."` for the root) that hold the files
  just listed; tell `notify` of changes. A no-op when the watcher isn't running (tests,
  headless).
  """
  @spec watch(GenServer.server(), String.t(), [String.t()], pid()) :: :ok
  def watch(server \\ __MODULE__, root, dirs, notify) do
    if alive?(server), do: GenServer.cast(server, {:watch, root, dirs, notify})
    :ok
  end

  @doc """
  The directories that hold `files` (paths relative to the root), each once: what a read hands
  to `watch/4`.

      iex> Geex.Tree.Watcher.dirs_of(["README.md", "lib/a.ex", "lib/b/c.ex", "lib/d.ex"])
      [".", "lib", "lib/b"]
  """
  @spec dirs_of([String.t()]) :: [String.t()]
  def dirs_of(files), do: files |> Enum.map(&Path.dirname/1) |> Enum.uniq()

  @impl true
  def init(opts) do
    # `FileSystem.start_link/1` links the worker to us; a worker that dies must not take the
    # watcher down.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       root: nil,
       notify: nil,
       dirs: nil,
       worker: nil,
       timer: nil,
       failures: 0,
       warned: false,
       delay_ms: Keyword.get(opts, :delay_ms, @default_delay_ms),
       start_worker: Keyword.get(opts, :start_worker, &start_filesystem/1)
     }}
  end

  @impl true
  def handle_cast({:watch, root, rel_dirs, notify}, state) do
    state = %{state | notify: notify}

    dirs =
      case watch_dirs(root, rel_dirs) do
        {:ok, dirs} ->
          dirs

        {:capped, n, dirs} ->
          if state.dirs != dirs,
            do: Logger.warning("geex tree: #{root} has #{n} directories; only its top is watched")

          dirs
      end

    if state.worker != nil and state.root == root and state.dirs == dirs,
      do: {:noreply, state},
      else: {:noreply, restart(%{state | root: root}, dirs)}
  end

  @impl true
  def handle_info({:file_event, worker, {_path, events}}, %{worker: worker} = state) do
    state = %{state | failures: 0}

    if state.timer == nil and Enum.any?(events, &(&1 in @tree_events)) do
      {:noreply, %{state | timer: Process.send_after(self(), :changed, state.delay_ms)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:changed, state) do
    if state.notify, do: send(state.notify, {:geex_tree_changed, state.root})
    {:noreply, %{state | timer: nil}}
  end

  # The worker stopped: `inotifywait` exited, as it does when a directory it was given is gone
  # by the time it starts. The loop reads the files again, and that read restarts the watch
  # with the directories as they are now. Twice in a row with no event between, it gives up
  # until the next read.
  def handle_info({:file_event, worker, :stop}, %{worker: worker} = state) do
    state = %{state | worker: nil, dirs: nil, failures: state.failures + 1}

    if state.failures <= 2 do
      if state.notify, do: send(state.notify, {:geex_tree_changed, state.root})
    else
      Logger.warning("geex tree: the file watch keeps stopping; new files show on Alt+O")
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state) when reason != :normal do
    Logger.warning("geex tree: the file watch ended (#{inspect(reason)})")
    {:noreply, %{state | worker: nil, dirs: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Start the new worker, then stop the old one, so no event falls between them.
  defp restart(state, dirs) do
    old = state.worker

    state =
      case state.start_worker.(dirs) do
        {:ok, worker} ->
          FileSystem.subscribe(worker)
          %{state | worker: worker, dirs: dirs}

        other ->
          unless state.warned do
            Logger.warning(
              "geex tree: can't watch #{state.root} (#{inspect(other)}); " <>
                "new files show on Alt+O or Alt+T"
            )
          end

          %{state | worker: nil, dirs: nil, warned: true}
      end

    if old, do: Process.exit(old, :shutdown)
    state
  end

  # The directories to watch, absolute and existing: the root, each that holds a listed file,
  # and each one's immediate subdirectories but dot-directories.
  defp watch_dirs(root, rel_dirs) do
    root = Path.expand(root)
    held = Enum.uniq([root | Enum.map(rel_dirs, &Path.expand(&1, root))])

    # Too many already: don't list each one's subdirectories to find out by how much.
    dirs =
      if length(held) > @max_dirs,
        do: held,
        else: Enum.uniq(held ++ Enum.flat_map(held, &subdirs/1)) |> Enum.filter(&File.dir?/1)

    if length(dirs) > @max_dirs,
      do: {:capped, length(dirs), Enum.sort([root | subdirs(root)])},
      else: {:ok, Enum.sort(dirs)}
  end

  defp subdirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            not String.starts_with?(name, "."),
            path = Path.join(dir, name),
            File.dir?(path),
            do: path

      {:error, _} ->
        []
    end
  end

  defp start_filesystem(dirs) do
    FileSystem.start_link(dirs: dirs, recursive: false)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp alive?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp alive?(server) when is_pid(server), do: Process.alive?(server)
end
