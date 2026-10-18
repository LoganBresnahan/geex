defmodule Geex.Installed.Watcher do
  @moduledoc """
  Notices packages installed by another geex process (`geex install` in another terminal,
  ADR-0040 §4), so a running editor highlights with them without a restart, as it does after
  its own installs.

  It watches `grammars/` and `themes/` under `Geex.Installed.root/0`, not recursively: an
  install renames its finished directory into place there. A burst of events is read once,
  `delay_ms` after the first: the directories are read again (`Geex.Installed.refresh/0`), and
  for each package that is new or whose sha256 changed, its compiled grammar is dropped and
  the loop is told `{:geex_installed, kind, name}`. Started with the loop; without
  `inotify-tools` it does nothing, and an install elsewhere shows after a restart.
  """

  use GenServer
  require Logger

  alias Geex.Installed

  @default_delay_ms 300

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dirs = for kind <- ["grammars", "themes"], do: Path.join(Installed.root(), kind)
    Enum.each(dirs, &File.mkdir_p/1)
    start = Keyword.get(opts, :start_worker, &FileSystem.start_link(dirs: &1, recursive: false))

    worker =
      case start.(dirs) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          pid

        other ->
          Logger.warning("geex install: can't watch #{Installed.root()} (#{inspect(other)})")
          nil
      end

    {:ok,
     %{
       worker: worker,
       timer: nil,
       known: known(),
       delay_ms: Keyword.get(opts, :delay_ms, @default_delay_ms),
       notify: Keyword.get(opts, :notify, Geex.Loop)
     }}
  end

  @impl true
  def handle_info({:file_event, worker, {_path, _events}}, %{worker: worker, timer: nil} = state),
    do: {:noreply, %{state | timer: Process.send_after(self(), :read, state.delay_ms)}}

  def handle_info(:read, state) do
    Installed.refresh()
    now = known()

    for {{kind, name}, sha} <- now, Map.get(state.known, {kind, name}) != sha do
      if kind == :grammar, do: Geex.Highlight.Grammars.forget(name)
      notify(state.notify, {:geex_installed, kind, name})
    end

    {:noreply, %{state | timer: nil, known: now}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp notify(pid, msg) when is_pid(pid), do: send(pid, msg)

  defp notify(name, msg) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end

  # Every installed package, by kind and name, with the sha256 its record names.
  defp known do
    for {kind, pkgs} <- [grammar: Installed.grammars(), theme: Installed.themes()],
        %{"installed" => %{"sha256" => sha}, "name" => name} <- pkgs,
        into: %{},
        do: {{kind, name}, sha}
  end
end
