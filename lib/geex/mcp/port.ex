defmodule Geex.MCP.Port do
  @moduledoc """
  Resolve and announce the loopback MCP HTTP port (ADR-0018).

  geex no longer hardcodes a port: by default it asks the **host** for a free TCP
  port (like pharos does with mist's `port = 0`), so two geex instances — or geex
  next to anything already on 4000 — don't collide. A fixed port is still
  available by pinning (`mix geex.serve --port N` / `GEEX_MCP_PORT=N`).

  Because Bandit is started from the supervision tree with a concrete port, the
  free port is resolved **up front** (bind `0`, read the assigned port, release
  it) rather than read back from the listener afterwards. A vanishingly small
  window exists before Bandit claims it; on loopback dev a collision just fails
  the listener start loudly.

  The resolved URL is **announced** so a headless caller can discover a dynamic
  port without a side channel: logged at boot, and written to the file named by
  `GEEX_MCP_PORT_FILE` when that variable is set (mirroring pharos's port file).
  """

  require Logger

  @doc """
  Resolve a requested port: `0` (auto) → an OS-assigned free loopback port; a
  fixed `1..65535` → itself.
  """
  @spec resolve(0..65535) :: 1..65535
  def resolve(0), do: free()
  def resolve(port) when port in 1..65535, do: port

  @doc """
  Ask the host for a free loopback TCP port: bind `0`, read the assigned port,
  release it.
  """
  @spec free() :: 1..65535
  def free do
    {:ok, socket} = :gen_tcp.listen(0, [{:ip, {127, 0, 0, 1}}, {:active, false}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @doc "The loopback MCP URL for `port`."
  @spec url(1..65535) :: String.t()
  def url(port) when port in 1..65535, do: "http://127.0.0.1:#{port}/mcp"

  @doc """
  Announce the bound `port`: log the URL, and write it to `GEEX_MCP_PORT_FILE`
  when set. Returns the file path written, or `nil`.
  """
  @spec announce(1..65535) :: Path.t() | nil
  def announce(port) when port in 1..65535 do
    Logger.info("geex MCP: serving #{url(port)}")
    write_file(port)
  end

  @doc """
  Write the URL for `port` to the path in `GEEX_MCP_PORT_FILE`, if set, so a
  spawner/harness can discover a dynamic port. Returns the path, or `nil`.
  """
  @spec write_file(1..65535) :: Path.t() | nil
  def write_file(port) when port in 1..65535 do
    case System.get_env("GEEX_MCP_PORT_FILE") do
      blank when blank in [nil, ""] ->
        nil

      path ->
        case File.write(path, url(port) <> "\n") do
          :ok ->
            path

          {:error, reason} ->
            Logger.warning("geex MCP: could not write GEEX_MCP_PORT_FILE #{path}: #{:file.format_error(reason)}")
            nil
        end
    end
  end
end
