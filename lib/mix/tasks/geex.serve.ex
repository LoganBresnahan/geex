defmodule Mix.Tasks.Geex.Serve do
  @shortdoc "Run geex serving the loopback MCP HTTP transport (ADR-0018)"
  @moduledoc """
  Start geex with the **loopback Streamable HTTP MCP transport** on (ADR-0018) so a
  harness can *connect* and edit the live session — dogfood == production.

      mix geex.serve              # auto: ask the host for a free port
      mix geex.serve --port 4000  # pin a port (e.g. to use the static `presets/`)

  By default geex does **not** hardcode a port — it asks the host for a free one
  (so two instances, or geex next to anything on 4000, don't collide). The bound
  URL is announced: logged at boot as `geex MCP: serving http://127.0.0.1:<port>/mcp`
  and written to `GEEX_MCP_PORT_FILE` when that variable is set. Pass `--port 0` to
  force auto explicitly, or `--port N` to pin (the checked-in `presets/` target 4000).

  It sets `GEEX_SERVE=1` (and `GEEX_MCP_PORT` when `--port` is given), which
  `config/runtime.exs` reads to flip `:start_http_mcp` on and `:start_terminal` off
  (a serving geex runs headless — it does not grab `:prim_tty`), then delegates to
  `mix run --no-halt` so the node boots with those gates and stays up. The listener
  binds 127.0.0.1 only. Stop with Ctrl-C.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [port: :integer])

    if (port = opts[:port]) && port not in 0..65535 do
      # OptionParser already enforces integer; range is on us. Fail loud and named here
      # rather than as an opaque `:badarg` from `:gen_tcp.listen/2` at listener start.
      Mix.raise("--port must be an integer in 0..65535 (0 = auto), got: #{port}")
    end

    System.put_env("GEEX_SERVE", "1")
    if port = opts[:port], do: System.put_env("GEEX_MCP_PORT", Integer.to_string(port))

    # Delegate to `run --no-halt`: it loads config (including the runtime serve gate set
    # above), starts the application with the HTTP listener on, and blocks so the server
    # stays up. Keeping the gate in runtime.exs means there is one source of truth for
    # "what serving turns on", reachable both via this task and a bare GEEX_SERVE=1.
    Mix.Task.run("run", ["--no-halt"])
  end
end
