defmodule Geex.Attest.HTTP do
  @moduledoc """
  `POST /attest` — the loopback attestation endpoint (ADR-0032).

  In TUI mode this router is the whole listener: the frozen MCP surface is *not* exposed
  just because the editor is open. Under `mix geex.serve` the MCP router hands `/attest`
  here, so the payload finds the same endpoint either way.

  Every request must carry `authorization: Bearer <token>`, the per-instance token in the
  `0600` discovery file (`Geex.Attest.Discovery`). A request with an `Origin` header is
  refused: the payload is a local process, never a browser page.

  Status codes: `200` with `{"status": "attested" | "pending" | "ignored" | "not_open"}`;
  `400` malformed JSON or an invalid message (the reason in the body); `401` missing or
  wrong token; `403` an `Origin` header; `413` body too large.
  """

  use Plug.Router

  import Plug.Conn

  alias Geex.Attest
  alias Geex.Attest.Discovery

  # A message is a few hundred bytes; anything near this is not an attestation.
  @max_body_bytes 64_000

  plug :match
  plug :dispatch

  post "/attest" do
    cond do
      get_req_header(conn, "origin") != [] -> send_resp(conn, 403, "Forbidden: Origin not allowed")
      not authorized?(conn) -> send_resp(conn, 401, "Unauthorized")
      true -> handle(conn)
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp handle(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> respond(conn, body)
      {:more, _partial, conn} -> send_resp(conn, 413, "Payload Too Large")
      {:error, _reason} -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp respond(conn, body) do
    with {:ok, msg} <- decode(body),
         {:ok, attestation} <- Attest.parse(msg) do
      status = Attest.submit(attestation)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"status" => Atom.to_string(status)}))
    else
      {:error, reason} -> send_resp(conn, 400, "Bad Request: " <> reason)
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, msg} -> {:ok, msg}
      {:error, _} -> {:error, "malformed JSON"}
    end
  end

  defp authorized?(conn) do
    with token when is_binary(token) <- Discovery.token(),
         ["Bearer " <> given] <- get_req_header(conn, "authorization") do
      Plug.Crypto.secure_compare(given, token)
    else
      _ -> false
    end
  end
end
