defmodule Geex.MCP.HTTPTest do
  # Exercises the Plug directly (no socket). Touches Session/CommandRegistry globals.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Geex.Buffer
  alias Geex.Session

  @opts Geex.MCP.HTTP.init([])

  defp call(method, path, body \\ "", headers \\ []) do
    conn = conn(method, path, body)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Geex.MCP.HTTP.call(conn, @opts)
  end

  defp post(body, headers \\ []), do: call(:post, "/mcp", body, headers)

  defp rpc(method, params \\ nil, id \\ 1) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    JSON.encode!(if params, do: Map.put(msg, "params", params), else: msg)
  end

  describe "POST /mcp — outcome mapping" do
    test "a request returns 200 application/json with the response frame" do
      conn = post(rpc("ping"))
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      assert %{"id" => 1, "result" => %{}} = JSON.decode!(conn.resp_body)
    end

    test "a notification returns 202 with an empty body" do
      conn = post(~s({"jsonrpc":"2.0","method":"notifications/initialized"}))
      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "malformed JSON returns 400 with a -32700 error frame (input the server can't accept)" do
      conn = post("{not json")
      assert conn.status == 400
      assert %{"error" => %{"code" => -32700}} = JSON.decode!(conn.resp_body)
    end

    test "a well-formed request whose result is a JSON-RPC error still rides 200" do
      conn = post(rpc("no/such/method"))
      assert conn.status == 200
      assert %{"error" => %{"code" => -32601}} = JSON.decode!(conn.resp_body)
    end

    test "initialize negotiates and advertises the tools capability" do
      conn = post(rpc("initialize", %{"protocolVersion" => "2025-11-25"}))
      assert %{"result" => result} = JSON.decode!(conn.resp_body)
      assert result["protocolVersion"] == "2025-11-25"
      assert result["capabilities"]["tools"] == %{}
    end

    test "a body over the cap is rejected with 413" do
      conn = post(String.duplicate("a", 4_000_001))
      assert conn.status == 413
    end
  end

  describe "Origin validation (DNS-rebinding defense)" do
    test "a missing Origin is allowed (native CLI clients)" do
      assert post(rpc("ping")).status == 200
    end

    test "a loopback Origin is allowed (case-insensitive host)" do
      assert post(rpc("ping"), [{"origin", "http://localhost:5173"}]).status == 200
      assert post(rpc("ping"), [{"origin", "http://127.0.0.1:9229"}]).status == 200
      assert post(rpc("ping"), [{"origin", "http://LOCALHOST:5173"}]).status == 200
    end

    test "a non-loopback Origin is forbidden with 403" do
      assert post(rpc("ping"), [{"origin", "https://evil.example.com"}]).status == 403
    end

    test "a look-alike host that only prefix-matches loopback is forbidden (no bypass)" do
      assert post(rpc("ping"), [{"origin", "http://localhost.evil.com"}]).status == 403
      assert post(rpc("ping"), [{"origin", "http://127.0.0.1.evil.com"}]).status == 403
      assert post(rpc("ping"), [{"origin", "http://localhost@evil.com"}]).status == 403
    end

    test "empty / null Origin is denied; absent Origin is allowed (safe asymmetry)" do
      assert post(rpc("ping"), [{"origin", ""}]).status == 403
      assert post(rpc("ping"), [{"origin", "null"}]).status == 403
      assert post(rpc("ping")).status == 200
    end
  end

  describe "MCP-Protocol-Version header (2025-11-25 MUST)" do
    test "a present-but-unsupported version → 400" do
      assert post(rpc("ping"), [{"mcp-protocol-version", "1999-99-99"}]).status == 400
    end

    test "a present-and-supported version → proceeds (200)" do
      assert post(rpc("ping"), [{"mcp-protocol-version", "2025-11-25"}]).status == 200
      assert post(rpc("ping"), [{"mcp-protocol-version", "2025-06-18"}]).status == 200
    end

    test "an absent version header is allowed" do
      assert post(rpc("ping")).status == 200
    end
  end

  describe "non-POST methods" do
    test "GET /mcp → 405 with an Allow: POST header" do
      conn = call(:get, "/mcp")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE /mcp → 405 (no session to terminate), not 404" do
      assert call(:delete, "/mcp").status == 405
    end

    test "an unknown path → 404" do
      assert call(:post, "/elsewhere", rpc("ping")).status == 404
    end
  end

  describe "tools/call over HTTP edits the live buffer" do
    setup do
      buf = start_supervised!({Buffer, text: ""})
      Session.set_active_buffer(buf)
      on_exit(fn -> Session.set_active_buffer(nil) end)
      :ok
    end

    test "an insert tool-call lands in the live session" do
      body = rpc("tools/call", %{"name" => "insert", "arguments" => %{"line" => 0, "col" => 0, "text" => "hi"}})
      conn = post(body)
      assert conn.status == 200
      assert %{"result" => %{"isError" => false, "content" => [%{"text" => "hi"}]}} =
               JSON.decode!(conn.resp_body)

      assert {:ok, %{text: "hi"}} = Session.snapshot()
    end
  end
end
