defmodule Geex.AttestTest do
  # Discovery is a named singleton with a global token; buffers register in Geex.Registry.
  use ExUnit.Case, async: false
  doctest Geex.Attest

  import Plug.Test
  import Plug.Conn

  alias Geex.{Attest, Buffer, Command, Reconcile}
  alias Geex.Attest.Discovery
  alias Geex.Command.Meta
  alias Geex.Commands.Insert

  defp hex(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp attestation(before_text, after_text, extra \\ %{}) do
    Map.merge(
      %{
        path: "/unused",
        before: before_text && hex(before_text),
        sha256: hex(after_text),
        harness: "claude-code",
        session: "s1",
        turn: "p1",
        tool_use: "toolu_1"
      },
      extra
    )
  end

  defp actors(buf), do: buf |> Buffer.history() |> Enum.map(& &1.meta.actor)

  describe "parse/1" do
    @ok %{
      "v" => 1,
      "path" => "/abs/f.txt",
      "before" => String.duplicate("0", 64),
      "sha256" => String.duplicate("f", 64),
      "harness" => "claude-code",
      "session" => "s1"
    }

    test "accepts the minimal message; turn/tool_use optional; unknown fields ignored" do
      assert {:ok, a} = Attest.parse(Map.put(@ok, "extra", "x"))
      assert %{path: "/abs/f.txt", turn: nil, tool_use: nil, harness: "claude-code"} = a
    end

    test "before may be absent (a created file)" do
      assert {:ok, %{before: nil}} = Attest.parse(Map.delete(@ok, "before"))
    end

    test "hashes must be exactly 64 lowercase hex" do
      for bad <- [String.duplicate("F", 64), String.duplicate("a", 63), "not hex", 123] do
        assert {:error, msg} = Attest.parse(Map.put(@ok, "sha256", bad))
        assert msg =~ "64 lowercase hex"
        assert {:error, _} = Attest.parse(Map.put(@ok, "before", bad))
      end
    end

    test "rejects other versions, relative paths, and missing identity" do
      assert {:error, "unsupported version 2"} = Attest.parse(Map.put(@ok, "v", 2))
      assert {:error, "path must be absolute"} = Attest.parse(Map.put(@ok, "path", "rel.txt"))
      assert {:error, _} = Attest.parse(Map.delete(@ok, "session"))
      assert {:error, _} = Attest.parse(Map.put(@ok, "harness", ""))
      assert {:error, _} = Attest.parse([])
    end
  end

  describe "Buffer.attest/2 — the both-hashes rule" do
    test "late: an attestation after the reconcile upgrades the whole group, once" do
      buf = start_supervised!({Buffer, text: "1\n2\n3\n"})
      {:ok, _v} = Buffer.subscribe(buf, self())
      {:reconciled, _} = Reconcile.reconcile(buf, "ONE\n2\nTHREE\n")
      assert actors(buf) == [:external, :external]

      assert Buffer.attest(buf, attestation("1\n2\n3\n", "ONE\n2\nTHREE\n")) == :attested

      expected =
        {:agent, %{harness: "claude-code", session: "s1", turn: "p1", tool_use: "toolu_1"}}

      assert actors(buf) == [expected, expected]
      assert_receive {:geex_buffer_attested, ^buf, _group, ^expected}, 500

      # once: a repeat is ignored, not re-attested and not parked
      assert Buffer.attest(buf, attestation("1\n2\n3\n", "ONE\n2\nTHREE\n")) == :ignored
    end

    test "early (the primary path): the attestation is held, and the group lands attested" do
      buf = start_supervised!({Buffer, text: "a\n"})
      assert Buffer.attest(buf, attestation("a\n", "b\n")) == :held

      {:reconciled, snap} = Reconcile.reconcile(buf, "b\n")
      assert [%{meta: %{actor: {:agent, %{session: "s1"}}}}] = snap.history
    end

    test "coalesced writes (sed H0->H1, agent H1->H2, one group H0->H2) stay :external" do
      buf = start_supervised!({Buffer, text: "h0\n"})
      # the agent's attestation describes only its own step
      assert Buffer.attest(buf, attestation("h1\n", "h2\n")) == :held
      {:reconciled, _} = Reconcile.reconcile(buf, "h2\n")
      assert actors(buf) == [:external]
      # and a late attempt doesn't match either
      assert Buffer.attest(buf, attestation("h1\n", "h2\n")) == :held
      assert actors(buf) == [:external]
    end

    test "an identical-bytes write (before == after) never matches" do
      buf = start_supervised!({Buffer, text: "x\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "y\n")
      assert Buffer.attest(buf, attestation("y\n", "y\n")) == :held
      assert actors(buf) == [:external]
    end

    test "only the newest group: an attestation for an older write doesn't match" do
      buf = start_supervised!({Buffer, text: "a\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
      {:reconciled, _} = Reconcile.reconcile(buf, "c\n")
      assert Buffer.attest(buf, attestation("a\n", "b\n")) == :held
      assert actors(buf) == [:external, :external]
    end

    test "human edits after the group don't block it" do
      buf = start_supervised!({Buffer, text: "a\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
      {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "x"})
      {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))

      assert Buffer.attest(buf, attestation("a\n", "b\n")) == :attested
      assert [{:agent, _}, :human] = actors(buf)
    end

    test "no `before` (a created file) is ignored, never parked" do
      buf = start_supervised!({Buffer, text: "a\n"})
      assert Buffer.attest(buf, attestation(nil, "b\n")) == :ignored
      {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
      assert actors(buf) == [:external]
    end

    test "held attestations are bounded: the oldest beyond 256 is dropped" do
      buf = start_supervised!({Buffer, text: "a\n"})
      assert Buffer.attest(buf, attestation("a\n", "b\n")) == :held

      for i <- 1..256,
          do: :held = Buffer.attest(buf, attestation("x#{i}\n", "y#{i}\n"))

      {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
      assert actors(buf) == [:external]
    end

    test "a fast-forward that used the held attestations clears them" do
      buf = start_supervised!({Buffer, text: "a\n"})
      :held = Buffer.attest(buf, attestation("a\n", "b\n"))
      {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
      assert :sys.get_state(buf).held == []
      # a repeat now finds its group already attested
      assert Buffer.attest(buf, attestation("a\n", "b\n")) == :ignored
    end

    test "replay is unaffected by an upgrade (meta never feeds run/2)" do
      buf = start_supervised!({Buffer, text: "1\n2\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "1\nTWO\n")
      :attested = Buffer.attest(buf, attestation("1\n2\n", "1\nTWO\n"))

      {:ok, replayed} =
        Geex.Dispatch.replay(Geex.EditorState.new("1\n2\n"), Buffer.history(buf))

      assert Geex.EditorState.text(replayed) == "1\nTWO\n"
    end
  end

  # Claude Code hands the hook a file's prior text with each "\r\n" turned into "\n" (one
  # left-to-right pass; a lone "\r" stays), so the payload's `before` is that text's hash.
  # `sha256` is the payload's hash of the disk. The rows come from the coordinator's live check
  # on Claude Code 2.1.299: the pre-write bytes and `originalFile` as it reported them (written
  # out, not computed); the after bytes follow the line endings it saw each tool leave.
  @crlf_cases [
    {"stray: CRLF with a lone \\r (Edit keeps CRLF)", "alpha\r\nmid\rline\r\ngamma\r\n",
     "alpha\nmid\rline\ngamma\n", "alpha\r\nmid\rline\r\nGAMMA\r\n"},
    {"mixed (Edit rewrites all-LF)", "alpha\nbeta\r\ngamma\nend\r\n", "alpha\nbeta\ngamma\nend\n",
     "alpha\nbeta\ngamma\nEND\n"},
    {"lfstray: LF with a lone \\r (exact match)", "alpha\nmid\rline\ngamma\n",
     "alpha\nmid\rline\ngamma\n", "alpha\nmid\rline\nGAMMA\n"},
    {"crlfw: Write rewrites a CRLF file as LF", "alpha\r\nbeta\r\ngamma\r\n",
     "alpha\nbeta\ngamma\n", "alpha\nbeta\nGAMMA\n"},
    {"doublecr: \\r\\r\\n reports as \\r\\n", "alpha\r\r\nbeta\n", "alpha\r\nbeta\n",
     "alpha\r\nBETA\n"}
  ]

  describe "Buffer.attest/2 — line endings as Claude Code reports them" do
    for {name, baseline, reported, disk} <- @crlf_cases do
      test name do
        buf = start_supervised!({Buffer, text: unquote(baseline)})
        {:reconciled, _} = Reconcile.reconcile(buf, unquote(disk))
        assert Buffer.attest(buf, attestation(unquote(reported), unquote(disk))) == :attested
        assert Enum.all?(actors(buf), &match?({:agent, _}, &1))
      end
    end

    test "the early (held) path matches the same way" do
      buf = start_supervised!({Buffer, text: "a\r\nb\r\n"})
      assert Buffer.attest(buf, attestation("a\nb\n", "a\r\nB\r\n")) == :held
      {:reconciled, snap} = Reconcile.reconcile(buf, "a\r\nB\r\n")
      assert [%{meta: %{actor: {:agent, _}}}] = snap.history
    end

    test "the exact before still matches; the after hash is never loosened" do
      buf = start_supervised!({Buffer, text: "a\r\nb\r\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "a\r\nB\r\n")
      # the after given without its \r: no match
      assert Buffer.attest(buf, attestation("a\nb\n", "a\nB\n")) == :held
      assert actors(buf) == [:external]
      assert Buffer.attest(buf, attestation("a\r\nb\r\n", "a\r\nB\r\n")) == :attested
    end

    test "a baseline with no \\r\\n gets no second hash" do
      buf = start_supervised!({Buffer, text: "a\rb\n"})
      {:reconciled, snap} = Reconcile.reconcile(buf, "c\n")
      assert [%{meta: %{reconcile: %{before_sha256_lf: nil}}}] = snap.history
    end

    # The stated residual (ADR-0032 CRLF amendment): another writer ONLY converts CRLF to LF,
    # then the agent edits, inside one quiet period. One group H0 -> H2; the agent's before
    # (H1 = H0 converted) matches the second hash, so the agent is credited with the
    # line-ending change too. A change to any other byte keeps the group :external.
    test "residual: a CRLF->LF conversion coalesced with an agent edit is credited to it" do
      buf = start_supervised!({Buffer, text: "a\r\nb\r\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "a\nB\n")
      assert Buffer.attest(buf, attestation("a\nb\n", "a\nB\n")) == :attested

      other = start_supervised!({Buffer, text: "a\r\nb\r\n"}, id: :other)
      {:reconciled, _} = Reconcile.reconcile(other, "x\nB\n")
      assert Buffer.attest(other, attestation("x\nb\n", "x\nB\n")) == :held
      assert actors(other) == [:external]
    end
  end

  describe "submit/1" do
    test "a path with no open buffer is :not_open" do
      assert Attest.submit(attestation("a", "b", %{path: "/nope/#{System.unique_integer()}"})) ==
               :not_open
    end
  end

  describe "POST /attest + discovery" do
    setup do
      dir = Path.join(System.tmp_dir!(), "geex_disc_#{Geex.Fixtures.uniq()}")
      on_exit(fn -> File.rm_rf(dir) end)
      start_supervised!({Discovery, url: "http://127.0.0.1:1/attest", dir: dir})
      %{dir: dir, token: Discovery.token()}
    end

    defp post_attest(body, headers) do
      conn = conn(:post, "/attest", body)
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      Geex.Attest.HTTP.call(conn, Geex.Attest.HTTP.init([]))
    end

    defp message(path, before_text, after_text) do
      JSON.encode!(%{
        "v" => 1,
        "path" => path,
        "before" => hex(before_text),
        "sha256" => hex(after_text),
        "harness" => "claude-code",
        "session" => "s1"
      })
    end

    test "the discovery file: 0600 in a 0700 dir, with url, token and pid", %{dir: dir} = ctx do
      [file] = Path.wildcard(Path.join(dir, "*.json"))
      assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
      assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600

      assert %{"v" => 1, "url" => "http://127.0.0.1:1/attest", "token" => token, "pid" => pid} =
               file |> File.read!() |> JSON.decode!()

      assert token == ctx.token
      assert Integer.to_string(pid) == System.pid()
    end

    test "on start, a file left by a geex that is gone is swept, and nothing else", %{dir: dir} do
      stop_supervised!(Discovery)
      dead = fn -> System.cmd("sh", ["-c", "echo $$"]) |> elem(0) |> String.trim() end
      port = Port.open({:spawn, "sleep 30"}, [])
      {:os_pid, live} = Port.info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", [Integer.to_string(live)]) end)
      [gone, linked, odd] = [dead.(), dead.(), dead.()]
      write = fn name, pid -> File.write!(Path.join(dir, name), JSON.encode!(%{"pid" => pid})) end

      write.("#{gone}.json", gone)
      write.("#{live}.json", live)
      # Not `<digits>.json`, though the pid inside is gone.
      write.("#{odd}x.json", odd)
      write.("notes.json", odd)
      # A link named like a stale file: neither it nor what it points at is touched.
      target = Path.join(dir, "target")
      File.write!(target, "keep")
      File.ln_s!(target, Path.join(dir, "#{linked}.json"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!({Discovery, url: "http://127.0.0.1:1/attest", dir: dir})
          # the sweep's `kill -0` ports have closed; their exits are handled, not logged
          :sys.get_state(Discovery)
        end)

      refute File.exists?(Path.join(dir, "#{gone}.json"))
      assert File.exists?(Path.join(dir, "#{live}.json"))
      assert File.exists?(Path.join(dir, "#{odd}x.json"))
      assert File.exists?(Path.join(dir, "notes.json"))
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(dir, "#{linked}.json"))
      assert File.read!(target) == "keep"
      assert File.exists?(Path.join(dir, "#{System.pid()}.json"))
      assert log =~ "geex attest: removed 1 stale discovery file(s)"
      refute log =~ "unexpected message"
    end

    test "a sweep that removes nothing says nothing", %{dir: dir} do
      stop_supervised!(Discovery)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!({Discovery, url: "http://127.0.0.1:1/attest", dir: dir})
          :sys.get_state(Discovery)
        end)

      refute log =~ "stale discovery"
    end

    test "the discovery file is removed on a clean stop", %{dir: dir} do
      stop_supervised!(Discovery)
      assert Path.wildcard(Path.join(dir, "*.json")) == []
      assert Discovery.token() == nil
    end

    test "401 without the token or with a wrong one", %{token: token} do
      body = message("/x", "a", "b")
      assert post_attest(body, []).status == 401
      assert post_attest(body, [{"authorization", "Bearer nope"}]).status == 401
      assert post_attest(body, [{"authorization", token}]).status == 401
    end

    test "403 with an Origin header, even with the token", %{token: token} do
      conn =
        post_attest(message("/x", "a", "b"), [
          {"authorization", "Bearer " <> token},
          {"origin", "http://127.0.0.1"}
        ])

      assert conn.status == 403
    end

    test "400 for malformed JSON and for an invalid hash, with the reason", %{token: token} do
      auth = [{"authorization", "Bearer " <> token}]
      assert post_attest("{nope", auth).status == 400

      bad = JSON.encode!(%{"v" => 1, "path" => "/x", "sha256" => "ABC"})
      conn = post_attest(bad, auth)
      assert conn.status == 400
      assert conn.resp_body =~ "64 lowercase hex"
    end

    test "200 not_open, and 200 attested end to end on an open buffer", %{token: token} do
      auth = [{"authorization", "Bearer " <> token}]
      conn = post_attest(message("/nope/#{System.unique_integer()}", "a", "b"), auth)
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"status" => "not_open"}

      path = Path.join(System.tmp_dir!(), "geex_att_#{Geex.Fixtures.uniq()}.txt")
      File.write!(path, "v1\n")
      on_exit(fn -> File.rm(path) end)
      {:ok, buf} = Geex.BufferSupervisor.start_buffer(Path.expand(path))

      on_exit(fn ->
        if Process.alive?(buf), do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, buf)
      end)

      {:reconciled, _} = Reconcile.reconcile(buf, "v2\n")
      conn = post_attest(message(path, "v1\n", "v2\n"), auth)
      assert JSON.decode!(conn.resp_body) == %{"status" => "attested"}
      assert [{:agent, %{harness: "claude-code"}}] = actors(buf)
    end

    test "the serve-mode MCP router hands /attest on", %{token: token} do
      conn =
        conn(:post, "/attest", message("/nope/#{System.unique_integer()}", "a", "b"))
        |> put_req_header("authorization", "Bearer " <> token)
        |> Geex.MCP.HTTP.call(Geex.MCP.HTTP.init([]))

      assert conn.status == 200
    end
  end
end
