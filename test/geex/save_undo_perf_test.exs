defmodule Geex.SaveUndoPerfTest do
  # mod-verify's review of `save-undo`: a big trimming save was quadratic (one command per line),
  # and a reopen after undoing a big step replayed the document once per undone command. Each
  # must now cost about one pass over the document. The bounds are generous: the old costs were
  # seconds to tens of seconds.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Reconcile}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_save_undo_perf_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{ledger: Path.join(dir, "ledger"), doc: Path.join(dir, "big.txt")}
  end

  defp open(ctx) do
    {:ok, buf} = Buffer.start_link(path: ctx.doc, ledger_dir: ctx.ledger)
    Process.unlink(buf)
    buf
  end

  defp close(buf), do: GenServer.stop(buf, :shutdown)

  defp ms(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  test "a trimming save of 20,000 lines, every one trailing, is one pass; so is its reopen",
       ctx do
    text = Enum.map_join(1..20_000, &"line #{&1}  \n")
    File.write!(ctx.doc, text)
    buf = open(ctx)

    {took, {:ok, _}} =
      ms(fn -> Buffer.save(buf, trim_trailing_whitespace: true, final_newline: true) end)

    assert took < 1000, "the save took #{took} ms"
    assert File.read!(ctx.doc) == Enum.map_join(1..20_000, &"line #{&1}\n")

    {took, {:ok, %{step: 1}, _}} = ms(fn -> Buffer.undo(buf) end)
    assert took < 1000, "the undo took #{took} ms"
    close(buf)

    {took, buf} = ms(fn -> open(ctx) end)
    assert took < 2000, "the reopen took #{took} ms"
    assert Buffer.get_text(buf) == text
    close(buf)
  end

  test "a reopen after undoing a step of 1,000 hunks folds the undos into one replay", ctx do
    lines = Enum.map(1..2_000, &"l#{&1}")
    File.write!(ctx.doc, Enum.join(lines, "\n") <> "\n")
    buf = open(ctx)

    # An outside write changing every other line: 1,000 hunks, one step.
    disk =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {l, i} -> if rem(i, 2) == 0, do: l <> "!", else: l end)
      |> Kernel.<>("\n")

    File.write!(ctx.doc, disk)
    {:reconciled, _} = Reconcile.reconcile(buf, disk)
    {:ok, %{step: 1000}, _} = Buffer.undo(buf)
    close(buf)

    {took, buf} = ms(fn -> open(ctx) end)
    assert took < 3000, "the reopen took #{took} ms"
    assert {:ok, %{step: 1000}, _} = Buffer.redo(buf)
    close(buf)
  end
end
