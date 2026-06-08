defmodule Geex.MCP.PortTest do
  # async: false — touches the GEEX_MCP_PORT_FILE environment variable.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Geex.MCP.Port

  test "resolve/1 keeps a pinned port and auto-assigns a free one for 0" do
    assert Port.resolve(4321) == 4321

    auto = Port.resolve(0)
    assert auto in 1..65535
    assert auto != 0
  end

  test "free/0 returns a genuinely free loopback port (bindable right now)" do
    port = Port.free()
    assert port in 1..65535

    {:ok, socket} = :gen_tcp.listen(port, [{:ip, {127, 0, 0, 1}}, {:active, false}])
    :gen_tcp.close(socket)
  end

  test "url/1 is the loopback MCP URL" do
    assert Port.url(4000) == "http://127.0.0.1:4000/mcp"
  end

  describe "write_file/1 (port-file discovery, like pharos)" do
    test "writes the URL when GEEX_MCP_PORT_FILE is set" do
      path = Path.join(System.tmp_dir!(), "geex_port_#{System.unique_integer([:positive])}")
      System.put_env("GEEX_MCP_PORT_FILE", path)
      on_exit(fn -> System.delete_env("GEEX_MCP_PORT_FILE"); File.rm(path) end)

      assert Port.write_file(4242) == path
      assert File.read!(path) == "http://127.0.0.1:4242/mcp\n"
    end

    test "is a no-op (nil) when GEEX_MCP_PORT_FILE is unset" do
      System.delete_env("GEEX_MCP_PORT_FILE")
      assert Port.write_file(4242) == nil
    end
  end

  test "announce/1 logs the bound URL" do
    System.delete_env("GEEX_MCP_PORT_FILE")

    log = capture_log([level: :info], fn -> assert Port.announce(4000) == nil end)
    assert log =~ "serving http://127.0.0.1:4000/mcp"
  end
end
