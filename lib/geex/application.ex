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
         ]},
        # The global clipboard register (ADR-0015) — a cheap always-on singleton, so an
        # interactive copy and a later paste (or an agent's) share one ring.
        Geex.Clipboard
      ] ++
        terminal_io_child() ++
        [
          Geex.Renderer,
          Geex.BufferSupervisor,
          # Per-buffer highlight reactors (ADR-0022) are started on demand under
          # this supervisor; cheap when empty, always present.
          Geex.Highlight.ReactorSupervisor,
          Geex.Session,
          # The edits list behind the edits pane (ADR-0034 §6): in memory, bounded, always on.
          Geex.Edits
        ] ++
        loop_child() ++
        reconcile_child() ++
        http_children()

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

  # The interactive editor loop (ADR-0024) — the event-driven frame owner that
  # renders the active buffer + its highlight overlay each frame. Gated with the
  # terminal: it drives Geex.TerminalIO (and would block on `window_size` without
  # it), so it is meaningless headless. Off under `mix test`, like the terminal.
  # Starts after Session / Renderer / ReactorSupervisor, which it subscribes to and
  # renders through.
  defp loop_child do
    if Application.get_env(:geex, :start_terminal, true) do
      [Geex.Loop]
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

  # The loopback HTTP listener — one port, two jobs, both bound to 127.0.0.1 only:
  #
  #   * the MCP transport (ADR-0018, frozen by ADR-0032): `mix geex.serve` / `GEEX_SERVE=1`
  #     flips :start_http_mcp on, and the listener runs the full `Geex.MCP.HTTP` router
  #     (which also hands `/attest` on);
  #   * the attestation intake (ADR-0032): :start_attest, on by default (off under test), so
  #     the interactive editor listens too, but only on `/attest` (`Geex.Attest.HTTP`) — the
  #     frozen MCP surface is not exposed just because the editor is open.
  #
  # Port: default 0 = ask the host for a free port (no hardcoded collision); a pinned
  # `http_mcp_port` is honoured. Serve mode announces the MCP URL (logged +
  # `GEEX_MCP_PORT_FILE`); the attest intake publishes its URL in a discovery file.
  defp http_children do
    serve? = Application.get_env(:geex, :start_http_mcp, false)
    attest? = Application.get_env(:geex, :start_attest, true)

    if serve? or attest? do
      port = Geex.MCP.Port.resolve(Application.get_env(:geex, :http_mcp_port, 0))
      plug = if serve?, do: Geex.MCP.HTTP, else: Geex.Attest.HTTP

      # Announce AFTER Bandit, never before: the announcer is ordered after the
      # listener in this one_for_one tree, so if Bandit fails to bind (a pinned-port
      # clash, or the free-port TOCTOU losing the race) the supervisor aborts before
      # the announcer runs — and no stale URL/port file is left naming a port nothing
      # is actually listening on. A run-once Task (`:temporary`); it logs + writes
      # `GEEX_MCP_PORT_FILE` then exits.
      #
      # The discovery file is published after the listener for the same reason: never name
      # a port nothing is listening on.
      [{Bandit, plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: port}] ++
        if(serve?, do: [{Task, fn -> Geex.MCP.Port.announce(port) end}], else: []) ++
        if(attest?,
          do: [{Geex.Attest.Discovery, url: "http://127.0.0.1:#{port}/attest"}],
          else: []
        )
    else
      []
    end
  end
end
