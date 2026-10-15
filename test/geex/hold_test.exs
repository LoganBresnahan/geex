defmodule Geex.HoldTest do
  # Open buffers hold (ADR-0034): a disk change marks the buffer behind, a fast-forward takes it
  # in (crediting the agent writes it held), and a save merges before it writes. Real files and
  # real `git merge-file`; each test has its own directory.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Geex.{Buffer, Command, Ledger, Reconcile}
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Ledger.{Restore, Spool}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_hold_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, ledger: Path.join(dir, "ledger"), doc: Path.join(dir, "doc.txt")}
  end

  defp open(ctx, opts \\ []) do
    {:ok, buf} = Buffer.start_link([path: ctx.doc] ++ opts)
    Process.unlink(buf)
    on_exit(fn -> if Process.alive?(buf), do: GenServer.stop(buf, :shutdown) end)
    buf
  end

  defp hex(text), do: Restore.sha256(text)

  defp type(buf, line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
  end

  # What the watcher does on a settled event: read the file, tell the buffer.
  defp agent_edits(ctx, buf, text) do
    File.write!(ctx.doc, text)
    Buffer.disk_changed(buf, text)
  end

  defp attestation(before, after_text, session \\ "s1", tool_use \\ "u1") do
    %{
      path: "/unused",
      before: hex(before),
      sha256: hex(after_text),
      harness: "claude-code",
      session: session,
      turn: "t-" <> tool_use,
      tool_use: tool_use
    }
  end

  defp actors(buf), do: Enum.map(Buffer.history(buf), & &1.meta.actor)

  describe "holding (ADR-0034 §1)" do
    test "a disk change marks the buffer behind without changing it; matching again clears it",
         ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      {:ok, _} = Buffer.subscribe(buf, self())

      assert agent_edits(ctx, buf, "b\n") == :behind
      assert Buffer.get_text(buf) == "a\n"
      assert Buffer.history(buf) == []
      assert %{sha256: sha, at: %DateTime{}} = Buffer.snapshot(buf).behind
      assert sha == hex("b\n")
      assert_receive {:geex_buffer_behind, ^buf, %{sha256: ^sha}}

      # the same disk again: no second notification
      assert Buffer.disk_changed(buf, "b\n") == :behind
      refute_receive {:geex_buffer_behind, ^buf, _}, 50

      assert agent_edits(ctx, buf, "a\n") == :in_sync
      assert Buffer.snapshot(buf).behind == nil
      assert_receive {:geex_buffer_behind, ^buf, nil}
    end

    test "a fast-forward takes a clean buffer to the disk as one undoable group", ctx do
      File.write!(ctx.doc, "1\n2\n3\n")
      buf = open(ctx)
      agent_edits(ctx, buf, "ONE\n2\nTHREE\n")

      assert {:fast_forwarded, snap, 0} = Reconcile.fast_forward(buf)
      assert snap.text == "ONE\n2\nTHREE\n"
      refute snap.dirty
      assert snap.behind == nil
      assert actors(buf) == [:external, :external]

      {:ok, _, _} = Buffer.undo(buf)
      {:ok, snap, _} = Buffer.undo(buf)
      assert snap.text == "1\n2\n3\n"
    end

    test "nothing to take in: up to date, and a stale mark is cleared", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      assert Reconcile.fast_forward(buf) == :up_to_date

      # marked behind, then the disk went back before the watcher said so
      Buffer.disk_changed(buf, "b\n")
      assert Reconcile.fast_forward(buf) == :up_to_date
      assert Buffer.snapshot(buf).behind == nil
    end

    test "a dirty buffer: a clean merge keeps your unsaved edit", ctx do
      File.write!(ctx.doc, "1\n2\n3\n4\n5\n")
      buf = open(ctx)
      type(buf, 0, 0, "MY-")
      agent_edits(ctx, buf, "1\n2\n3\n4\nFIVE\n")

      assert {:fast_forwarded, snap, 0} = Reconcile.fast_forward(buf)
      assert snap.text == "MY-1\n2\n3\n4\nFIVE\n"
      assert snap.synced == "1\n2\n3\n4\nFIVE\n"
      assert snap.dirty
    end

    test "a dirty buffer: an overlap leaves git's conflict block and a notice", ctx do
      File.write!(ctx.doc, "keep\nedit me\n")
      buf = open(ctx)
      type(buf, 1, 0, "MINE ")
      {:ok, _} = Buffer.subscribe(buf, self())
      agent_edits(ctx, buf, "keep\nDISK\n")

      assert {:fast_forwarded, snap, 1} = Reconcile.fast_forward(buf)
      assert snap.text == "keep\n<<<<<<< buffer\nMINE edit me\n=======\nDISK\n>>>>>>> disk\n"
      assert_receive {:geex_buffer_notice, ^buf, "1 conflict with the disk" <> _}
    end
  end

  describe "credit for the writes a buffer held" do
    test "a held write is credited at the fast-forward", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      agent_edits(ctx, buf, "b\n")
      assert Buffer.attest(buf, attestation("a\n", "b\n")) == :held

      {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)

      assert [%{meta: %{actor: {:agent, %{session: "s1", tool_use: "u1"}}} = meta}] =
               Buffer.history(buf)

      assert meta.reconcile.chain == ["u1"]
    end

    test "a same-session chain is credited to that session; mixed sessions stay :external", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      :held = Buffer.attest(buf, attestation("a\n", "b\n", "s1", "u1"))
      agent_edits(ctx, buf, "b\n")
      :held = Buffer.attest(buf, attestation("b\n", "c\n", "s1", "u2"))
      agent_edits(ctx, buf, "c\n")

      {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)
      assert [%{meta: %{actor: {:agent, who}} = meta}] = Buffer.history(buf)
      assert {who.session, who.tool_use, meta.reconcile.chain} == {"s1", "u2", ["u1", "u2"]}

      :held = Buffer.attest(buf, attestation("c\n", "d\n", "s1", "u3"))
      agent_edits(ctx, buf, "d\n")
      :held = Buffer.attest(buf, attestation("d\n", "e\n", "s2", "u4"))
      agent_edits(ctx, buf, "e\n")

      {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)
      assert List.last(actors(buf)) == :external
    end

    test "a write both held and spooled links once", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx, ledger_dir: ctx.ledger)
      first = attestation("a\n", "b\n", "s1", "u1")
      second = attestation("b\n", "c\n", "s1", "u2")
      :held = Buffer.attest(buf, first)
      :held = Buffer.attest(buf, second)
      # what the payload appends after a `held` answer
      spool!(ctx, [first, second])
      agent_edits(ctx, buf, "c\n")

      {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)
      assert [%{meta: %{reconcile: %{chain: ["u1", "u2"]}}}] = Buffer.history(buf)
      refute File.exists?(spool_file(ctx))
    end

    test "a spool line that lands after the fast-forward can't link later", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx, ledger_dir: ctx.ledger)
      :held = Buffer.attest(buf, attestation("a\n", "b\n"))
      agent_edits(ctx, buf, "b\n")
      {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)

      # the payload's append for that write, late
      spool!(ctx, [attestation("a\n", "b\n")])
      # an unattested write next: the stale line starts from "a\n", not the synced "b\n"
      agent_edits(ctx, buf, "c\n")
      {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)
      assert [{:agent, _}, :external] = actors(buf)
    end

    # A file with history: one you edited and saved. (A ledger with no entries reopens fresh, as
    # any file geex never recorded does, ADR-0033; the payload doesn't spool for it either.)
    test "a crash while holding still credits the write on reopen", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx, ledger_dir: ctx.ledger)
      type(buf, 0, 0, "0")
      {:ok, _} = Buffer.save(buf)
      :held = Buffer.attest(buf, attestation("0a\n", "b\n"))
      spool!(ctx, [attestation("0a\n", "b\n")])
      agent_edits(ctx, buf, "b\n")

      ref = Process.monitor(buf)
      Process.exit(buf, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      buf = open(ctx, ledger_dir: ctx.ledger)
      assert Buffer.get_text(buf) == "b\n"
      assert [:human, {:agent, %{session: "s1"}}] = actors(buf)
    end

    test "an attestation after the fast-forward still upgrades its group", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      agent_edits(ctx, buf, "b\n")
      {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)
      assert actors(buf) == [:external]

      assert Buffer.attest(buf, attestation("a\n", "b\n")) == :attested
      assert [{:agent, %{session: "s1"}}] = actors(buf)
    end
  end

  describe "saving a buffer that is behind (ADR-0034 §3)" do
    test "Buffer.save/1 won't write over a changed disk, noticed or not", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      type(buf, 0, 0, "x")
      # the watcher hasn't reported this one
      File.write!(ctx.doc, "agent\n")

      assert Buffer.save(buf) == {:error, :behind}
      assert File.read!(ctx.doc) == "agent\n"
    end

    test "a clean buffer takes in the disk; the agent's write stays on disk", ctx do
      File.write!(ctx.doc, "a\n")
      buf = open(ctx)
      agent_edits(ctx, buf, "agent\n")

      assert {:ok, _} = Reconcile.save(buf)
      assert File.read!(ctx.doc) == "agent\n"
      assert Buffer.get_text(buf) == "agent\n"
      assert Buffer.snapshot(buf).behind == nil
    end

    test "a dirty buffer with a clean merge writes the merge", ctx do
      File.write!(ctx.doc, "1\n2\n3\n4\n5\n")
      buf = open(ctx)
      type(buf, 0, 0, "MY-")
      # not reported by the watcher yet either
      File.write!(ctx.doc, "1\n2\n3\n4\nFIVE\n")

      assert {:ok, _} = Reconcile.save(buf)
      assert File.read!(ctx.doc) == "MY-1\n2\n3\n4\nFIVE\n"
      refute Buffer.snapshot(buf).dirty
    end

    test "a conflicting merge doesn't write; leftover markers refuse until forced", ctx do
      File.write!(ctx.doc, "keep\nedit me\n")
      buf = open(ctx)
      type(buf, 1, 0, "MINE ")
      agent_edits(ctx, buf, "keep\nDISK\n")

      assert Reconcile.save(buf) == {:conflicts, 1}
      assert File.read!(ctx.doc) == "keep\nDISK\n"
      assert Buffer.get_text(buf) =~ "<<<<<<< buffer"

      # saving again without resolving: refused, naming the block's line
      assert Reconcile.save(buf) == {:markers, 1}
      assert File.read!(ctx.doc) == "keep\nDISK\n"

      # the second Ctrl-O in a row saves anyway
      assert {:ok, _} = Reconcile.save(buf, force: true)
      assert File.read!(ctx.doc) =~ ">>>>>>> disk"
    end

    test "resolving the block and saving writes your resolution", ctx do
      File.write!(ctx.doc, "keep\nedit me\n")
      buf = open(ctx)
      type(buf, 1, 0, "MINE ")
      agent_edits(ctx, buf, "keep\nDISK\n")
      {:conflicts, 1} = Reconcile.save(buf)

      resolve(buf, "keep\nMINE DISK\n")
      assert {:ok, _} = Reconcile.save(buf)
      assert File.read!(ctx.doc) == "keep\nMINE DISK\n"
    end
  end

  test "Alt+L, the `fast-forward` verb and the palette entry are one action" do
    assert Geex.Loop.Keymap.resolve({:alt, ?l}, {0, 0}, "a") == :fast_forward
    assert Geex.Loop.Keymap.resolve({:alt, ?L}, {0, 0}, "a") == :fast_forward
    assert Geex.Loop.Verbs.parse("fast-forward") == {:action, :fast_forward}

    assert %{invoke: {:action, :fast_forward}} =
             Enum.find(Geex.Command.Catalog.all(), &(&1.name == "fast-forward"))
  end

  defp spool_file(ctx), do: Spool.file(Ledger.file(ctx.ledger, ctx.doc))

  defp spool!(ctx, attestations) do
    lines =
      for a <- attestations do
        a
        |> Map.take([:before, :sha256, :harness, :session, :turn, :tool_use])
        |> Map.merge(%{v: 1, path: ctx.doc, at: "2026-10-15T12:00:00Z"})
        |> JSON.encode!()
        |> Kernel.<>("\n")
      end

    File.write!(spool_file(ctx), lines, [:append])
  end

  # Replace the whole text, as a human edit.
  defp resolve(buf, text) do
    lines = String.split(Buffer.get_text(buf), "\n")
    last = length(lines) - 1

    {:ok, cmd} =
      Geex.Commands.Replace.parse(%{
        start_line: 0,
        start_col: 0,
        end_line: last,
        end_col: String.length(List.last(lines)),
        text: text
      })

    {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
  end
end
