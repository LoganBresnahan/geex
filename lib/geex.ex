defmodule Geex do
  @moduledoc """
  Top-level namespace. Implementation lives under `Geex.*` —
  see `Geex.Application` for the supervision tree entry point.
  """

  @doc """
  Smoke entry point for v0.1 — boots the application, subscribes to
  `Geex.TerminalIO` events, and writes each event as a status line at
  the top of the alternate screen. No quit key: every printable
  character is reserved for editing, so exit via the BEAM break menu
  (Ctrl-c twice).

  Launch outside of iex so `:prim_tty` has exclusive terminal ownership:

      elixir --erl "-noshell -noinput" -S mix run -e 'Geex.run()'

  No real editing yet — this just proves the input/output path works
  end-to-end on top of `:prim_tty`.
  """
  def run(_path \\ nil) do
    {:ok, _} = Application.ensure_all_started(:geex)
    Geex.TerminalIO.subscribe()

    Geex.TerminalIO.write([
      "\e[1;1H",
      "geex v0.1 smoke — Ctrl-c twice to quit",
      "\e[3;1H",
      "events:"
    ])

    loop(_row = 4)
  end

  defp loop(row) do
    receive do
      {:geex_io, :eof} ->
        :ok

      {:geex_io, event} ->
        Geex.TerminalIO.write([
          "\e[#{row};1H",
          "\e[K",
          inspect(event)
        ])

        loop(row + 1)
    end
  end
end
