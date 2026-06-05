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

  # A unique tmp path per test (counter, not randomness — no Date/rand).
  defp tmp_path do
    name = "geex_op_#{System.unique_integer([:positive])}.txt"
    path = Path.join(System.tmp_dir!(), name)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Open `path` via the MCP tool, and schedule the started buffer's teardown so the
  # app-global BufferSupervisor / Registry stay clean across tests.
  defp open_file_tool(id, path) do
    out =
      frame(request(id, "tools/call", %{"name" => "open_file", "arguments" => %{"path" => path}}))

    case Geex.BufferSupervisor.whereis(Path.expand(path)) do
      {:ok, pid} ->
        on_exit(fn ->
          if Process.alive?(pid),
            do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
        end)

      :error ->
        :ok
    end

    out
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

  describe "tools/list (projected from the live registry, merged with operation tools)" do
    test "lists the registered edit commands plus the operation tools (ADR-0019)" do
      %{"result" => %{"tools" => tools}} = frame(request(1, "tools/list"))
      names = Enum.map(tools, & &1["name"]) |> Enum.sort()
      assert names == ["delete", "insert", "open_file", "replace", "save_file"]
      insert = Enum.find(tools, &(&1["name"] == "insert"))
      assert insert["inputSchema"]["required"] == ["line", "col", "text"]
    end

    test "operation tools carry a field-spec-projected inputSchema" do
      %{"result" => %{"tools" => tools}} = frame(request(1, "tools/list"))

      open = Enum.find(tools, &(&1["name"] == "open_file"))
      assert open["inputSchema"]["required"] == ["path"]
      assert open["inputSchema"]["properties"]["path"]["type"] == "string"

      save = Enum.find(tools, &(&1["name"] == "save_file"))
      assert save["inputSchema"]["required"] == []
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

    test "a replace tool-call edits a range in the live buffer" do
      request(1, "tools/call", %{
        "name" => "insert",
        "arguments" => %{"line" => 0, "col" => 0, "text" => "hello world"}
      })

      replace = %{
        "name" => "replace",
        "arguments" => %{
          "start_line" => 0,
          "start_col" => 6,
          "end_line" => 0,
          "end_col" => 11,
          "text" => "there"
        }
      }

      %{"result" => result} = frame(request(2, "tools/call", replace))

      assert result["isError"] == false
      assert [%{"text" => "hello there"}] = result["content"]
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

  describe "tools/call — operation tools (open_file/save_file, ADR-0019)" do
    setup do
      on_exit(fn -> Session.set_active_buffer(nil) end)
      :ok
    end

    test "open_file loads a file, makes it the active buffer, and returns its text" do
      path = tmp_path()
      File.write!(path, "alpha\nbeta\n")

      %{"result" => result} = open_file_tool(1, path)
      assert result["isError"] == false
      assert [%{"type" => "text", "text" => "alpha\nbeta\n"}] = result["content"]

      # the opened file is now the active buffer
      assert {:ok, snap} = Session.snapshot()
      assert snap.text == "alpha\nbeta\n"
    end

    test "open a missing file → fresh empty buffer (created on first save_file)" do
      path = tmp_path()
      refute File.exists?(path)

      %{"result" => result} = open_file_tool(1, path)
      assert result["isError"] == false
      assert [%{"text" => ""}] = result["content"]

      %{"result" => saved} =
        frame(request(2, "tools/call", %{"name" => "save_file", "arguments" => %{}}))

      assert saved["isError"] == false
      assert File.read!(path) == ""
    end

    test "the full loop: open → edit → save lands on disk (dogfood == production)" do
      path = tmp_path()
      File.write!(path, "hello\nworld\n")

      open_file_tool(1, path)

      edit = %{"name" => "insert", "arguments" => %{"line" => 0, "col" => 5, "text" => " there"}}
      %{"result" => edited} = frame(request(2, "tools/call", edit))
      assert edited["isError"] == false

      %{"result" => saved} =
        frame(request(3, "tools/call", %{"name" => "save_file", "arguments" => %{}}))

      assert saved["isError"] == false
      assert [%{"text" => text}] = saved["content"]
      assert text =~ "saved "
      assert File.read!(path) == "hello there\nworld\n"

      # the headline ADR-0019 invariant: open_file + save_file added nothing to the
      # undo history — only the one edit is recorded.
      assert {:ok, %{history: [_only_the_edit]}} = Session.snapshot()
    end

    test "the edit recorded through the loop is provenance-tagged LLM" do
      path = tmp_path()
      File.write!(path, "")
      open_file_tool(1, path)

      frame(
        request(2, "tools/call", %{
          "name" => "insert",
          "arguments" => %{"line" => 0, "col" => 0, "text" => "x"}
        })
      )

      assert {:ok, %{history: [recorded]}} = Session.snapshot()
      assert recorded.meta.actor == {:llm, "unknown"}
    end

    test "save_file with no active buffer → isError result" do
      Session.set_active_buffer(nil)

      %{"result" => result} =
        frame(request(1, "tools/call", %{"name" => "save_file", "arguments" => %{}}))

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ ":no_active_buffer"
    end

    test "save_file when the active buffer has no path → isError result" do
      scratch = start_supervised!({Buffer, text: "scratch"})
      Session.set_active_buffer(scratch)

      %{"result" => result} =
        frame(request(1, "tools/call", %{"name" => "save_file", "arguments" => %{}}))

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ ":no_path"
    end

    test "open_file with a missing path arg → isError result (SEP-1303), not -32602" do
      %{"result" => result} =
        frame(request(1, "tools/call", %{"name" => "open_file", "arguments" => %{}}))

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "Invalid arguments"
    end

    test "re-opening an already-open file reuses the buffer (keeps unsaved edits)" do
      path = tmp_path()
      File.write!(path, "original\n")
      open_file_tool(1, path)

      frame(
        request(2, "tools/call", %{
          "name" => "insert",
          "arguments" => %{"line" => 0, "col" => 0, "text" => "X"}
        })
      )

      # re-open the same path: the in-memory edit must survive (no clobber-from-disk)
      %{"result" => reopened} = open_file_tool(3, path)
      assert [%{"text" => "Xoriginal\n"}] = reopened["content"]
    end

    test ~s(an explicit "arguments": null coalesces to empty args, not -32602) do
      # some clients serialize an omitted/empty arguments object as JSON null
      params = %{"name" => "open_file", "arguments" => nil}
      %{"result" => result} = frame(request(1, "tools/call", params))

      # reaches the handler (then fails arg validation as an isError result), rather
      # than a hard -32602 "arguments must be an object"
      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "Invalid arguments"
    end
  end

  describe "the one parser (§1/§15a): MCP args and typed args agree" do
    test "string-valued and typed args parse to the same %Command{}" do
      assert Insert.parse(%{"line" => "0", "col" => "5", "text" => " w"}) ==
               Insert.parse(%{line: 0, col: 5, text: " w"})
    end
  end
end
