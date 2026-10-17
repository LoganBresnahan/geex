defmodule Geex do
  @moduledoc """
  Top-level namespace. Implementation lives under `Geex.*` —
  see `Geex.Application` for the supervision tree entry point.
  """

  @doc """
  Boot geex as an interactive terminal editor and open `path` (if given).

  Starts the application — which brings up `Geex.TerminalIO` (raw-mode
  `:prim_tty`) and the event-driven `Geex.Loop` that paints the active buffer,
  highlights it live, and turns keys into commands on the one shared path — then
  opens `path` as the active buffer and blocks. **Quit with Ctrl-X, Ctrl-Q or Ctrl-C** (the
  loop calls `Geex.stop/0`, so the app's shutdown restores the terminal).

  Launch *outside* iex so `:prim_tty` has exclusive terminal ownership. The `--erl`
  flags matter:

    * `-noshell -noinput` — keep the Erlang shell off stdin so `:prim_tty` owns it.
    * `+Bd` — **disable the ERTS break handler.** The BEAM normally reserves
      `SIGINT`/Ctrl-C for its `BREAK:` inspect-a-live-node menu (which is why a bare
      Ctrl-C doesn't quit and `sigint` is absent from `os:set_signal/2`). Ctrl-C itself
      never sends SIGINT here: `Geex.TerminalIO` turns the tty's signal keys off, so it
      arrives as a key ([BUG-3](../doc/bugs.md)). With the menu off, a SIGINT from outside
      ends the VM instead of the menu taking the terminal. (`SIGTERM` triggers a graceful
      shutdown that restores the terminal, so `kill` is safe.)

  Use `--no-start` so logging is redirected to a file *before* the app (and its
  terminal) come up — otherwise startup logs (e.g. the file-watcher's warnings)
  splatter onto the alt-screen:

      elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("lib/geex/loop.ex")'

  Quit with **Ctrl-X**, Ctrl-Q or Ctrl-C. Logs go to `<tmpdir>/geex.log`. With no path, geex boots to an empty
  screen. The live dogfood: watch geex recolour its own source as you type.

  `path` may also be a **list** of paths, all opened, the first one shown (`buffers` switches,
  ADR-0034), or a **directory**, which opens an empty scratch buffer.
  """
  @spec run(String.t() | [String.t()] | nil) :: no_return()
  def run(path \\ nil) do
    redirect_logs_to_file()
    {:ok, _} = Application.ensure_all_started(:geex)
    open_paths(path)
    Process.sleep(:infinity)
  end

  @doc """
  Quit the editor: what `Ctrl-X`, the `quit` verb and the end of input call.

  Under `mix run` this is `System.stop/0`: the application stops in order, and
  `Geex.TerminalIO` restores the terminal on the way down. The installed binary's application
  never finishes starting (`Geex.CLI`), and a `System.stop/0` there skips that orderly stop.
  So when `Geex.CLI` is running, it is told instead, and it stops the tree itself.
  """
  @spec stop() :: :ok
  def stop do
    case Process.whereis(Geex.CLI) do
      nil -> System.stop()
      cli -> send(cli, :geex_quit)
    end

    :ok
  end

  @doc false
  # Open what geex was started on: `run/1` above, and the installed binary's `Geex.CLI`.
  @spec open_paths(String.t() | [String.t()] | nil) :: :ok
  def open_paths(path) do
    # Where geex was started, for the edits pane's root and a relative `open` (ADR-0034 §5).
    with [first | _] <- List.wrap(path), do: Geex.Session.set_start(first)
    open(path)
    :ok
  end

  defp open([]), do: open(nil)

  # Open the last first, so the first is shown and the recent list reads in argument order. The
  # editor shows them as tabs in argument order (ADR-0038).
  defp open([_ | _] = paths) do
    pids = paths |> Enum.reverse() |> Enum.map(&open/1) |> Enum.reverse()
    Geex.Loop.open_tabs(for {:ok, pid} <- pids, do: pid)
  end

  defp open(path) when is_binary(path) do
    if File.dir?(path), do: open(nil), else: Geex.Session.open_file(path)
  end

  # No file given: start a pathless scratch buffer and make it active, so the editor
  # is usable (typing needs an active buffer — with none, the loop ignores keys).
  defp open(nil) do
    {:ok, buf} = Geex.BufferSupervisor.start_scratch()
    Geex.Session.set_active_buffer(buf)
    {:ok, buf}
  end

  # geex draws on the terminal via :prim_tty, so any console/Logger output would
  # splatter onto the alt-screen mid-render (e.g. the file_system watcher's startup
  # warnings when inotify-tools is missing). Send logs to a file and detach every
  # other handler — done *before* the app starts (hence `mix run --no-start`).
  # Best-effort: a logging hiccup must never stop the editor from booting.
  @doc false
  def redirect_logs_to_file do
    file = System.tmp_dir!() |> Path.join("geex.log") |> String.to_charlist()
    _ = :logger.add_handler(:geex_file, :logger_std_h, %{config: %{type: {:file, file}}})
    for id <- :logger.get_handler_ids(), id != :geex_file, do: :logger.remove_handler(id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
