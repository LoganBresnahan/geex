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
  opens `path` as the active buffer and blocks. **Quit with Ctrl-Q** (the loop
  calls `System.stop/0`, so the app's shutdown restores the terminal).

  Launch *outside* iex so `:prim_tty` has exclusive terminal ownership, and with
  `--no-start` so logging is redirected to a file *before* the app (and its
  terminal) come up — otherwise startup logs (e.g. the file-watcher's warnings)
  splatter onto the alt-screen:

      elixir --erl "-noshell -noinput" -S mix run --no-start -e 'Geex.run("lib/geex/loop.ex")'

  Logs go to `<tmpdir>/geex.log`. With no path, geex boots to an empty screen
  (open a file via the MCP `open_file` tool, or pass one here). This is the live
  dogfood: watch geex recolour its own source as you type.
  """
  @spec run(String.t() | nil) :: no_return()
  def run(path \\ nil) do
    redirect_logs_to_file()
    {:ok, _} = Application.ensure_all_started(:geex)
    if is_binary(path), do: Geex.Session.open_file(path)
    Process.sleep(:infinity)
  end

  # geex draws on the terminal via :prim_tty, so any console/Logger output would
  # splatter onto the alt-screen mid-render (e.g. the file_system watcher's startup
  # warnings when inotify-tools is missing). Send logs to a file and detach every
  # other handler — done *before* the app starts (hence `mix run --no-start`).
  # Best-effort: a logging hiccup must never stop the editor from booting.
  defp redirect_logs_to_file do
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
