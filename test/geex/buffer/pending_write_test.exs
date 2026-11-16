defmodule Geex.Buffer.PendingWriteTest do
  # A save's write outside the buffer (ADR-0035's 2026-11-15 amendment): `begin_write/2` and
  # `end_write/2`, the buffer answering in between, edits made during the write, a failed or
  # dead writer, the watcher seeing the write, and `Reconcile.save/2`'s gate. Some tests stand in
  # for the reconciler under its registered name, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Reconcile}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_pending_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: Path.join(dir, "a.txt"), ledger: Path.join(dir, "ledger")}
  end

  defp open(ctx, text, opts \\ []) do
    File.write!(ctx.path, text)
    {:ok, buf} = Buffer.start_link([path: ctx.path] ++ opts)
    Process.unlink(buf)
    on_exit(fn -> if Process.alive?(buf), do: GenServer.stop(buf) end)
    buf
  end

  defp insert(buf, line, col, text) do
    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: line, col: col, text: text})
    {:ok, _} = Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))
  end

  defp sha(text), do: Geex.Ledger.Restore.sha256(text)

  # Stand in for the reconciler, which isn't started under `mix test`, to see a buffer ask for
  # its file to be read again.
  defp as_reconciler do
    refute Process.whereis(Geex.Reconcile)
    Process.register(self(), Geex.Reconcile)
    on_exit(fn -> if Process.whereis(Geex.Reconcile), do: Process.unregister(Geex.Reconcile) end)
  end

  test "the buffer answers while the write is under way; nothing changed, the save is kept",
       ctx do
    buf = open(ctx, "a  \n")
    path = ctx.path

    assert {:ok, %{path: ^path, text: "a\n", synced: "a  \n"}} =
             Buffer.begin_write(buf, trim_trailing_whitespace: true)

    # Frames read the buffer, and keys reach it, in between: the save's trim isn't kept yet.
    assert Buffer.snapshot(buf).text == "a  \n"
    assert Buffer.status(buf).behind == nil

    File.write!(path, "a\n")
    assert Buffer.end_write(buf, :ok) == {:ok, path}
    assert Buffer.get_text(buf) == "a\n"
    refute Buffer.status(buf).dirty
    # The trim, one step, yours.
    assert [%{meta: %{actor: :human}}] = Buffer.history(buf)
  end

  test "an edit during the write lands and stays unsaved; the written text is the synced one",
       ctx do
    buf = open(ctx, "a  \nb\n", ledger_dir: ctx.ledger)
    {:ok, w} = Buffer.begin_write(buf, trim_trailing_whitespace: true)
    insert(buf, 1, 0, "x")
    File.write!(w.path, w.text)
    assert {:ok, _} = Buffer.end_write(buf, :ok)

    # The edit; the trim, made against the text before it, is the file's, not the buffer's.
    assert Buffer.get_text(buf) == "a  \nxb\n"
    assert %{dirty: true, behind: nil} = Buffer.status(buf)
    assert Buffer.status(buf).synced == sha("a\nb\n")
    assert Buffer.disk_changed(buf, File.read!(ctx.path)) == :in_sync

    # Kept across a reopen: the ledger has the synced text.
    GenServer.stop(buf)
    buf = open_again(ctx)
    assert Buffer.get_text(buf) == "a  \nxb\n"
    assert %{dirty: true} = Buffer.status(buf)
    assert Buffer.status(buf).synced == sha("a\nb\n")

    # The next save makes the trim again, with the edit.
    assert {:ok, _} = Buffer.save(buf, trim_trailing_whitespace: true)
    assert File.read!(ctx.path) == "a\nxb\n"
    refute Buffer.status(buf).dirty
  end

  defp open_again(ctx) do
    {:ok, buf} = Buffer.start_link(path: ctx.path, ledger_dir: ctx.ledger)
    Process.unlink(buf)
    on_exit(fn -> if Process.alive?(buf), do: GenServer.stop(buf) end)
    buf
  end

  test "a failed write leaves the buffer as it was, and it can begin again", ctx do
    buf = open(ctx, "a  ")
    insert(buf, 0, 0, "z")
    before = Buffer.history(buf)

    {:ok, _} = Buffer.begin_write(buf, trim_trailing_whitespace: true, final_newline: true)
    assert Buffer.end_write(buf, {:error, :eacces}) == {:error, :eacces}
    assert Buffer.get_text(buf) == "za  "
    assert Buffer.history(buf) == before
    assert Buffer.status(buf).dirty
    assert {:ok, _} = Buffer.begin_write(buf)
  end

  test "one write at a time, and only its writer ends it", ctx do
    buf = open(ctx, "a\n")
    {:ok, _} = Buffer.begin_write(buf)
    assert Buffer.begin_write(buf) == {:error, :saving}
    assert Task.await(Task.async(fn -> Buffer.end_write(buf, :ok) end)) == {:error, :not_writing}
    assert Buffer.end_write(buf, :ok) == {:ok, ctx.path}
    assert Buffer.end_write(buf, :ok) == {:error, :not_writing}
  end

  test "the watcher seeing the text being written: geex's own; a fast-forward waits", ctx do
    buf = open(ctx, "a  \n")
    {:ok, w} = Buffer.begin_write(buf, trim_trailing_whitespace: true)
    File.write!(w.path, w.text)

    assert Buffer.disk_changed(buf, w.text) == :in_sync
    assert Buffer.status(buf).behind == nil
    assert Buffer.dispatch_group(buf, [], baseline: w.text) == {:error, :saving}
    assert Reconcile.fast_forward(buf) == {:error, :saving}

    assert {:ok, _} = Buffer.end_write(buf, :ok)
    assert Buffer.disk_changed(buf, w.text) == :in_sync
    refute Buffer.status(buf).dirty
  end

  test "anything else seen during the write is read again once it is done", ctx do
    as_reconciler()
    path = ctx.path
    buf = open(ctx, "a\n")

    {:ok, _} = Buffer.begin_write(buf)
    # Half-written, or an outside write racing geex's: not marked behind now.
    assert Buffer.disk_changed(buf, "a half-wri") == :in_sync
    assert Buffer.status(buf).behind == nil
    {:ok, _} = Buffer.end_write(buf, :ok)
    assert_receive {:recheck, ^path}

    # A write the watcher saw nothing odd during asks for nothing.
    {:ok, _} = Buffer.begin_write(buf)
    {:ok, _} = Buffer.end_write(buf, :ok)
    refute_receive {:recheck, _}, 50
  end

  test "a writer that dies before end_write: a failed save, the file read again", ctx do
    as_reconciler()
    path = ctx.path
    buf = open(ctx, "a  \n")

    {_pid, ref} =
      spawn_monitor(fn -> {:ok, _} = Buffer.begin_write(buf, trim_trailing_whitespace: true) end)

    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert_receive {:recheck, ^path}
    assert Buffer.get_text(buf) == "a  \n"
    assert Buffer.history(buf) == []
    assert {:ok, _} = Buffer.begin_write(buf)
  end

  # mod-verify's review: the history it began on came back at the end, losing the credit.
  test "an attestation credited during the write is kept with the save's own edits", ctx do
    buf = open(ctx, "1\n2\n3\n")
    # An agent's write, taken in as :external, with trailing spaces for the save to trim.
    {:reconciled, _} = Reconcile.reconcile(buf, "ONE  \n2\nTHREE\n")
    File.write!(ctx.path, "ONE  \n2\nTHREE\n")
    {:ok, w} = Buffer.begin_write(buf, trim_trailing_whitespace: true)

    attestation = %{
      path: ctx.path,
      before: sha("1\n2\n3\n"),
      sha256: sha("ONE  \n2\nTHREE\n"),
      harness: "claude-code",
      session: "s1",
      turn: "p1",
      tool_use: "t1"
    }

    assert Buffer.attest(buf, attestation) == :attested
    File.write!(w.path, w.text)
    assert {:ok, _} = Buffer.end_write(buf, :ok)

    assert [{:agent, _}, {:agent, _}, :human] =
             Enum.map(Buffer.history(buf), & &1.meta.actor)

    assert Buffer.get_text(buf) == "ONE\n2\nTHREE\n"
    refute Buffer.status(buf).dirty
  end

  test "a failed write has the file read again: it may hold part or all of it", ctx do
    as_reconciler()
    path = ctx.path
    buf = open(ctx, "a\n")
    {:ok, _} = Buffer.begin_write(buf)
    assert Buffer.end_write(buf, {:error, :eio}) == {:error, :eio}
    assert_receive {:recheck, ^path}
  end

  test "held for a rename, delete or close: no save begins; refused while one writes", ctx do
    buf = open(ctx, "a\n")
    assert Buffer.status(buf).saving == false

    {:ok, _} = Buffer.begin_write(buf)
    assert Buffer.status(buf).saving
    assert Buffer.hold(buf) == {:error, :saving}
    {:ok, _} = Buffer.end_write(buf, :ok)

    assert Buffer.hold(buf) == :ok
    assert Buffer.begin_write(buf) == {:error, :held}
    assert Buffer.save(buf) == {:error, :held}
    assert Buffer.release(buf) == :ok
    assert {:ok, _} = Buffer.begin_write(buf)
    {:ok, _} = Buffer.end_write(buf, :ok)

    # A rename re-keys it and lets saves begin again, at the new path.
    :ok = Buffer.hold(buf)
    to = ctx.path <> ".moved"
    :ok = Buffer.rename(buf, to)
    assert {:ok, %{path: ^to}} = Buffer.begin_write(buf)
  end

  test "Reconcile.save's gate: cancelled before the write begins, nothing written or begun",
       ctx do
    buf = open(ctx, "a  \n")
    insert(buf, 0, 0, "z")

    assert Reconcile.save(buf, trim_trailing_whitespace: true, gate: fn -> :cancelled end) ==
             {:error, :cancelled}

    assert File.read!(ctx.path) == "a  \n"
    assert Buffer.get_text(buf) == "za  \n"
    assert {:ok, _} = Buffer.begin_write(buf)
  end

  test "the file checked in the caller: a file changed on disk is refused, nothing kept", ctx do
    buf = open(ctx, "a  \n")
    File.write!(ctx.path, "changed\n")
    assert Buffer.save(buf, trim_trailing_whitespace: true) == {:error, :behind}
    assert File.read!(ctx.path) == "changed\n"
    assert Buffer.history(buf) == []
    assert {:ok, _} = Buffer.begin_write(buf)
  end
end
