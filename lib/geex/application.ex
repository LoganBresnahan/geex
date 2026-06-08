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

  # The port the checked-in example preset (`presets/`) targets, and what its test
  # asserts the preset URL against so it can't silently drift. NOTE: this is *not*
  # the app's runtime default anymore — by default geex asks the host for a free
  # port (`Geex.MCP.Port`); pin `--port 4000` to use the static preset as-is.
  @example_preset_port 4000

  @doc "The port the checked-in example preset targets (pin `--port 4000` to use it as-is)."
  @spec default_http_mcp_port() :: pos_integer()
  def default_http_mcp_port, do: @example_preset_port

  # The loopback MCP HTTP transport (ADR-0018), feature-gated exactly like
  # terminal_io_child/0. Default OFF; bind 127.0.0.1 only (never 0.0.0.0) so
  # nothing off-host can reach it. `mix geex.serve` / `GEEX_SERVE=1` flips :start_http_mcp on.
  #
  # Port: default 0 = ask the host for a free port (no hardcoded collision); a
  # pinned `http_mcp_port` is honoured. The resolved URL is announced (logged +
  # `GEEX_MCP_PORT_FILE`) so a headless caller can discover a dynamic port.
  defp http_mcp_child do
    if Application.get_env(:geex, :start_http_mcp, false) do
      port = Geex.MCP.Port.resolve(Application.get_env(:geex, :http_mcp_port, 0))

      # Announce AFTER Bandit, never before: the announcer is ordered after the
      # listener in this one_for_one tree, so if Bandit fails to bind (a pinned-port
      # clash, or the free-port TOCTOU losing the race) the supervisor aborts before
      # the announcer runs — and no stale URL/port file is left naming a port nothing
      # is actually listening on. A run-once Task (`:temporary`); it logs + writes
      # `GEEX_MCP_PORT_FILE` then exits.
      [
        {Bandit, plug: Geex.MCP.HTTP, scheme: :http, ip: {127, 0, 0, 1}, port: port},
        {Task, fn -> Geex.MCP.Port.announce(port) end}
      ]
    else
      []
    end
  end
end
