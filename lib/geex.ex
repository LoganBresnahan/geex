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

  Launch *outside* iex so `:prim_tty` has exclusive terminal ownership:

      elixir --erl "-noshell -noinput" -S mix run -e 'Geex.run("lib/geex/loop.ex")'

  With no path, geex boots to an empty screen (open a file via the MCP
  `open_file` tool, or pass one here). This is the live dogfood: watch geex
  recolour its own source as you type.
  """
  @spec run(String.t() | nil) :: no_return()
  def run(path \\ nil) do
    {:ok, _} = Application.ensure_all_started(:geex)
    if is_binary(path), do: Geex.Session.open_file(path)
    Process.sleep(:infinity)
  end
end
