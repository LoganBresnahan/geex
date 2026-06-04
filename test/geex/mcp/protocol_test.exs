defmodule Geex.MCP.ProtocolTest do
  # Touches the app-global CommandRegistry + Session — not parallel-safe.
  use ExUnit.Case, async: false

  alias Geex.Buffer
  alias Geex.Commands.Insert
  alias Geex.MCP.Protocol
  alias Geex.Session

  # Decode the frame out of a {:reply, _} / {:protocol_error, _} outcome.
  defp frame({tag, json}) when tag in [:reply, :protocol_error], do: JSON.decode!(json)

  defp request(id, method, params \\ nil) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    msg = if params, do: Map.put(msg, "params", params), else: msg
    Protocol.handle_line(JSON.encode!(msg))
  end

  describe "the JSON-RPC envelope (pure, no app state)" do
    test "malformed JSON → protocol_error -32700 with null id" do
      assert {:protocol_error, _} = out = Protocol.handle_line("{not json")
      assert %{"id" => nil, "error" => %{"code" => -32700}} = frame(out)
    end

    test "a non-object message → invalid request -32600, null id" do
      assert {:protocol_error, _} = out = Protocol.handle_line("5")
      assert %{"id" => nil, "error" => %{"code" => -32600}} = frame(out)
    end

    test "a notification (no id) never gets a response" do
      assert Protocol.handle_line(~s({"jsonrpc":"2.0","method":"notifications/initialized"})) ==
               :noreply

      assert Protocol.handle_line(~s({"jsonrpc":"2.0","method":"notifications/cancelled"})) ==
               :noreply
    end

    test "unknown method → -32601" do
      assert %{"error" => %{"code" => -32601}} = frame(request(1, "no/such/method"))
    end

    test "ping → empty result" do
      assert %{"result" => result} = frame(request(1, "ping"))
      assert result == %{}
    end

    test "a request missing method → invalid request -32600 (id echoed)" do
      assert {:reply, _} = out = Protocol.handle_line(~s({"jsonrpc":"2.0","id":9}))
      assert %{"id" => 9, "error" => %{"code" => -32600}} = frame(out)
    end

    test "id type is preserved on the way out (integer and string)" do
      assert %{"id" => 7} = frame(request(7, "ping"))
      assert %{"id" => "abc"} = frame(request("abc", "ping"))
    end

    test "every reply carries jsonrpc 2.0" do
      assert %{"jsonrpc" => "2.0"} = frame(request(1, "ping"))
    end
  end

  describe "initialize" do
    test "echoes a supported protocol version and advertises the tools capability" do
      reply = frame(request(1, "initialize", %{"protocolVersion" => "2025-11-25"}))
      assert reply["result"]["protocolVersion"] == "2025-11-25"
      assert reply["result"]["capabilities"]["tools"] == %{}
      assert reply["result"]["serverInfo"]["name"] == "geex"
    end

    test "echoes an older-but-supported version (back-compat)" do
      reply = frame(request(1, "initialize", %{"protocolVersion" => "2025-06-18"}))
      assert reply["result"]["protocolVersion"] == "2025-06-18"
    end

    test "an unsupported requested version falls back to geex's preferred version" do
      reply = frame(request(1, "initialize", %{"protocolVersion" => "1999-01-01"}))
      assert reply["result"]["protocolVersion"] == "2025-11-25"
    end
  end

  describe "tools/list (projected from the live registry)" do
    test "lists the registered commands as MCP tools" do
      %{"result" => %{"tools" => tools}} = frame(request(1, "tools/list"))
      names = Enum.map(tools, & &1["name"]) |> Enum.sort()
      assert names == ["delete", "insert"]
      insert = Enum.find(tools, &(&1["name"] == "insert"))
      assert insert["inputSchema"]["required"] == ["line", "col", "text"]
    end
  end

  describe "tools/call — the same parse + dispatcher a human hits" do
    setup do
      buf = start_supervised!({Buffer, text: ""})
      Session.set_active_buffer(buf)
      on_exit(fn -> Session.set_active_buffer(nil) end)
      %{buf: buf}
    end

    test "a valid call edits the live buffer and returns a non-error result" do
      params = %{"name" => "insert", "arguments" => %{"line" => 0, "col" => 0, "text" => "hi"}}
      %{"result" => result} = frame(request(1, "tools/call", params))

      assert result["isError"] == false
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text == "hi"
      assert {:ok, %{text: "hi", history: [recorded]}} = Session.snapshot()
      assert recorded.meta.actor == {:llm, "unknown"}
    end

    test "string-valued JSON args are coerced (insert with string coords)" do
      params = %{"name" => "insert", "arguments" => %{"line" => "0", "col" => "0", "text" => "x"}}
      %{"result" => result} = frame(request(1, "tools/call", params))
      assert result["isError"] == false
    end

    test "a command runtime error rides isError:true (not a JSON-RPC error)" do
      params = %{"name" => "insert", "arguments" => %{"line" => 9, "col" => 0, "text" => "x"}}
      %{"result" => result} = frame(request(1, "tools/call", params))
      assert result["isError"] == true
      assert [%{"text" => "error: :row_out_of_range"}] = result["content"]
    end

    test "an unknown tool → -32602 (protocol error, not a result)" do
      params = %{"name" => "frobnicate", "arguments" => %{}}
      assert %{"error" => %{"code" => -32602}} = frame(request(1, "tools/call", params))
    end

    test "invalid arguments for a found tool → isError result (SEP-1303), not -32602" do
      params = %{"name" => "insert", "arguments" => %{"line" => 0}}
      %{"result" => result} = frame(request(1, "tools/call", params))
      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "Invalid arguments"
    end

    test "missing name → -32602 (malformed call, no tool identified)" do
      assert %{"error" => %{"code" => -32602}} = frame(request(1, "tools/call", %{}))
    end

    test "a dead active buffer yields -32603, not an uncaught exit" do
      # Point the session at a pid that is already dead; Dispatch.run → Buffer.dispatch
      # to it exits, and the protocol boundary must contain that as -32603.
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}
      Session.set_active_buffer(dead)

      params = %{"name" => "insert", "arguments" => %{"line" => 0, "col" => 0, "text" => "x"}}
      assert %{"error" => %{"code" => -32603}} = frame(request(1, "tools/call", params))
    end
  end

  describe "the one parser (§1/§15a): MCP args and typed args agree" do
    test "string-valued and typed args parse to the same %Command{}" do
      assert Insert.parse(%{"line" => "0", "col" => "5", "text" => " w"}) ==
               Insert.parse(%{line: 0, col: 5, text: " w"})
    end
  end
end
