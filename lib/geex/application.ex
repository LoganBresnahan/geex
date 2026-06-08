defmodule Geex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Geex.Registry},
        {Geex.CommandRegistry,
         commands: [
           Geex.Commands.Insert,
           Geex.Commands.Delete,
           Geex.Commands.Replace,
           Geex.Commands.Edit
         ]}
      ] ++
        terminal_io_child() ++
        [
          Geex.Renderer,
          Geex.BufferSupervisor,
          # Per-buffer highlight reactors (ADR-0022) are started on demand under
          # this supervisor; cheap when empty, always present.
          Geex.Highlight.ReactorSupervisor,
          Geex.Session
        ] ++
        reconcile_child() ++
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

  # The reconcile file-watcher (ADR-0017) — the always-on Rung 0 floor. Gated like the
  # others; default ON (it is the honest floor), off under `mix test` (config.exs). It
  # depends on BufferSupervisor + Session, so it starts after them.
  defp reconcile_child do
    if Application.get_env(:geex, :start_reconcile, true) do
      [Geex.Reconcile]
    else
      []
    end
  end

  # The default loopback MCP port (ADR-0018) — the single source of truth. `config/runtime.exs`'s
  # GEEX_MCP_PORT fallback mirrors this, and the checked-in preset (`presets/`) + its test assert
  # the preset URL against `default_http_mcp_port/0`, so the preset can't silently drift off the
  # port a default-served geex actually listens on.
  @default_http_mcp_port 4000

  @doc "The default port the loopback MCP HTTP transport serves on when none is configured."
  @spec default_http_mcp_port() :: pos_integer()
  def default_http_mcp_port, do: @default_http_mcp_port

  # The loopback MCP HTTP transport (ADR-0018), feature-gated exactly like
  # terminal_io_child/0. Default OFF; bind 127.0.0.1 only (never 0.0.0.0) so
  # nothing off-host can reach it. `mix geex.serve` / `GEEX_SERVE=1` flips :start_http_mcp on.
  defp http_mcp_child do
    if Application.get_env(:geex, :start_http_mcp, false) do
      port = Application.get_env(:geex, :http_mcp_port, @default_http_mcp_port)
      [{Bandit, plug: Geex.MCP.HTTP, scheme: :http, ip: {127, 0, 0, 1}, port: port}]
    else
      []
    end
  end
end
