defmodule Geex.MCP.HTTP do
  @moduledoc """
  The loopback **MCP Streamable HTTP** transport (ADR-0018) — a thin `Plug.Router`
  adapter over the pure `Geex.MCP.Protocol.handle_line/1`. This is **Mode 2**: a
  harness *connects* to the long-running geex and edits land in the live session,
  so dogfood == production.

  One endpoint, `POST /mcp`:

    * a JSON-RPC **request** → `200 application/json` with the response frame;
    * a **notification** (no `id`) → `202 Accepted`, empty body;
    * malformed JSON → `200` with the JSON-RPC error frame (the fault rides the body);
    * body over the cap → `413`.

  `GET /mcp` → `405` (geex serves no server→client SSE stream yet — there are no
  server-initiated messages in v0.5; `notifications/tools/list_changed` is deferred,
  §13). Everything else → `404`.

  **Security (the MCP spec MUSTs / pharos prior art):** `Origin` is allowed when
  absent (native CLI clients send none) or loopback, else `403` (DNS-rebinding
  defense); a present-but-unsupported `MCP-Protocol-Version` header → `400` (spec MUST);
  the listener binds `127.0.0.1` only (in `Geex.Application`), so nothing off-host can
  reach it; no auth on the loopback default. Responses are always `application/json`
  (geex serves no SSE stream), so `Accept` is not negotiated.

  **v0.5 scope:** stateless — no `Mcp-Session-Id`, single user, loopback only. Session
  tracking (and the connection-aware provenance it unlocks — real `model` from
  `clientInfo`, a `turn_id`) is a deliberate follow-up; today tool-call edits stamp
  `{:llm, "unknown"}` (`Geex.MCP.Protocol`).
  """

  use Plug.Router

  alias Geex.MCP.Protocol

  # Cap the request body so a crafted client can't exhaust memory (pharos uses 4MB).
  @max_body_bytes 4_000_000

  # Exact loopback hosts. Matching the *host* (not a string prefix) is deliberate:
  # a prefix check would accept `http://localhost.evil.com`, an Origin bypass.
  # (`::1` is allowed for forward-compat; the listener is IPv4-only today, so it
  # never actually arrives — harmless.)
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  plug :match
  plug :dispatch

  post "/mcp" do
    cond do
      not origin_allowed?(conn) ->
        send_resp(conn, 403, "Forbidden: Origin not allowed")

      not protocol_version_ok?(conn) ->
        send_resp(conn, 400, "Bad Request: unsupported MCP-Protocol-Version")

      true ->
        handle_post(conn)
    end
  end

  # Any non-POST method on /mcp (GET/DELETE/PUT/…) — geex serves no SSE stream and
  # has no session to terminate, so the method is simply not allowed here.
  match "/mcp" do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "Method Not Allowed (POST only; no SSE stream)")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp handle_post(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> respond(conn, Protocol.handle_line(body))
      {:more, _partial, conn} -> send_resp(conn, 413, "Payload Too Large")
      {:error, _reason} -> send_resp(conn, 400, "Bad Request")
    end
  end

  # The three handle_line/1 outcomes mapped to HTTP. A well-formed request (even one
  # whose result is a JSON-RPC error, e.g. method-not-found) rides 200 with the frame.
  # Input the server cannot accept (parse error / non-object — `:protocol_error`, no
  # client id) is an HTTP 400 carrying the JSON-RPC error frame, the spec-aligned
  # mapping for un-acceptable input.
  defp respond(conn, {:reply, frame}), do: json(conn, 200, frame)
  defp respond(conn, {:protocol_error, frame}), do: json(conn, 400, frame)
  defp respond(conn, :noreply), do: send_resp(conn, 202, "")

  defp json(conn, status, frame) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, frame)
  end

  # An absent header → assume the negotiated/current version (spec SHOULD, not a
  # reject). A present-but-unsupported header MUST be 400 (2025-11-25 spec).
  defp protocol_version_ok?(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> true
      [version | _] -> version in Protocol.supported_versions()
    end
  end

  defp origin_allowed?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> loopback_origin?(origin)
    end
  end

  # Match the parsed *host* (case-insensitively, per RFC 3986), never a string prefix.
  defp loopback_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host, :ascii) in @loopback_hosts

      _ ->
        false
    end
  end
end
