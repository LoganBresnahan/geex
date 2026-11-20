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
    dir = Path.join(System.tmp_dir!(), "geex_payload_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Tap, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
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

    # ADR-0034 §8. The fixtures above report `userModified: false`, and their message has no
    # `user_modified` (the exact maps above); set to true, it is sent.
    test "userModified: true (you edited the proposal) adds user_modified", ctx do
      listen(ctx, "/tap")
      path = target(ctx, "file", "after\n")

      line =
        envelope("edit.jsonl")
        |> retarget(path)
        |> JSON.decode!()
        |> put_in(["event", "payload", "tool_response", "userModified"], true)
        |> JSON.encode!()

      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, line)
      assert_receive {:tapped, "/tap", _, body}, 2_000
      assert %{"user_modified" => true, "tool_use" => _} = JSON.decode!(body)
    end

    # ADR-0032, amended 2026-10-18: a file the call created is sent as created, with no before.
    test "write-create.jsonl: created, no before", ctx do
      listen(ctx, "/tap")
      line = envelope("write-create.jsonl")
      payload = JSON.decode!(line)["event"]["payload"]
      assert payload["tool_response"]["type"] == "create"
      assert payload["tool_response"]["originalFile"] == nil
      path = target(ctx, "new", "alpha\nbeta\n")

      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, retarget(line, path))
      assert_receive {:tapped, "/tap", _, body}, 2_000

      assert JSON.decode!(body) == %{
               "v" => 1,
               "path" => path,
               "created" => true,
               "sha256" => hex("alpha\nbeta\n"),
               "harness" => "claude-code",
               "session" => payload["session_id"],
               "turn" => payload["prompt_id"],
               "tool_use" => payload["tool_use_id"]
             }
    end

    test "a writer reporting no prior text that didn't create the file sends nothing", ctx do
      listen(ctx, "/tap")

      for {fixture, type} <- [{"write-update.jsonl", "update"}, {"edit.jsonl", "create"}] do
        line =
          envelope(fixture)
          |> retarget(target(ctx, "f", "x\n"))
          |> JSON.decode!()
          |> put_in(["event", "payload", "tool_response", "originalFile"], nil)
          |> put_in(["event", "payload", "tool_response", "type"], type)
          |> JSON.encode!()

        assert %{status: 0, stdout: ""} = run(ctx, line)
        refute_receive {:tapped, _, _, _}, 200
      end
    end

    for fixture <- ~w(read-text.jsonl read-notebook.jsonl bash.jsonl) do
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
            {"named", String.replace(ctx.base, "127.0.0.1", "localhost") <> "/named", token,
             live},
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

    test "drops a dead geex's own file; keeps a link, another name, and a live one", ctx do
      disc = Path.join(ctx.dir, "disc")
      File.mkdir_p!(disc)
      dead = fn -> System.cmd("sh", ["-c", "echo $$"]) |> elem(0) |> String.trim() end
      [gone, linked, renamed] = [dead.(), dead.(), dead.()]
      live = System.pid()

      write = fn name, pid ->
        file = Path.join(disc, name)
        message = %{"v" => 1, "url" => "http://127.0.0.1:1/attest", "token" => "ab", "pid" => pid}
        File.write!(file, JSON.encode!(message))
        File.chmod!(file, 0o600)
        file
      end

      gone_file = write.("#{gone}.json", gone)
      renamed_file = write.("other.json", renamed)
      live_file = write.("#{live}.json", live)
      target = write.("target", linked)
      link = Path.join(disc, "#{linked}.json")
      File.ln_s!(target, link)

      line = envelope("edit.jsonl") |> retarget(target(ctx, "f", "x\n"))
      assert %{status: 0, stdout: ""} = run(ctx, line)

      refute File.exists?(gone_file)
      assert File.exists?(renamed_file)
      assert File.exists?(live_file)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert File.exists?(target)
    end

    test "macOS-style: no sha256sum, falls back to shasum -a 256", ctx do
      listen(ctx, "/tap")
      bin = Path.join(ctx.dir, "bin")
      File.mkdir_p!(bin)

      for tool <- ~w(cat jq curl mktemp rm wc tail mv),
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

  describe "the spool (ADR-0033 F): attestations no geex took" do
    defp state_env(ctx), do: [{"XDG_STATE_HOME", Path.join(ctx.dir, "state")}]
    defp ledger_dir(ctx), do: Path.join([ctx.dir, "state", "geex", "ledger"])

    defp with_ledger(ctx, path) do
      File.mkdir_p!(ledger_dir(ctx))
      File.write!(Geex.Ledger.file(ledger_dir(ctx), path), "{}\n")
    end

    defp spooled(ctx, path) do
      spool = Geex.Ledger.Spool.file(Geex.Ledger.file(ledger_dir(ctx), path))

      case File.read(spool) do
        {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
        {:error, _} -> []
      end
    end

    test "no geex running, and geex keeps a ledger for the file: spooled, 0600", ctx do
      path = target(ctx, "f", "after\n")
      with_ledger(ctx, path)
      line = envelope("edit.jsonl") |> retarget(path)

      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, line, state_env(ctx))
      assert [entry] = spooled(ctx, path)
      assert %{"path" => ^path, "harness" => "claude-code", "at" => _} = entry
      assert entry["sha256"] == hex("after\n")

      spool = Geex.Ledger.Spool.file(Geex.Ledger.file(ledger_dir(ctx), path))
      assert File.stat!(spool).mode |> Bitwise.band(0o777) == 0o600
    end

    test "no ledger for the file: nothing spooled", ctx do
      path = target(ctx, "f", "after\n")
      assert %{status: 0} = run(ctx, envelope("edit.jsonl") |> retarget(path), state_env(ctx))
      assert spooled(ctx, path) == []
      refute File.exists?(ledger_dir(ctx))
    end

    test "a geex that took it (pending) means no spool; not_open everywhere means spool", ctx do
      listen(ctx, "/tap")
      path = target(ctx, "f", "after\n")
      with_ledger(ctx, path)
      line = envelope("edit.jsonl") |> retarget(path)

      assert %{status: 0} = run(ctx, line, state_env(ctx))
      assert_receive {:tapped, "/tap", _, _}, 2_000
      assert spooled(ctx, path) == []

      stop_supervised!(Discovery)
      listen(ctx, "/attest")
      assert %{status: 0} = run(ctx, line, state_env(ctx))
      assert [_entry] = spooled(ctx, path)
    end

    test "end to end: the payload spools while the file is closed; reopening credits it", ctx do
      path = target(ctx, "e2e.txt", "one\ntwo\n")
      {:ok, buf} = Geex.Buffer.start_link(path: path, ledger_dir: ledger_dir(ctx))
      Process.unlink(buf)
      {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "0"})
      {:ok, _} = Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))
      {:ok, _} = Buffer.save(buf)
      GenServer.stop(buf, :shutdown)

      # an agent edits the closed file
      File.write!(path, "0one\nTWO\n")

      assert %{status: 0, stderr: ""} =
               run(ctx, agent_write("edit.jsonl", path, "0one\ntwo\n"), state_env(ctx))

      {:ok, buf} = Geex.Buffer.start_link(path: path, ledger_dir: ledger_dir(ctx))
      Process.unlink(buf)
      payload = JSON.decode!(envelope("edit.jsonl"))["event"]["payload"]
      gap = List.last(Buffer.history(buf))

      assert gap.meta.actor ==
               {:agent,
                %{
                  harness: "claude-code",
                  session: payload["session_id"],
                  turn: payload["prompt_id"],
                  tool_use: payload["tool_use_id"]
                }}

      GenServer.stop(buf, :shutdown)
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

    test "an Edit: held by the open buffer, credited when you fast-forward", ctx do
      path = target(ctx, "e2e.txt", "one\ntwo\n")
      buf = open(path)
      File.write!(path, "one\nTWO\n")

      assert %{status: 0, stderr: ""} = run(ctx, agent_write("edit.jsonl", path, "one\ntwo\n"))
      assert Buffer.get_text(buf) == "one\ntwo\n"
      {:fast_forwarded, snap, 0} = Reconcile.fast_forward(buf)

      payload = JSON.decode!(envelope("edit.jsonl"))["event"]["payload"]

      assert [%{meta: %{actor: {:agent, who}}}] = snap.history

      assert who == %{
               harness: "claude-code",
               session: payload["session_id"],
               turn: payload["prompt_id"],
               tool_use: payload["tool_use_id"]
             }
    end

    # ADR-0032's 2026-11-18 amendment: a Bash call, bracketed, held, credited "while".
    test "a Bash call: held by the open buffer, credited while python3 at the fast-forward",
         ctx do
      repo = Path.join(ctx.dir, "bashrepo")
      File.mkdir_p!(repo)
      path = Path.join(repo, "f.txt")
      File.write!(path, "one\ntwo\n")

      for args <- [
            ["init", "-q"],
            ["add", "-A"],
            ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "i"]
          ],
          do: {_, 0} = System.cmd("git", args, cd: repo)

      buf = open(path)
      command = "cd #{repo} && python3 - <<'EOF'\nedit\nEOF"

      bash = fn which ->
        envelope("bash.jsonl", which)
        |> JSON.decode!()
        |> put_in(["event", "cwd"], ctx.dir)
        |> put_in(["event", "payload", "tool_input", "command"], command)
        |> JSON.encode!()
      end

      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, bash.(:pre))
      File.write!(path, "one\nTWO\n")
      assert %{status: 0, stderr: ""} = run(ctx, bash.(:post))
      assert Buffer.get_text(buf) == "one\ntwo\n"
      {:fast_forwarded, snap, 0} = Reconcile.fast_forward(buf)

      payload = JSON.decode!(envelope("bash.jsonl"))["event"]["payload"]
      assert [%{meta: %{actor: {:agent, who}}}] = snap.history

      assert who == %{
               harness: "claude-code",
               session: payload["session_id"],
               turn: payload["prompt_id"],
               tool_use: payload["tool_use_id"],
               during: "Bash",
               program: "python3"
             }
    end

    # ADR-0032, amended 2026-10-18.
    test "a created file no geex has open is listed as the agent's", ctx do
      path = target(ctx, "made.txt", "alpha\nbeta\n")
      assert %{status: 0, stderr: ""} = run(ctx, retarget(envelope("write-create.jsonl"), path))
      payload = JSON.decode!(envelope("write-create.jsonl"))["event"]["payload"]

      assert [%{who: {:agent, %{tool_use: tool_use}}, sha256: sha} | _] =
               Enum.filter(Geex.Edits.rows(), &(&1.path == path))

      assert {tool_use, sha} == {payload["tool_use_id"], hex("alpha\nbeta\n")}
    end

    test "a created file is credited to a buffer that held nothing, not to one with text", ctx do
      # Open on a path that doesn't exist yet: empty.
      empty = Path.join(ctx.dir, "empty.txt")
      buf = open(empty)
      File.write!(empty, "alpha\n")
      assert %{status: 0, stderr: ""} = run(ctx, retarget(envelope("write-create.jsonl"), empty))
      {:fast_forwarded, snap, 0} = Reconcile.fast_forward(buf)
      assert [{:agent, %{harness: "claude-code"}}] = Enum.map(snap.history, & &1.meta.actor)

      # A buffer that held text when the "create" landed: the hashes can't link, so :external.
      full = target(ctx, "full.txt", "already here\n")
      buf = open(full)
      File.write!(full, "alpha\n")
      assert %{status: 0, stderr: ""} = run(ctx, retarget(envelope("write-create.jsonl"), full))
      {:fast_forwarded, snap, 0} = Reconcile.fast_forward(buf)
      assert Enum.uniq(Enum.map(snap.history, & &1.meta.actor)) == [:external]
    end

    test "a Write over a CRLF file (rewritten as LF) is credited", ctx do
      path = target(ctx, "crlf.txt", "one\r\ntwo\r\n")
      buf = open(path)
      File.write!(path, "one\nTWO\n")
      {:reconciled, _} = Reconcile.reconcile(buf, "one\nTWO\n")

      # Claude Code reports the CRLF file's prior text with "\r\n" as "\n"
      assert %{status: 0, stderr: ""} =
               run(ctx, agent_write("write-update.jsonl", path, "one\ntwo\n"))

      assert [{:agent, %{harness: "claude-code"}}] =
               Enum.map(Buffer.history(buf), & &1.meta.actor)
    end

    # ADR-0034: geex answers `held`, which the payload doesn't count as taken, so it spools the
    # attestation as well; the credit survives a crash before the fast-forward.
    test "held: the payload spools it too, so a crash before the fast-forward keeps the credit",
         ctx do
      path = target(ctx, "held.txt", "one\ntwo\n")
      name = {:via, Registry, {Geex.Registry, Path.expand(path)}}
      {:ok, buf} = Buffer.start_link(path: path, ledger_dir: ledger_dir(ctx), name: name)
      Process.unlink(buf)
      # a file with history, so it has a ledger to spool beside
      {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "0"})
      {:ok, _} = Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))
      {:ok, _} = Buffer.save(buf)

      File.write!(path, "0one\nTWO\n")
      Buffer.disk_changed(buf, "0one\nTWO\n")

      assert %{status: 0, stderr: ""} =
               run(ctx, agent_write("edit.jsonl", path, "0one\ntwo\n"), state_env(ctx))

      assert Buffer.get_text(buf) == "0one\ntwo\n"
      assert [_entry] = spooled(ctx, path)

      ref = Process.monitor(buf)
      Process.exit(buf, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      {:ok, buf} = Buffer.start_link(path: path, ledger_dir: ledger_dir(ctx))
      Process.unlink(buf)
      session = JSON.decode!(envelope("edit.jsonl"))["event"]["payload"]["session_id"]
      assert Buffer.get_text(buf) == "0one\nTWO\n"
      assert {:agent, %{session: ^session}} = List.last(Buffer.history(buf)).meta.actor
      GenServer.stop(buf, :shutdown)
    end
  end

  # ADR-0032's 2026-11-18 amendment: a Bash call bracketed by a git snapshot, credited "while".
  describe "Bash: a credit by time" do
    defp git(repo, args), do: {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

    # A git work tree under the test dir, `files` committed.
    defp repo(ctx, name, files, config \\ []) do
      repo = Path.join(ctx.dir, name)
      File.mkdir_p!(repo)
      git(repo, ["init", "-q"])
      for {k, v} <- config, do: git(repo, ["config", k, v])

      for {f, body} <- files do
        File.mkdir_p!(Path.dirname(Path.join(repo, f)))
        File.write!(Path.join(repo, f), body)
      end

      git(repo, ["add", "-A"])
      git(repo, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])
      repo
    end

    # The Bash fixture's PreToolUse (or PostToolUse) line with this cwd and command.
    defp bash(which, cwd, command, input \\ %{}) do
      envelope("bash.jsonl", which)
      |> JSON.decode!()
      |> put_in(["event", "cwd"], cwd)
      |> put_in(["event", "payload", "cwd"], cwd)
      |> update_in(
        ["event", "payload", "tool_input"],
        &Map.merge(&1, Map.put(input, "command", command))
      )
      |> JSON.encode!()
    end

    defp snaps(ctx), do: Path.join([ctx.dir, "disc", "bash"])

    # PreToolUse, then the change, then PostToolUse; every message that arrived, by file name.
    defp bracket(ctx, cwd, command, change, input \\ %{}) do
      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, bash(:pre, cwd, command, input))
      change.()
      assert %{status: 0, stdout: ""} = run(ctx, bash(:post, cwd, command, input))
      received(ctx.dir)
    end

    # Keyed by the path under the test dir ("repo/a.txt").
    defp received(dir, acc \\ %{}) do
      receive do
        {:tapped, "/tap", _, body} ->
          msg = JSON.decode!(body)
          received(dir, Map.put(acc, Path.relative_to(msg["path"], dir), msg))
      after
        300 -> acc
      end
    end

    test "a clean file, a dirty one, a new one and a deleted one: each change sent as during Bash",
         ctx do
      listen(ctx, "/tap")

      repo =
        repo(ctx, "repo", [{"a.txt", "x one\nx two\n"}, {"b.txt", "keep\n"}, {"gone.txt", "g\n"}])

      File.write!(Path.join(repo, "b.txt"), "keep\ndirty\n")
      payload = JSON.decode!(envelope("bash.jsonl"))["event"]["payload"]

      got =
        bracket(ctx, repo, "sed -i 's/x/y/' a.txt && printf 'new\\n' > c.txt", fn ->
          File.write!(Path.join(repo, "a.txt"), "y one\ny two\n")
          File.write!(Path.join(repo, "b.txt"), "keep\ndirty\nmore\n")
          File.write!(Path.join(repo, "c.txt"), "new\n")
          File.rm!(Path.join(repo, "gone.txt"))
        end)

      assert Map.keys(got) |> Enum.sort() == ["repo/a.txt", "repo/b.txt", "repo/c.txt"]

      assert got["repo/a.txt"] == %{
               "v" => 1,
               "path" => Path.join(repo, "a.txt"),
               "before" => hex("x one\nx two\n"),
               "sha256" => hex("y one\ny two\n"),
               "harness" => "claude-code",
               "session" => payload["session_id"],
               "turn" => payload["prompt_id"],
               "tool_use" => payload["tool_use_id"],
               "during" => "Bash",
               "program" => "sed"
             }

      assert %{"before" => before, "sha256" => after_b} = got["repo/b.txt"]
      assert {before, after_b} == {hex("keep\ndirty\n"), hex("keep\ndirty\nmore\n")}
      assert %{"created" => true, "sha256" => created} = got["repo/c.txt"]
      assert created == hex("new\n")
      refute Map.has_key?(got["repo/c.txt"], "before")
      # The snapshot is gone once compared.
      assert File.ls!(snaps(ctx)) == []
    end

    # verifier's review of ba6883f: each case it found, as a test.
    test "a ~ that isn't a home (lodash@~4.17.21, git show @~2, ~nosuchuser): no hang", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])

      for command <- [
            "npm install lodash@~4.17.21",
            "git show @~2",
            "ls ~nosuchuser/x",
            "cd ~- && make",
            "cat ~+"
          ] do
        {micros, result} = :timer.tc(fn -> run(ctx, bash(:pre, repo, command)) end)
        assert %{status: 0, stdout: ""} = result
        assert micros < 1_000_000, "#{command}: #{div(micros, 1000)} ms"
      end
    end

    test "a call whose first line names no program is still credited", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])

      for {command, program} <- [
            {"cd #{repo}\nsed -i s/0/1/ a.txt", "sed"},
            {"export X=1\nmake", "make"},
            {"true", nil},
            {"A=1", nil}
          ] do
        n = System.unique_integer([:positive])

        got =
          bracket(ctx, repo, command, fn -> File.write!(Path.join(repo, "a.txt"), "#{n}\n") end)

        assert %{"during" => "Bash"} = msg = got["repo/a.txt"], command
        assert msg["program"] == program
      end
    end

    test "never created for a file that existed: inside an untracked dir, ignored, or unstaged",
         ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"t.txt", "t\n"}, {".gitignore", "*.log\n"}])
      File.mkdir_p!(Path.join(repo, "newdir"))
      File.write!(Path.join(repo, "newdir/old.txt"), "old\n")
      File.write!(Path.join(repo, "keep.log"), "log\n")

      got =
        bracket(
          ctx,
          repo,
          "git add newdir/b.txt; printf '' > .gitignore; git rm --cached t.txt",
          fn ->
            File.write!(Path.join(repo, "newdir/b.txt"), "b\n")
            git(repo, ["add", "newdir/b.txt"])
            File.write!(Path.join(repo, ".gitignore"), "")
            git(repo, ["rm", "-q", "--cached", "t.txt"])
          end
        )

      refute Map.has_key?(got, "repo/newdir/old.txt")
      refute Map.has_key?(got, "repo/keep.log")
      refute Map.has_key?(got, "repo/t.txt")
      # The file the command named and made is new; .gitignore changed.
      assert %{"created" => true} = got["repo/newdir/b.txt"]
      assert %{"before" => before} = got["repo/.gitignore"]
      assert before == hex("*.log\n")
    end

    test "an edit staged in the same call is credited, before from HEAD", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"f.txt", "A\n"}])

      got =
        bracket(ctx, repo, "sed -i s/A/B/ f.txt && git add f.txt", fn ->
          File.write!(Path.join(repo, "f.txt"), "B\n")
          git(repo, ["add", "f.txt"])
        end)

      assert %{"before" => before, "sha256" => after_f} = got["repo/f.txt"]
      assert {before, after_f} == {hex("A\n"), hex("B\n")}
    end

    test "a path with a space is credited; a symlink never is", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a b.txt", "0\n"}, {"real.txt", "r\n"}])
      File.ln_s!(Path.join(repo, "real.txt"), Path.join(repo, "link.txt"))

      got =
        bracket(ctx, repo, "sed -i s/0/1/ 'a b.txt'", fn ->
          File.write!(Path.join(repo, "a b.txt"), "1\n")
          File.write!(Path.join(repo, "real.txt"), "R\n")
        end)

      assert %{"before" => before} = got["repo/a b.txt"]
      assert before == hex("0\n")
      refute Map.has_key?(got, "repo/link.txt")
    end

    test "the program past sudo -u, nice -n and env -u options", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])

      for {command, program} <- [
            {"sudo -u root sed -i x a.txt", "sed"},
            {"nice -n 5 make", "make"},
            {"env -u FOO prettier --write a.txt", "prettier"}
          ] do
        n = System.unique_integer([:positive])

        got =
          bracket(ctx, repo, command, fn -> File.write!(Path.join(repo, "a.txt"), "#{n}\n") end)

        assert %{"program" => ^program} = got["repo/a.txt"], command
      end
    end

    test "a snapshot from another session, or over an hour old, is refused", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])
      assert %{status: 0} = run(ctx, bash(:pre, repo, "true"))
      [snap] = File.ls!(snaps(ctx))
      path = Path.join(snaps(ctx), snap)
      kept = File.read!(path)

      File.write!(path, String.replace(kept, ~r/^session\t.*$/m, "session\tsomeone-else"))
      File.write!(Path.join(repo, "a.txt"), "1\n")
      assert %{status: 0} = run(ctx, bash(:post, repo, "true"))
      refute_receive {:tapped, _, _, _}, 300

      File.write!(
        path,
        String.replace(kept, ~r/^at\t.*$/m, "at\t#{System.os_time(:second) - 7200}")
      )

      assert %{status: 0} = run(ctx, bash(:post, repo, "true"))
      refute_receive {:tapped, _, _, _}, 300
      refute File.exists?(path)
    end

    test "more changed files than one PostToolUse sends (150): none, a clean miss", ctx do
      listen(ctx, "/tap")
      files = for i <- 1..151, do: {"f#{i}.txt", "#{i}\n"}
      repo = repo(ctx, "repo", files)

      got =
        bracket(ctx, repo, "sed -i s/^/x/ f*.txt", fn ->
          for {f, body} <- files, do: File.write!(Path.join(repo, f), "x" <> body)
        end)

      assert got == %{}
    end

    # verifier's rev 2 re-check.
    test "a reset or a commit in the call claims nothing for a file whose disk never changed",
         ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"f.txt", "C1\n"}])
      File.write!(Path.join(repo, "f.txt"), "C2\n")
      git(repo, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "two"])

      for reset <- [["reset", "-q", "--soft", "HEAD~1"], ["reset", "-q", "HEAD~1"]] do
        got = bracket(ctx, repo, "git " <> Enum.join(reset, " "), fn -> git(repo, reset) end)
        assert got == %{}, inspect(reset)
        git(repo, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "again"])
      end

      # An edit committed in the same call ends clean: missed, never a wrong claim.
      got =
        bracket(ctx, repo, "sed -i s/C2/C3/ f.txt && git commit -qam three", fn ->
          File.write!(Path.join(repo, "f.txt"), "C3\n")
          git(repo, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "three"])
        end)

      assert got == %{}
    end

    test "an unreadable changed file costs only its own credit, never a second POST", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "a\n"}, {"b.txt", "b\n"}, {"c.txt", "c\n"}])

      got =
        bracket(ctx, repo, "sed -i s/^/x/ a.txt b.txt c.txt", fn ->
          for f <- ~w(a.txt b.txt c.txt), do: File.write!(Path.join(repo, f), "x\n")
          File.chmod!(Path.join(repo, "b.txt"), 0o000)
        end)

      File.chmod!(Path.join(repo, "b.txt"), 0o644)
      assert Map.keys(got) |> Enum.sort() == ["repo/a.txt", "repo/c.txt"]
      refute_receive {:tapped, _, _, _}, 200
    end

    test "the 150-file skip says so on stderr, for captAInHook's trail", ctx do
      files = for i <- 1..151, do: {"f#{i}.txt", "#{i}\n"}
      repo = repo(ctx, "repo", files)
      assert %{status: 0, stdout: ""} = run(ctx, bash(:pre, repo, "sed -i s/^/x/ f*.txt"))
      for {f, body} <- files, do: File.write!(Path.join(repo, f), "x" <> body)

      assert %{status: 0, stdout: "", stderr: stderr} =
               run(ctx, bash(:post, repo, "sed -i s/^/x/ f*.txt"))

      assert stderr =~ "151 files to compare after the Bash call (over 150); nothing sent"
    end

    test "the program through time -p, a subshell, a comment line and a continuation", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])

      for {command, program} <- [
            {"time -p make", "make"},
            {"(cd sub && make)", "make"},
            {"# build it\nmake -j4", "make"},
            {"FOO=1 \\\n  make \\\n  -j4", "make"}
          ] do
        n = System.unique_integer([:positive])

        got =
          bracket(ctx, repo, command, fn -> File.write!(Path.join(repo, "a.txt"), "#{n}\n") end)

        assert %{"program" => ^program} = got["repo/a.txt"], inspect(command)
      end
    end

    test "a named path through a symlinked directory is new where it lands; one leaving the tree is not",
         ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"sub/keep.txt", "k\n"}])
      outside = Path.join(ctx.dir, "elsewhere")
      File.mkdir_p!(outside)
      File.ln_s!(Path.join(repo, "sub"), Path.join(repo, "via"))
      File.ln_s!(outside, Path.join(repo, "out"))
      git(repo, ["add", "via", "out"])
      git(repo, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "links"])

      got =
        bracket(ctx, repo, "printf n > via/new.txt; printf o > out/x.txt", fn ->
          File.write!(Path.join(repo, "sub/new.txt"), "n")
          File.write!(Path.join(outside, "x.txt"), "o")
        end)

      assert Map.keys(got) == ["repo/sub/new.txt"]
      assert %{"created" => true} = got["repo/sub/new.txt"]
    end

    # verifier's rev 3 re-check.
    test "the cap counts real changes: 160 untouched untracked files don't hide one edit", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"f.txt", "0\n"}])
      for i <- 1..160, do: File.write!(Path.join(repo, "u#{i}.txt"), "#{i}\n")

      got =
        bracket(ctx, repo, "sed -i s/0/1/ f.txt", fn ->
          File.write!(Path.join(repo, "f.txt"), "1\n")
        end)

      assert Map.keys(got) == ["repo/f.txt"]
    end

    test "a dangling link the call makes real can't credit a file outside the tree", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"keep.txt", "k\n"}])
      outside = Path.join(ctx.dir, "made-later")
      File.ln_s!(outside, Path.join(repo, "dl"))

      got =
        bracket(ctx, repo, "mkdir #{outside}; printf n > dl/new.txt; printf t > top.txt", fn ->
          File.mkdir_p!(outside)
          File.write!(Path.join(outside, "new.txt"), "n")
          File.write!(Path.join(repo, "top.txt"), "t")
        end)

      # The new file at the top of the tree is still credited; the one through the link isn't.
      assert Map.keys(got) == ["repo/top.txt"]
    end

    # Item 8 (the maintainer's word, 2026-11-19): git runs before the permission prompt, in trees
    # a command merely names, so nothing a repository configures may run, nor the index change.
    test "a booby-trapped repository: no fsmonitor, no filter runs, the index untouched; a filtered file isn't credited",
         ctx do
      listen(ctx, "/tap")

      repo =
        repo(ctx, "repo", [
          {"plain.txt", "p\n"},
          {"lfs.bin", "l\n"},
          {".gitattributes", "*.bin filter=evil\n"}
        ])

      marker = Path.join(ctx.dir, "ran")
      trap = Path.join(ctx.dir, "trap.sh")
      File.write!(trap, "#!/bin/sh\necho \"$0 $*\" >> #{marker}\ncat\n")
      File.chmod!(trap, 0o755)
      git(repo, ["config", "core.fsmonitor", trap])
      git(repo, ["config", "filter.evil.clean", "#{trap} clean"])
      git(repo, ["config", "filter.evil.smudge", "#{trap} smudge"])
      git(repo, ["config", "filter.evil.process", "#{trap} process"])
      index = Path.join([repo, ".git", "index"])
      # Changed before the call, so `status` would run the clean filter on them.
      Process.sleep(1100)
      File.write!(Path.join(repo, "lfs.bin"), "L\n")
      outside = Path.join(ctx.dir, "outside")
      File.mkdir_p!(outside)
      before_index = File.stat!(index).mtime

      got =
        bracket(
          ctx,
          outside,
          "cat #{repo}/plain.txt; sed -i s/p/q/ #{repo}/plain.txt #{repo}/lfs.bin",
          fn ->
            File.write!(Path.join(repo, "plain.txt"), "q\n")
            File.write!(Path.join(repo, "lfs.bin"), "LL\n")
          end
        )

      refute File.exists?(marker)
      assert File.stat!(index).mtime == before_index
      assert Map.keys(got) == ["repo/plain.txt"]
      assert %{"before" => before} = got["repo/plain.txt"]
      assert before == hex("p\n")
    end

    # verifier's item 8 check.
    test "a partial clone is refused at PreToolUse and PostToolUse: its remote's program never runs",
         ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"f.txt", "0\n"}])
      marker = Path.join(ctx.dir, "fetched")
      trap = Path.join(ctx.dir, "upload.sh")
      File.write!(trap, "#!/bin/sh\necho ran >> #{marker}\nexit 1\n")
      File.chmod!(trap, 0o755)
      git(repo, ["config", "core.repositoryformatversion", "1"])
      git(repo, ["config", "extensions.partialClone", "origin"])
      git(repo, ["config", "remote.origin.url", "file:///nowhere"])
      git(repo, ["config", "remote.origin.promisor", "true"])
      git(repo, ["config", "remote.origin.uploadpack", trap])
      git(repo, ["config", "core.autocrlf", "true"])

      assert %{status: 0, stdout: ""} = run(ctx, bash(:pre, repo, "ls #{repo}"))
      # No snapshot names the refused tree (here, none is written at all).
      written =
        case File.ls(snaps(ctx)) do
          {:ok, list} -> list
          _ -> []
        end

      refute Enum.any?(written, &(File.read!(Path.join(snaps(ctx), &1)) =~ "root\t#{repo}"))

      got =
        bracket(ctx, repo, "sed -i s/0/1/ f.txt", fn ->
          File.write!(Path.join(repo, "f.txt"), "1\n")
        end)

      assert got == %{}
      refute File.exists?(marker)
    end

    test "with a git older than 2.31: no snapshot, nothing sent, one stderr line", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])
      bin = Path.join(ctx.dir, "oldbin")
      File.mkdir_p!(bin)
      real = System.find_executable("git")
      fake = Path.join(bin, "git")

      File.write!(fake, """
      #!/bin/sh
      [ "$1" = version ] && { echo "git version 2.30.9"; exit 0; }
      exec #{real} "$@"
      """)

      File.chmod!(fake, 0o755)
      env = [{"PATH", bin <> ":" <> System.get_env("PATH")}]

      assert %{status: 0, stdout: "", stderr: stderr} =
               run(ctx, bash(:pre, repo, "sed -i s/0/1/ a.txt"), env)

      assert stderr =~ "git version 2.30.9 is older than 2.31; Bash changes aren't credited"
      refute File.exists?(snaps(ctx)) and File.ls!(snaps(ctx)) != []
      File.write!(Path.join(repo, "a.txt"), "1\n")
      assert %{status: 0, stdout: ""} = run(ctx, bash(:post, repo, "sed -i s/0/1/ a.txt"), env)
      refute_receive {:tapped, _, _, _}, 300
    end

    test "a geex that accepts but never answers costs one timeout, not one per batch", ctx do
      listen(ctx, "/tap")
      # A second "geex": a socket that takes connections and never answers.
      {:ok, hung} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, backlog: 64])
      {:ok, port} = :inet.port(hung)
      disc = Path.join(ctx.dir, "disc")
      # A live pid of ours, so the payload counts it as running.
      pid = System.pid()

      File.write!(
        Path.join(disc, "hung.json"),
        ~s|{"v":1,"url":"http://127.0.0.1:#{port}/attest","token":"ab","pid":#{pid}}|
      )

      File.rename!(Path.join(disc, "hung.json"), Path.join(disc, "#{pid}.hung.json"))
      files = for i <- 1..32, do: {"f#{i}.txt", "#{i}\n"}
      repo = repo(ctx, "repo", files)
      assert %{status: 0} = run(ctx, bash(:pre, repo, "sed -i s/^/x/ f*.txt"))
      for {f, body} <- files, do: File.write!(Path.join(repo, f), "x" <> body)

      {micros, %{status: 0}} =
        :timer.tc(fn -> run(ctx, bash(:post, repo, "sed -i s/^/x/ f*.txt")) end)

      :gen_tcp.close(hung)
      # Four batches of eight: four seconds before; one timeout now.
      assert micros < 2_500_000, "#{div(micros, 1000)} ms"
      assert map_size(received(ctx.dir)) == 32
    end

    # The first live run read "while pwd" for `pwd; sed …` (the maintainer: skip parts that only read).
    test "the program skips parts that only read; a redirect into a file makes a writer", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])

      for {command, program} <- [
            {"pwd; sed -i s/0/1/ a.txt", "sed"},
            {"ls -la && cat a.txt | grep 0; python3 x.py", "python3"},
            {"echo start; echo hi > a.txt", "echo"},
            {"ls > /dev/null; perl -pi -e s/0/1/ a.txt", "perl"},
            {"sed -i s/0/1/ a.txt 2>&1; echo done", "sed"},
            {"cat a.txt", "cat"},
            # verifier's check of the label fix: redirections, an assignment-only part, lookups.
            {"cat a.txt 2>&1; sed -i s/0/1/ a.txt", "sed"},
            {"echo hi >&2; sed -i s/0/1/ a.txt", "sed"},
            {"grep -c x a.txt >/dev/null 2>&1 && sed -i s/0/1/ a.txt", "sed"},
            {"ls 2>&1 | head; python3 x.py", "python3"},
            {"echo x >| a.txt", "echo"},
            {"echo x &>a.txt", "echo"},
            {"echo x &>> a.txt", "echo"},
            {"FOO=1; sed -i s/0/1/ a.txt", "sed"},
            {~s|echo hi > "/dev/null"; perl -pi -e s/0/1/ a.txt|, "perl"},
            {"echo oops >/dev/stderr; sed -i s/0/1/ a.txt", "sed"},
            {"command -v sed && sed -i s/0/1/ a.txt", "sed"}
          ] do
        n = System.unique_integer([:positive])

        got =
          bracket(ctx, repo, command, fn -> File.write!(Path.join(repo, "a.txt"), "#{n}\n") end)

        assert %{"program" => ^program} = got["repo/a.txt"], command
      end
    end

    test "a cut-short PreToolUse's .tmp is swept too", ctx do
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])
      File.mkdir_p!(snaps(ctx))
      tmp = Path.join(snaps(ctx), "toolu_x.snap.tmp.123")
      File.write!(tmp, "half")
      File.touch!(tmp, System.os_time(:second) - 2 * 3600)
      assert %{status: 0} = run(ctx, bash(:pre, repo, "true"))
      refute File.exists?(tmp)
    end

    test "a file written back unchanged sends nothing", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "same\n"}])

      got =
        bracket(ctx, repo, "touch a.txt", fn ->
          File.write!(Path.join(repo, "a.txt"), "same\n")
        end)

      assert got == %{}
    end

    test "a CRLF file under core.autocrlf: before is the bytes a checkout writes", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"w.txt", "l1\r\nl2\r\n"}], [{"core.autocrlf", "true"}])
      # The index holds LF; the work tree CRLF.
      assert {"l1\nl2\n", 0} = System.cmd("git", ["show", ":w.txt"], cd: repo)

      got =
        bracket(ctx, repo, "perl -pi -e s/l2/L2/ w.txt", fn ->
          File.write!(Path.join(repo, "w.txt"), "l1\r\nL2\r\n")
        end)

      assert %{"before" => before, "program" => "perl"} = got["repo/w.txt"]
      assert before == hex("l1\r\nl2\r\n")
    end

    test "other work trees: a cd, a git -C and an absolute path, from a cwd outside git", ctx do
      listen(ctx, "/tap")
      one = repo(ctx, "one", [{"f.txt", "1\n"}])
      two = repo(ctx, "two", [{"f.txt", "2\n"}])
      three = repo(ctx, "three", [{"f.txt", "3\n"}])
      outside = Path.join(ctx.dir, "outside")
      File.mkdir_p!(outside)

      command =
        "cd #{one} && FOO=1 python3 - <<'EOF'\nopen('f.txt','w').write('1!')\nEOF\n" <>
          "git -C #{two} checkout -- f.txt; printf x > #{Path.join(three, "f.txt")}"

      got =
        bracket(ctx, outside, command, fn ->
          for {r, body} <- [{one, "1!"}, {two, "2!"}, {three, "x"}],
              do: File.write!(Path.join(r, "f.txt"), body)
        end)

      paths = got |> Map.values() |> Enum.map(& &1["path"]) |> Enum.sort()
      assert paths == Enum.sort(for r <- [one, two, three], do: Path.join(r, "f.txt"))
      assert Enum.all?(Map.values(got), &(&1["program"] == "python3"))
    end

    test "the program: past cd, assignments and wrappers, as a basename; never the command line",
         ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])

      for {command, program} <- [
            {"/usr/bin/sed -i s/0/1/ a.txt --token=SECRET", "sed"},
            {"cd . && env A=1 B=2 nohup prettier --write a.txt", "prettier"},
            {"export X=1; npx eslint --fix a.txt", "npx"},
            {"echo SECRET > a.txt", "echo"}
          ] do
        n = System.unique_integer([:positive])

        got =
          bracket(ctx, repo, command, fn -> File.write!(Path.join(repo, "a.txt"), "#{n}\n") end)

        assert %{"program" => ^program} = msg = got["repo/a.txt"]
        refute JSON.encode!(msg) =~ "SECRET"
      end
    end

    test "a background call: no snapshot, nothing sent", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])
      input = %{"run_in_background" => true}

      got =
        bracket(
          ctx,
          repo,
          "npm run dev",
          fn -> File.write!(Path.join(repo, "a.txt"), "1\n") end,
          input
        )

      assert got == %{}
      refute File.exists?(snaps(ctx)) and File.ls!(snaps(ctx)) != []
    end

    test "outside any git work tree: no snapshot, nothing sent", ctx do
      listen(ctx, "/tap")
      plain = Path.join(ctx.dir, "plain")
      File.mkdir_p!(plain)
      File.write!(Path.join(plain, "a.txt"), "0\n")

      got =
        bracket(ctx, plain, "sed -i s/0/1/ a.txt", fn ->
          File.write!(Path.join(plain, "a.txt"), "1\n")
        end)

      assert got == %{}
    end

    test "PreToolUse is silent and records only: no POST, empty stdout, a 0600 snapshot", ctx do
      listen(ctx, "/tap")
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])
      File.write!(Path.join(repo, "a.txt"), "dirty\n")

      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, bash(:pre, repo, "true"))
      refute_receive {:tapped, _, _, _}, 200
      assert [snap] = File.ls!(snaps(ctx))
      assert File.stat!(Path.join(snaps(ctx), snap)).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(snaps(ctx)).mode |> Bitwise.band(0o777) == 0o700
      # Never a *.json beside the discovery files.
      refute snap =~ ".json"
    end

    test "a PreToolUse for another tool leaves at once, writing nothing", ctx do
      listen(ctx, "/tap")
      line = envelope("edit.jsonl", :pre) |> retarget(target(ctx, "f", "x\n"))
      assert %{status: 0, stdout: "", stderr: ""} = run(ctx, line)
      refute File.exists?(snaps(ctx))
    end

    test "a denied call's snapshot (over an hour old) is swept by the next PreToolUse", ctx do
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])
      File.mkdir_p!(snaps(ctx))
      stale = Path.join(snaps(ctx), "toolu_stale.snap")
      File.write!(stale, "root\t/nowhere\n")
      File.touch!(stale, System.os_time(:second) - 2 * 3600)

      assert %{status: 0} = run(ctx, bash(:pre, repo, "true"))
      refute File.exists?(stale)
    end

    test "spooled with during, never with program", ctx do
      repo = repo(ctx, "repo", [{"a.txt", "0\n"}])
      path = Path.join(repo, "a.txt")
      with_ledger(ctx, path)
      env = state_env(ctx)

      assert %{status: 0} = run(ctx, bash(:pre, repo, "sed -i s/0/1/ a.txt"), env)
      File.write!(path, "1\n")
      assert %{status: 0} = run(ctx, bash(:post, repo, "sed -i s/0/1/ a.txt"), env)

      assert [entry] = spooled(ctx, path)
      assert %{"during" => "Bash", "before" => before, "sha256" => after_s} = entry
      assert {before, after_s} == {hex("0\n"), hex("1\n")}
      refute Map.has_key?(entry, "program")
    end
  end
end
