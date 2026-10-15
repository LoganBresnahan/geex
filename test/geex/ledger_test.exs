defmodule Geex.LedgerTest do
  # Each test has its own files and ledger directory, so they run concurrently.
  use ExUnit.Case, async: true
  # The damage tests log warnings on purpose.
  @moduletag :capture_log
  doctest Geex.Ledger.Spool

  alias Geex.{Buffer, Command, Ledger, Reconcile}
  alias Geex.Command.Meta
  alias Geex.Commands.{Delete, Edit, Insert, Replace}
  alias Geex.Ledger.{Codec, Restore, Spool}

  @agent {:agent, %{harness: "claude-code", session: "s1", turn: "t1", tool_use: "u1"}}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_ledger_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, ledger: Path.join(dir, "ledger"), doc: Path.join(dir, "doc.txt")}
  end

  defp hex(text), do: Restore.sha256(text)

  defp open(ctx, path \\ nil) do
    path = path || ctx.doc
    {:ok, buf} = Buffer.start_link(path: path, ledger_dir: ctx.ledger)
    Process.unlink(buf)
    buf
  end

  defp close(buf), do: GenServer.stop(buf, :shutdown)

  defp crash(buf) do
    ref = Process.monitor(buf)
    Process.exit(buf, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  defp type(buf, line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
  end

  defp agent_writes(buf, file, before, after_text) do
    File.write!(file, after_text)
    {:reconciled, _} = Reconcile.reconcile(buf, after_text)

    :attested =
      Buffer.attest(buf, %{
        before: hex(before),
        sha256: hex(after_text),
        harness: "claude-code",
        session: "s1",
        turn: "t1",
        tool_use: "u1"
      })
  end

  defp live(buf), do: :sys.get_state(buf).history
  defp actors(buf), do: Enum.map(Buffer.history(buf), & &1.meta.actor)

  defp ledger_lines(ctx, path \\ nil),
    do: Ledger.file(ctx.ledger, path || ctx.doc) |> File.read!() |> String.split("\n", trim: true)

  describe "the line format" do
    test "every entry round-trips, with every actor, a stamp, an origin and non-UTF-8 bytes" do
      at = ~U[2026-10-15 12:00:00.123456Z]
      raw = <<"caf", 0xE9, "\n">>
      {:ok, ins} = Insert.parse(%{line: 0, col: 0, text: raw})
      {:ok, del} = Delete.parse(%{line: 0, col: 0, count: 2})

      {:ok, rep} =
        Replace.parse(%{start_line: 0, start_col: 0, end_line: 0, end_col: 1, text: "x"})

      {:ok, edit} = Edit.parse(%{"edits" => [%{"search" => "a", "replace" => "b"}]})

      stamp = %{group: 3, before_sha256: hex("a"), before_sha256_lf: nil, sha256: hex("b")}

      commands = [
        Command.put_meta(ins, Meta.new(:human, at: at)),
        Command.put_meta(
          del,
          Meta.new({:llm, "m"}, at: at, prompt_hash: "p", origin: %{turn_id: "t", seq: 2})
        ),
        Command.put_meta(rep, Meta.new(@agent, at: at, reconcile: stamp)),
        Command.put_meta(edit, Meta.new(:external, at: at))
      ]

      entries = [
        {:open, %{path: "/f", base: raw, geex: "0.1.0"}},
        {:cmd, hd(commands)},
        {:group, commands, :none},
        {:gap, commands, :result},
        {:group, [], raw},
        :undo,
        :redo,
        {:attest, 3, @agent},
        {:sync, hex("x")},
        {:rename, "/g"},
        {:close, %{text_sha256: hex("x"), synced_sha256: hex("y")}},
        {:checkpoint,
         %{
           path: "/f",
           text: raw,
           blame: [nil, {@agent, 3}, {:human, nil}],
           synced: "disk",
           next_group: 4,
           geex: "0.1.0"
         }},
        {:checkpoint,
         %{path: "/f", text: "t", blame: [nil], synced: "t", next_group: 1, geex: "0.1.0"}}
      ]

      for entry <- entries do
        line = Codec.encode(entry, at)
        assert String.ends_with?(line, "\n")
        assert Codec.decode(String.trim_trailing(line, "\n")) == {:ok, entry}
      end
    end

    test "rejects other versions, unknown types and garbage" do
      assert {:error, _} = Codec.decode(~s|{"v":2,"t":"undo"}|)
      assert {:error, _} = Codec.decode(~s|{"v":1,"t":"checkpoint"}|)
      assert {:error, _} = Codec.decode("{nope")
    end
  end

  describe "reopening" do
    test "a clean close restores history, blame and undo across sessions", ctx do
      File.write!(ctx.doc, "a\nb\n")
      buf = open(ctx)
      type(buf, 0, 0, "x")
      {:ok, _} = Buffer.save(buf)
      agent_writes(buf, ctx.doc, "xa\nb\n", "xa\nB\n")
      before = live(buf)
      close(buf)

      buf = open(ctx)
      assert live(buf) == before
      assert actors(buf) == [:human, @agent]
      assert [{:human, nil}, {@agent, 1}, nil] = Buffer.snapshot(buf).blame

      {:ok, _, _} = Buffer.undo(buf)
      {:ok, snap, _} = Buffer.undo(buf)
      assert snap.text == "a\nb\n"
      close(buf)
    end

    test "unsaved edits survive a crash and come back dirty, with a notice", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      type(buf, 0, 1, "bc")
      crash(buf)

      buf = open(ctx)
      {:ok, _} = Buffer.subscribe(buf, self())
      assert_receive {:geex_buffer_notice, ^buf, "restored unsaved changes" <> _}
      snap = Buffer.snapshot(buf)
      assert {snap.text, snap.dirty} == {"abc\n", true}
      close(buf)
    end

    test "a crash right after an agent edit reconciled into a clean buffer finds no gap", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      agent_writes(buf, ctx.doc, "a\n", "A\n")
      before = live(buf)
      crash(buf)

      buf = open(ctx)
      {:ok, _} = Buffer.subscribe(buf, self())
      refute_receive {:geex_buffer_notice, _, _}, 50
      assert live(buf) == before
      refute Buffer.snapshot(buf).dirty
      close(buf)
    end

    test "a change made while geex was closed is recorded as an :external gap", ctx do
      File.write!(ctx.doc, "a\nb\n")
      buf = open(ctx)
      type(buf, 0, 0, "x")
      {:ok, _} = Buffer.save(buf)
      close(buf)
      File.write!(ctx.doc, "xa\nB\n")

      buf = open(ctx)
      {:ok, _} = Buffer.subscribe(buf, self())
      assert_receive {:geex_buffer_notice, ^buf, "the file changed while geex was closed" <> _}
      snap = Buffer.snapshot(buf)
      assert {snap.text, snap.dirty} == {"xa\nB\n", false}
      assert actors(buf) == [:human, :external]
      assert Enum.any?(ledger_lines(ctx), &(&1 =~ ~s|"t":"gap"|))

      # and it is part of the history now: a reopen finds nothing new
      close(buf)
      buf = open(ctx)
      assert actors(buf) == [:human, :external]
      close(buf)
    end

    test "a closed-file change merges with unsaved edits: yours are kept, still dirty", ctx do
      File.write!(ctx.doc, "a\nb\nc\n")
      buf = open(ctx)
      type(buf, 0, 0, "MY-")
      close(buf)
      File.write!(ctx.doc, "a\nb\nDISK\n")

      buf = open(ctx)
      snap = Buffer.snapshot(buf)
      assert {snap.text, snap.dirty} == {"MY-a\nb\nDISK\n", true}
      close(buf)
    end

    test "CRLF, a BOM and no final newline: the saved bytes rejoin with no gap", ctx do
      File.write!(ctx.doc, "﻿one\r\ntwo")
      buf = open(ctx)
      type(buf, 1, 0, "x")
      {:ok, _} = Buffer.save(buf)
      close(buf)

      buf = open(ctx)
      {:ok, _} = Buffer.subscribe(buf, self())
      refute_receive {:geex_buffer_notice, _, _}, 50
      assert actors(buf) == [:human]
      assert Buffer.snapshot(buf).text == "﻿one\r\nxtwo"
      close(buf)
    end

    test "group ids are durable: a new group after a reopen continues the count", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      agent_writes(buf, ctx.doc, "a\n", "b\n")
      close(buf)

      buf = open(ctx)
      File.write!(ctx.doc, "c\n")
      {:reconciled, snap} = Reconcile.reconcile(buf, "c\n")
      assert Enum.map(snap.history, & &1.meta.reconcile.group) == [1, 2]
      close(buf)
    end
  end

  describe "damage" do
    test "a torn last line is dropped and cut off the file", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      type(buf, 0, 0, "x")
      close(buf)
      file = Ledger.file(ctx.ledger, ctx.doc)
      good = File.read!(file)
      File.write!(file, ~s|{"v":1,"t":"cmd","cm|, [:append])

      buf = open(ctx)
      assert Buffer.snapshot(buf).text == "xa\n"
      assert File.read!(file) == good
      close(buf)
    end

    test "a corrupt middle line stops replay there; the original is kept aside", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      type(buf, 0, 0, "1")
      type(buf, 0, 0, "2")
      type(buf, 0, 0, "3")
      close(buf)
      file = Ledger.file(ctx.ledger, ctx.doc)
      [open_line, one, _two, three | rest] = File.read!(file) |> String.split("\n")
      File.write!(file, Enum.join([open_line, one, "garbage", three | rest], "\n"))

      buf = open(ctx)
      assert Buffer.snapshot(buf).text == "1a\n"
      assert [_aside] = Path.wildcard(file <> ".corrupt-*")
      # the usable prefix, then the reopen's verification of it
      assert Enum.map(ledger_lines(ctx), &JSON.decode!(&1)["t"]) == ["open", "cmd", "close"]
      close(buf)
    end

    test "a sync whose hash doesn't match stops at the last verified point", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      type(buf, 0, 0, "1")
      {:ok, _} = Buffer.save(buf)
      type(buf, 0, 0, "2")
      {:ok, _} = Buffer.save(buf)
      close(buf)
      file = Ledger.file(ctx.ledger, ctx.doc)
      bytes = File.read!(file)
      # tamper with the second save's hash
      second = hex("21a\n")
      File.write!(file, String.replace(bytes, second, String.duplicate("0", 64)))

      buf = open(ctx)
      # back to the first verified save; the disk ("21a") then reads as a later change
      assert actors(buf) == [:human, :external]
      assert Buffer.snapshot(buf).text == "21a\n"
      close(buf)
    end
  end

  describe "the file and its lock" do
    test "nothing is written for a buffer that never changes", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      close(buf)
      assert File.ls!(ctx.ledger) == []
    end

    test "0600 files in a 0700 directory", ctx do
      buf = open(ctx)
      type(buf, 0, 0, "x")
      close(buf)
      assert File.stat!(ctx.ledger).mode |> Bitwise.band(0o777) == 0o700
      assert File.stat!(Ledger.file(ctx.ledger, ctx.doc)).mode |> Bitwise.band(0o777) == 0o600
    end

    test "a second buffer on the same file doesn't record, and says so", ctx do
      first = open(ctx)
      second = open(ctx)
      {:ok, _} = Buffer.subscribe(second, self())
      assert_receive {:geex_buffer_notice, ^second, "another geex is recording" <> _}

      type(second, 0, 0, "ignored")
      type(first, 0, 0, "kept")
      close(second)
      close(first)

      buf = open(ctx)
      assert Buffer.snapshot(buf).text == "kept"
      close(buf)
    end

    test "a stale lock (its owner is gone) is taken over", ctx do
      File.mkdir_p!(ctx.ledger)
      {dead, 0} = System.cmd("sh", ["-c", "echo $$"])
      lock = String.replace_suffix(Ledger.file(ctx.ledger, ctx.doc), ".jsonl", ".lock")
      File.write!(lock, String.trim(dead) <> " <0.1.0>")

      buf = open(ctx)
      type(buf, 0, 0, "x")
      close(buf)
      assert File.exists?(Ledger.file(ctx.ledger, ctx.doc))
      refute File.exists?(lock)
    end

    test "a rename moves the ledger to the new path", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      type(buf, 0, 0, "x")
      moved = Path.join(ctx.dir, "moved.txt")
      :ok = Buffer.rename(buf, moved)
      type(buf, 0, 0, "y")
      {:ok, _} = Buffer.save(buf)
      close(buf)

      refute File.exists?(Ledger.file(ctx.ledger, ctx.doc))
      buf = open(ctx, moved)
      assert actors(buf) == [:human, :human]
      assert Buffer.snapshot(buf).text == "yxa\n"
      close(buf)
    end
  end

  describe "reopening after a crash" do
    test "the restored state is verified at once with a close entry", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      type(buf, 0, 0, "x")
      crash(buf)
      refute List.last(ledger_lines(ctx)) =~ ~s|"t":"close"|

      buf = open(ctx)
      assert List.last(ledger_lines(ctx)) =~ ~s|"t":"close"|
      close(buf)
    end
  end

  describe "the spool: credit for edits made while the file wasn't open (ADR-0033 F)" do
    defp spool(ctx, entries) do
      lines =
        Enum.map(entries, fn {before, after_text, session, tool_use} ->
          JSON.encode!(%{
            "v" => 1,
            "path" => ctx.doc,
            "before" => hex(before),
            "sha256" => hex(after_text),
            "harness" => "claude-code",
            "session" => session,
            "turn" => "t-" <> tool_use,
            "tool_use" => tool_use,
            "at" => "2026-10-15T12:00:00Z"
          }) <> "\n"
        end)

      File.write!(Spool.file(Ledger.file(ctx.ledger, ctx.doc)), lines)
    end

    defp saved_and_closed(ctx, text) do
      File.write!(ctx.doc, text)
      buf = open(ctx)
      type(buf, 0, 0, "0")
      {:ok, _} = Buffer.save(buf)
      close(buf)
      "0" <> text
    end

    test "one spooled write that explains the change is credited", ctx do
      base = saved_and_closed(ctx, "a\nb\n")
      File.write!(ctx.doc, "0a\nB\n")
      spool(ctx, [{base, "0a\nB\n", "s1", "u1"}])

      buf = open(ctx)
      {:ok, _} = Buffer.subscribe(buf, self())
      assert_receive {:geex_buffer_notice, ^buf, notice}
      assert notice =~ "credited to claude-code/s1 (1 edit)"

      [_typed, gap] = Buffer.history(buf)

      assert gap.meta.actor ==
               {:agent, %{harness: "claude-code", session: "s1", turn: "t-u1", tool_use: "u1"}}

      assert gap.meta.reconcile.chain == ["u1"]
      refute File.exists?(Spool.file(Ledger.file(ctx.ledger, ctx.doc)))
      close(buf)

      # the credit is in the ledger: a reopen keeps it
      buf = open(ctx)
      assert {:agent, %{session: "s1"}} = List.last(Buffer.history(buf)).meta.actor
      close(buf)
    end

    test "a same-session chain is credited to that session, last write's ids", ctx do
      base = saved_and_closed(ctx, "a\n")
      File.write!(ctx.doc, "0a\nb\nc\n")

      spool(ctx, [
        {base, "0a\nb\n", "s1", "u1"},
        {"unrelated", "noise", "s1", "u9"},
        {"0a\nb\n", "0a\nb\nc\n", "s1", "u2"}
      ])

      buf = open(ctx)
      gap = List.last(Buffer.history(buf))
      assert {:agent, %{session: "s1", tool_use: "u2", turn: "t-u2"}} = gap.meta.actor
      assert gap.meta.reconcile.chain == ["u1", "u2"]
      close(buf)
    end

    test "a chain across two sessions, or with a missing link, stays :external", ctx do
      base = saved_and_closed(ctx, "a\n")
      File.write!(ctx.doc, "0a\nb\nc\n")
      spool(ctx, [{base, "0a\nb\n", "s1", "u1"}, {"0a\nb\n", "0a\nb\nc\n", "s2", "u2"}])

      buf = open(ctx)
      assert List.last(Buffer.history(buf)).meta.actor == :external
      refute File.exists?(Spool.file(Ledger.file(ctx.ledger, ctx.doc)))
      close(buf)

      File.write!(ctx.doc, "0a\nb\nc\nd\n")
      spool(ctx, [{"0a\nb\nc\nZZZ\n", "0a\nb\nc\nd\n", "s1", "u3"}])
      buf = open(ctx)
      assert List.last(Buffer.history(buf)).meta.actor == :external
      close(buf)
    end

    test "a CRLF file's single write matches through the \\r\\n-as-\\n before", ctx do
      base = saved_and_closed(ctx, "a\r\nb\r\n")
      File.write!(ctx.doc, "0a\r\nB\r\n")
      spool(ctx, [{String.replace(base, "\r\n", "\n"), "0a\r\nB\r\n", "s1", "u1"}])

      buf = open(ctx)
      assert {:agent, %{session: "s1"}} = List.last(Buffer.history(buf)).meta.actor
      close(buf)
    end
  end

  # ADR-0033 §3: restoring the ledger yields the history value the live buffer had.
  test "after random edits, undos, redos, outside writes, credits and saves, restore == live",
       ctx do
    :rand.seed(:exsss, {7, 8, 9})
    File.write!(ctx.doc, "one\ntwo\nthree\n")
    buf = open(ctx)

    for _ <- 1..150 do
      text = Buffer.get_text(buf)
      lines = String.split(text, "\n")

      case :rand.uniform(7) do
        1 ->
          Buffer.undo(buf)

        2 ->
          Buffer.redo(buf)

        3 ->
          {:ok, _} = Buffer.save(buf)

        4 ->
          line = :rand.uniform(length(lines)) - 1
          disk = lines |> List.replace_at(line, "disk#{:rand.uniform(99)}") |> Enum.join("\n")
          File.write!(ctx.doc, disk)
          Reconcile.reconcile(buf, disk)
          synced = Buffer.snapshot(buf).synced

          Buffer.attest(buf, %{
            before: hex(text),
            sha256: hex(synced),
            harness: "claude-code",
            session: "s#{:rand.uniform(3)}",
            turn: nil,
            tool_use: nil
          })

        _ ->
          line = :rand.uniform(length(lines)) - 1
          type(buf, line, 0, Enum.random(["x", "\n", "y\nz"]))
      end
    end

    before = live(buf)
    close(buf)
    {:ok, restored} = Ledger.load(%{Ledger.new(ctx.ledger, ctx.doc) | locked: true})
    assert restored.stopped == nil
    assert restored.history == before
  end
end
