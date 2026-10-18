defmodule Geex.LedgerAdminTest do
  # `mix geex.ledger list | forget | compact` (ADR-0033 §6), against real ledgers written by
  # real buffers. Each test has its own directory.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import ExUnit.CaptureIO

  alias Geex.{Buffer, Command, History, Ledger, Reconcile}
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Ledger.{Codec, Restore, Spool}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_ledger_admin_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, ledger: Path.join(dir, "ledger"), doc: Path.join(dir, "doc.txt")}
  end

  defp open(ctx, path \\ nil) do
    {:ok, buf} = Buffer.start_link(path: path || ctx.doc, ledger_dir: ctx.ledger)
    Process.unlink(buf)
    buf
  end

  defp close(buf), do: GenServer.stop(buf, :shutdown)
  defp live(buf), do: :sys.get_state(buf).history

  defp type(buf, line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    {:ok, _} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
  end

  # A ledger with typing, a credited agent write, a save, undo/redo, and unsaved edits.
  defp busy_ledger(ctx) do
    File.write!(ctx.doc, "a\nb\nc\n")
    buf = open(ctx)
    for c <- ~w(1 2 3), do: type(buf, 0, 0, c)
    {:ok, _} = Buffer.save(buf)
    File.write!(ctx.doc, "321a\nB\nc\n")
    {:reconciled, _} = Reconcile.reconcile(buf, "321a\nB\nc\n")

    :attested =
      Buffer.attest(buf, %{
        before: Restore.sha256("321a\nb\nc\n"),
        sha256: Restore.sha256("321a\nB\nc\n"),
        harness: "claude-code",
        session: "s1",
        turn: "t",
        tool_use: "u"
      })

    type(buf, 2, 0, "x")
    {:ok, _, _} = Buffer.undo(buf)
    {:ok, _, _} = Buffer.redo(buf)
    type(buf, 2, 0, "y")
    before = live(buf)
    close(buf)
    before
  end

  describe "compact" do
    test "keeps the text, blame, synced text and unsaved edits; undo stops at the checkpoint",
         ctx do
      before = busy_ledger(ctx)
      file = Ledger.file(ctx.ledger, ctx.doc)
      size = File.stat!(file).size

      assert {:ok, %{kept: 2, dropped: 4, before: ^size, after: after_size}} =
               Ledger.compact(file, 2)

      assert after_size < size
      [first | _] = File.read!(file) |> String.split("\n", trim: true)
      assert {:ok, {:checkpoint, _}} = Codec.decode(first)

      buf = open(ctx)
      h = live(buf)
      assert History.text(h) == History.text(before)
      assert h.blame == before.blame
      assert h.synced == before.synced
      assert Buffer.snapshot(buf).dirty
      assert [{{:agent, %{session: "s1"}}, 1} | _] = Enum.drop(h.blame, 1)

      {:ok, _, _} = Buffer.undo(buf)
      {:ok, _, _} = Buffer.undo(buf)
      assert {:error, :nothing_to_undo} = Buffer.undo(buf)
      # the agent's line keeps its credit through the undos (it is in the checkpoint's blame)
      assert {{:agent, _}, 1} = Enum.at(Buffer.snapshot(buf).blame, 1)
      close(buf)
    end

    test "--keep 0 folds everything into the checkpoint; group ids continue after it", ctx do
      busy_ledger(ctx)
      file = Ledger.file(ctx.ledger, ctx.doc)
      assert {:ok, %{kept: 0}} = Ledger.compact(file, 0)

      buf = open(ctx)
      assert Buffer.history(buf) == []
      File.write!(ctx.doc, "new\n")
      {:reconciled, snap} = Reconcile.reconcile(buf, "new\n")
      assert List.last(snap.history).meta.reconcile.group == 2
      close(buf)
    end

    test "compacting twice is fine, and a compacted ledger keeps recording", ctx do
      busy_ledger(ctx)
      file = Ledger.file(ctx.ledger, ctx.doc)
      {:ok, _} = Ledger.compact(file, 3)
      {:ok, _} = Ledger.compact(file, 1)

      buf = open(ctx)
      type(buf, 0, 0, "z")
      text = Buffer.get_text(buf)
      close(buf)
      buf = open(ctx)
      assert Buffer.get_text(buf) == text
      close(buf)
    end

    test "refused while a running geex has the file open", ctx do
      busy_ledger(ctx)
      buf = open(ctx)
      file = Ledger.file(ctx.ledger, ctx.doc)
      assert {:error, {:locked, _}} = Ledger.compact(file, 1)
      assert {:error, {:locked, _}} = Ledger.forget(file)
      close(buf)
    end
  end

  test "a checkpoint anywhere but the first line stops replay", ctx do
    busy_ledger(ctx)
    file = Ledger.file(ctx.ledger, ctx.doc)
    {:ok, _} = Ledger.compact(file, 1)
    [checkpoint | rest] = File.read!(file) |> String.split("\n", trim: true)
    lines = Enum.with_index([hd(rest), checkpoint], fn line, i -> {line, i} end)
    assert {:error, _} = Restore.restore(lines)
  end

  test "forget removes the ledger, its spool and set-aside copies", ctx do
    busy_ledger(ctx)
    file = Ledger.file(ctx.ledger, ctx.doc)
    File.write!(Spool.file(file), "{}\n")
    File.write!(file <> ".corrupt-1", "x")

    assert {:ok, removed} = Ledger.forget(file)
    assert Enum.sort(removed) == Enum.sort([file, Spool.file(file), file <> ".corrupt-1"])
    assert File.ls!(ctx.ledger) == []
  end

  test "list shows path, entries and flags, following a rename", ctx do
    busy_ledger(ctx)
    moved = Path.join(ctx.dir, "moved.txt")
    buf = open(ctx)
    :ok = Buffer.rename(buf, moved)
    type(buf, 0, 0, "m")

    File.write!(
      Spool.file(Ledger.file(ctx.ledger, moved)),
      "{\"before\":\"a\",\"sha256\":\"b\",\"harness\":\"h\",\"session\":\"s\"}\n"
    )

    assert [l] = Ledger.list(ctx.ledger)
    assert l.path == Path.expand(moved)
    assert l.open
    assert l.spooled == 1
    assert l.orphan
    close(buf)

    File.write!(moved, "now it exists\n")
    assert [%{open: false, orphan: false}] = Ledger.list(ctx.ledger)
  end

  describe "the mix task" do
    test "list, forget (dry run, then --yes), compact", ctx do
      busy_ledger(ctx)
      task = &Mix.Tasks.Geex.Ledger.run(&1 ++ ["--dir", ctx.ledger])

      assert capture_io(fn -> task.(["list"]) end) =~ ctx.doc
      assert capture_io(fn -> task.(["compact", ctx.doc, "--keep", "1"]) end) =~ "kept the last 1"
      assert capture_io(fn -> task.(["forget", ctx.doc]) end) =~ "would delete"
      assert File.exists?(Ledger.file(ctx.ledger, ctx.doc))
      assert capture_io(fn -> task.(["forget", ctx.doc, "--yes"]) end) =~ "removed"
      assert capture_io(fn -> task.(["list"]) end) =~ "no ledgers"
    end
  end
end
