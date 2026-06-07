import Config

# Runtime serve gate — evaluated at boot (before `Geex.Application.start/2`) on every
# start path (`mix run`, `iex -S mix`, a release), so the HTTP MCP listener's feature
# gate can be flipped from the environment without editing compiled config.
#
# `GEEX_SERVE=1` is geex's "--serve" switch (ADR-0018): it turns on the loopback
# Streamable HTTP MCP transport so a harness can *connect* and edit the live session
# (dogfood == production), and turns the interactive terminal *off* (a serving geex runs
# headless — it must not try to grab `:prim_tty`). `mix geex.serve` is sugar that sets
# this env var then delegates to `mix run --no-halt`.
#
# The listener still binds 127.0.0.1 only (in `Geex.Application`); `GEEX_MCP_PORT`
# overrides the default port (4000). Off by default — absent the var, dev/prod boot
# exactly as before (terminal on, no HTTP listener).
if System.get_env("GEEX_SERVE") in ~w(1 true yes) do
  # Resolve the port defensively. An unset *or empty* `GEEX_MCP_PORT` is the default (4000,
  # mirroring `Geex.Application.default_http_mcp_port/0` — `System.get_env` returns "" for a
  # set-but-empty var, which a bare `||` would NOT fall back from); anything else must be an
  # integer in the TCP range. A bad value fails the boot here with a message that *names* the
  # variable, instead of a bare `String.to_integer/1` ArgumentError (or a later opaque
  # `:badarg` from the listener) that never mentions GEEX_MCP_PORT.
  port =
    case System.get_env("GEEX_MCP_PORT") do
      empty when empty in [nil, ""] ->
        4000

      str ->
        case Integer.parse(String.trim(str)) do
          {p, ""} when p in 1..65535 -> p
          _ -> raise "GEEX_MCP_PORT must be an integer in 1..65535, got: #{inspect(str)}"
        end
    end

  config :geex,
    start_http_mcp: true,
    start_terminal: false,
    http_mcp_port: port
end
