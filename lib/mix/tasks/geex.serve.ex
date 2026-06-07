defmodule Mix.Tasks.Geex.Serve do
  @shortdoc "Run geex serving the loopback MCP HTTP transport (ADR-0018)"
  @moduledoc """
  Start geex with the **loopback Streamable HTTP MCP transport** on (ADR-0018) so a
  harness can *connect* and edit the live session — dogfood == production.

      mix geex.serve              # serve on 127.0.0.1:4000
      mix geex.serve --port 4100  # serve on a different loopback port

  This is geex's "--serve" entry point at the dev stage. It sets `GEEX_SERVE=1`
  (and `GEEX_MCP_PORT` when `--port` is given), which `config/runtime.exs` reads to
  flip `:start_http_mcp` on and `:start_terminal` off (a serving geex runs headless —
  it does not grab `:prim_tty`), then delegates to `mix run --no-halt` so the node
  boots with those gates and stays up. The listener binds 127.0.0.1 only.

  Point a harness at `http://127.0.0.1:<port>/mcp` (see `presets/`). Stop with Ctrl-C.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [port: :integer])

    if (port = opts[:port]) && port not in 1..65535 do
      # OptionParser already enforces integer; range is on us. Fail loud and named here
      # rather than as an opaque `:badarg` from `:gen_tcp.listen/2` at listener start.
      Mix.raise("--port must be an integer in 1..65535, got: #{port}")
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
