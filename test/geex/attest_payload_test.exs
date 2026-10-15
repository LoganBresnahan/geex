defmodule Geex.AttestPayloadTest do
  # The captAInHook payload (`integrations/captainhook/geex-attest.sh`, ADR-0032 step d) run
  # for real: the real Claude Code envelopes in test/fixtures/claude-code on stdin, a real
  # discovery file, and a real loopback listener. Discovery is a named singleton.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, BufferSupervisor, Reconcile}
  alias Geex.Attest.Discovery

  @payload Path.expand("../../integrations/captainhook/geex-attest.sh", __DIR__)
  @fixtures Path.expand("../fixtures/claude-code", __DIR__)

  missing = Enum.reject(~w(sh jq curl sha256sum), &System.find_executable/1)
  if missing != [], do: @moduletag(skip: "needs #{Enum.join(missing, ", ")}")

  # `/tap` records what arrived and answers like geex would; `/attest` is the real intake.
  defmodule Tap do
    @behaviour Plug
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(%{request_path: "/attest"} = conn, _test_pid),
      do: Geex.Attest.HTTP.call(conn, Geex.Attest.HTTP.init([]))

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:tapped, conn.request_path, get_req_header(conn, "authorization"), body})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s|{"status":"pending"}|)
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_payload_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    bandit =
      start_supervised!(
        {Bandit, plug: {Tap, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    %{dir: dir, base: "http://127.0.0.1:#{port}"}
  end

  defp listen(%{dir: dir, base: base}, route) do
    start_supervised!({Discovery, url: base <> route, dir: Path.join(dir, "disc")})
    Discovery.token()
  end

  defp hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # The fixture's PostToolUse line (or PreToolUse), with only the captured path swapped.
  defp envelope(name, which \\ :post) do
    [pre, post] = @fixtures |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
    if which == :pre, do: pre, else: post
  end

  defp captured_path(line) do
    input = JSON.decode!(line)["event"]["payload"]["tool_input"]
    input["file_path"] || input["notebook_path"]
  end

  defp retarget(line, path), do: String.replace(line, captured_path(line), path)

  defp run(%{dir: dir}, line, env \\ []) do
    stdin = Path.join(dir, "envelope.json")
    stderr = Path.join(dir, "stderr")
    File.write!(stdin, line)

    {stdout, status} =
      System.cmd("sh", ["-c", ~s|exec "$0" <"$1" 2>"$2"|, @payload, stdin, stderr],
        env: [{"GEEX_ATTEST_DIR", Path.join(dir, "disc")} | env]
      )

    %{stdout: stdout, status: status, stderr: File.read!(stderr)}
  end

  defp target(%{dir: dir}, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  describe "what it sends, per real envelope" do
    for {fixture, original_key} <- [
          {"edit.jsonl", "originalFile"},
          {"write-update.jsonl", "originalFile"},
          {"notebook-edit.jsonl", "original_file"}
        ] do
      test "#{fixture}: the message, its hashes, and the bearer token", ctx do
        token = listen(ctx, "/tap")
        line = envelope(unquote(fixture))
        payload = JSON.decode!(line)["event"]["payload"]
        path = target(ctx, "file", "on disk after the call\n")

        assert %{status: 0, stdout: "", stderr: ""} = run(ctx, retarget(line, path))
        assert_receive {:tapped, "/tap", [auth], body}, 2_000
        assert auth == "Bearer " <> token

        assert JSON.decode!(body) == %{
                 "v" => 1,
                 "path" => path,
                 "before" => hex(payload["tool_response"][unquote(original_key)]),
                 "sha256" => hex("on disk after the call\n"),
                 "harness" => "claude-code",
                 "session" => payload["session_id"],
                 "turn" => payload["prompt_id"],
                 "tool_use" => payload["tool_use_id"]
               }
      end
    end

    for fixture <- ~w(write-create.jsonl read-text.jsonl read-notebook.jsonl bash.jsonl) do
      test "#{fixture}: sends nothing", ctx do
        listen(ctx, "/tap")
        line = envelope(unquote(fixture))
        line = if captured_path(line), do: retarget(line, target(ctx, "f", "x\n")), else: line

        assert %{status: 0, stdout: ""} = run(ctx, line)
        refute_receive {:tapped, _, _, _}, 200
      end
    end

    test "a PreToolUse envelope sends nothing", ctx do
      listen(ctx, "/tap")
      line = envelope("edit.jsonl", :pre) |> retarget(target(ctx, "f", "x\n"))
      assert %{status: 0, stdout: ""} = run(ctx, line)
      refute_receive {:tapped, _, _, _}, 200
    end

    test "another harness sends nothing", ctx do
      listen(ctx, "/tap")
      line = envelope("edit.jsonl") |> retarget(target(ctx, "f", "x\n"))
      line = String.replace(line, ~s|"harness":"claude-code"|, ~s|"harness":"other"|)
      assert %{status: 0, stdout: ""} = run(ctx, line)
      refute_receive {:tapped, _, _, _}, 200
    end

    test "a NotebookEdit that reports an error sends nothing", ctx do
      listen(ctx, "/tap")
      line = envelope("notebook-edit.jsonl") |> retarget(target(ctx, "nb", "{}\n"))
      line = String.replace(line, ~s|"error":""|, ~s|"error":"boom"|)
      assert %{status: 0, stdout: ""} = run(ctx, line)
      refute_receive {:tapped, _, _, _}, 200
    end
  end

  describe "fail-open and the discovery files" do
    test "garbage in: exit 0, no stdout, a note on stderr", ctx do
      listen(ctx, "/tap")
      assert %{status: 0, stdout: "", stderr: err} = run(ctx, "{not json")
      assert err =~ "did not parse"
    end

    test "no geex listening: exit 0 at once", ctx do
      line = envelope("edit.jsonl") |> retarget(target(ctx, "f", "x\n"))
      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, line)
    end

    test "skips a dead pid, a non-loopback url and a bad token; reports a refused POST", ctx do
      token = listen(ctx, "/tap")
      disc = Path.join(ctx.dir, "disc")
      {dead, 0} = System.cmd("sh", ["-c", "echo $$"])
      live = System.pid()

      for {name, url, tok, pid} <- [
            {"second", ctx.base <> "/second", token, live},
            {"stale", ctx.base <> "/stale", token, String.trim(dead)},
            {"named", String.replace(ctx.base, "127.0.0.1", "localhost") <> "/named", token, live},
            {"badtoken", ctx.base <> "/badtoken", "not-hex", live},
            {"closed", "http://127.0.0.1:1/attest", token, live}
          ] do
        file = Path.join(disc, name <> ".json")
        File.write!(file, JSON.encode!(%{"v" => 1, "url" => url, "token" => tok, "pid" => pid}))
        File.chmod!(file, 0o600)
      end

      line = envelope("edit.jsonl") |> retarget(target(ctx, "f", "x\n"))
      assert %{status: 0, stdout: "", stderr: err} = run(ctx, line)

      # only the two live loopback instances were sent to
      assert_receive {:tapped, "/tap", _, _}, 2_000
      assert_receive {:tapped, "/second", _, _}, 2_000
      refute_receive {:tapped, _, _, _}, 200
      assert err =~ "127.0.0.1:1/attest answered 000"
    end

    test "macOS-style: no sha256sum, falls back to shasum -a 256", ctx do
      listen(ctx, "/tap")
      bin = Path.join(ctx.dir, "bin")
      File.mkdir_p!(bin)

      for tool <- ~w(cat jq curl),
          do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

      # a stand-in that insists on the macOS arguments
      shasum = Path.join(bin, "shasum")
      sha256sum = System.find_executable("sha256sum")
      File.write!(shasum, ~s|#!/bin/sh\n[ "$1 $2" = "-a 256" ] \|\| exit 9\nexec #{sha256sum}\n|)
      File.chmod!(shasum, 0o755)

      line = envelope("edit.jsonl") |> retarget(target(ctx, "f", "mac\n"))
      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, line, [{"PATH", bin}])
      assert_receive {:tapped, "/tap", _, body}, 2_000
      assert JSON.decode!(body)["sha256"] == hex("mac\n")
    end
  end

  describe "end to end: payload -> POST /attest -> the buffer" do
    setup ctx do
      listen(ctx, "/attest")
      :ok
    end

    defp open(path) do
      {:ok, buf} = BufferSupervisor.start_buffer(Path.expand(path))

      on_exit(fn ->
        if Process.alive?(buf), do: DynamicSupervisor.terminate_child(BufferSupervisor, buf)
      end)

      buf
    end

    # An envelope from a real fixture, its prior text and path replaced.
    defp agent_write(fixture, path, original) do
      fixture
      |> envelope()
      |> JSON.decode!()
      |> put_in(["event", "payload", "tool_input", "file_path"], path)
      |> put_in(["event", "payload", "tool_response", "originalFile"], original)
      |> JSON.encode!()
    end

    test "an Edit: attested before reconcile (pending), credited when the group lands", ctx do
      path = target(ctx, "e2e.txt", "one\ntwo\n")
      buf = open(path)
      File.write!(path, "one\nTWO\n")

      assert %{status: 0, stderr: ""} = run(ctx, agent_write("edit.jsonl", path, "one\ntwo\n"))
      {:reconciled, snap} = Reconcile.reconcile(buf, "one\nTWO\n")

      payload = JSON.decode!(envelope("edit.jsonl"))["event"]["payload"]

      assert [%{meta: %{actor: {:agent, who}}}] = snap.history
      assert who == %{
               harness: "claude-code",
               session: payload["session_id"],
               turn: payload["prompt_id"],
               tool_use: payload["tool_use_id"]
             }
    end

    test "a Write over a CRLF file (rewritten as LF) is credited", ctx do
      path = target(ctx, "crlf.txt", "one\r\ntwo\r\n")
      buf = open(path)
      File.write!(path, "one\nTWO\n")
      {:reconciled, _} = Reconcile.reconcile(buf, "one\nTWO\n")

      # Claude Code reports the CRLF file's prior text with "\r\n" as "\n"
      assert %{status: 0, stderr: ""} = run(ctx, agent_write("write-update.jsonl", path, "one\ntwo\n"))
      assert [{:agent, %{harness: "claude-code"}}] = Enum.map(Buffer.history(buf), & &1.meta.actor)
    end
  end
end
