defmodule Geex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Geex.Registry},
        {Geex.CommandRegistry,
         commands: [Geex.Commands.Insert, Geex.Commands.Delete, Geex.Commands.Replace]}
      ] ++
        terminal_io_child() ++
        [
          Geex.Renderer,
          Geex.BufferSupervisor,
          Geex.Session
        ] ++
        http_mcp_child()

    opts = [strategy: :one_for_one, name: Geex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp terminal_io_child do
    if Application.get_env(:geex, :start_terminal, true) do
      [Geex.TerminalIO]
    else
      []
    end
  end

  # The loopback MCP HTTP transport (ADR-0018), feature-gated exactly like
  # terminal_io_child/0. Default OFF; bind 127.0.0.1 only (never 0.0.0.0) so
  # nothing off-host can reach it. `geex --serve` flips :start_http_mcp on.
  defp http_mcp_child do
    if Application.get_env(:geex, :start_http_mcp, false) do
      port = Application.get_env(:geex, :http_mcp_port, 4000)
      [{Bandit, plug: Geex.MCP.HTTP, scheme: :http, ip: {127, 0, 0, 1}, port: port}]
    else
      []
    end
  end
end
