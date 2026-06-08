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
# The listener still binds 127.0.0.1 only (in `Geex.Application`). `GEEX_MCP_PORT`
# pins a port; **unset (or `0`) means auto — geex asks the host for a free port**
# (no hardcoded 4000 to collide on; the bound URL is announced via the log and
# `GEEX_MCP_PORT_FILE`). Off by default — absent `GEEX_SERVE`, dev/prod boot
# exactly as before (terminal on, no HTTP listener).
if System.get_env("GEEX_SERVE") in ~w(1 true yes) do
  # Resolve the *requested* port defensively (0 = auto, resolved to a free port in
  # `Geex.Application`/`Geex.MCP.Port`). An unset *or empty* `GEEX_MCP_PORT` is auto
  # (`System.get_env` returns "" for a set-but-empty var, which a bare `||` would NOT
  # fall back from); anything else must be an integer in `0..65535`. A bad value fails
  # the boot here with a message that *names* the variable, instead of a bare
  # `String.to_integer/1` ArgumentError (or a later opaque `:badarg` from the listener).
  port =
    case System.get_env("GEEX_MCP_PORT") do
      empty when empty in [nil, ""] ->
        0

      str ->
        case Integer.parse(String.trim(str)) do
          {p, ""} when p in 0..65535 -> p
          _ -> raise "GEEX_MCP_PORT must be an integer in 0..65535 (0 = auto), got: #{inspect(str)}"
        end
    end

  config :geex,
    start_http_mcp: true,
    start_terminal: false,
    http_mcp_port: port
end
