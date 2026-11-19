defmodule Geex.WhileCreditTest do
  # ADR-0032's 2026-11-18 amendment: a credit by time. The payload brackets an agent's Bash call
  # with a git snapshot, so a match proves the file changed *while* the call ran, not that it
  # changed it. The intake reads `during` and `program`, the actor keeps them through
  # attestation, the spool's chain, the ledger and the edits log, and every place that names
  # the writer says "while", never authorship.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Geex.{Attest, Buffer, Edits, Reconcile, Screen}
  alias Geex.Edits.Log
  alias Geex.Ledger.{Restore, Spool}
  alias Geex.Loop
  alias Geex.Loop.EditsPane

  defp hex(text), do: Restore.sha256(text)

  defp attestation(before, after_text, extra) do
    Map.merge(
      %{
        path: "/unused",
        before: hex(before),
        sha256: hex(after_text),
        harness: "claude-code",
        session: "s1",
        turn: "t1",
        tool_use: "u1",
        user_modified: false,
        during: "Bash",
        program: "sed"
      },
      extra
    )
  end

  describe "the intake" do
    @msg %{
      "v" => 1,
      "path" => "/f",
      "before" => String.duplicate("b", 64),
      "sha256" => String.duplicate("a", 64),
      "harness" => "claude-code",
      "session" => "s1"
    }

    test "during and program are read; absent, they are nil" do
      msg = Map.merge(@msg, %{"during" => "Bash", "program" => "python3"})
      assert {:ok, %{during: "Bash", program: "python3"}} = Attest.parse(msg)
      assert {:ok, %{during: nil, program: nil}} = Attest.parse(@msg)
    end

    test "a garbled during is refused, never read as absent (that would show authorship)" do
      for bad <- ["", "Bash; rm", 1, true, %{}, String.duplicate("x", 40)] do
        assert {:error, msg} = Attest.parse(Map.put(@msg, "during", bad)), inspect(bad)
        assert msg =~ "tool name"
      end
    end

    test "a program that isn't a plain name is dropped: display only, never a reason to refuse" do
      for bad <- ["sed -i x", "a/b", "", 7, String.duplicate("p", 65)] do
        msg = Map.merge(@msg, %{"during" => "Bash", "program" => bad})
        assert {:ok, %{during: "Bash", program: nil}} = Attest.parse(msg), inspect(bad)
      end
    end
  end

  test "the actor keeps it, held or late; a writer's credit is as before" do
    buf = start_supervised!({Buffer, text: "a\n"})
    :held = Buffer.attest(buf, attestation("a\n", "b\n", %{}))
    {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
    assert [{:agent, %{during: "Bash", program: "sed", tool_use: "u1"}}] = actors(buf)

    late = start_supervised!({Buffer, text: "a\n"}, id: :late)
    {:reconciled, _} = Reconcile.reconcile(late, "b\n")
    :attested = Buffer.attest(late, attestation("a\n", "b\n", %{program: nil}))
    assert [{:agent, who}] = actors(late)
    assert who.during == "Bash"
    refute Map.has_key?(who, :program)

    writer = start_supervised!({Buffer, text: "a\n"}, id: :writer)
    {:reconciled, _} = Reconcile.reconcile(writer, "b\n")
    :attested = Buffer.attest(writer, attestation("a\n", "b\n", %{during: nil, program: nil}))
    assert [{:agent, who}] = actors(writer)
    refute Map.has_key?(who, :during)
  end

  test "a chain with any credit by time is one: the weaker claim wins" do
    e1 = attestation("a", "b", %{tool_use: "u1", program: nil})
    e2 = attestation("b", "c", %{tool_use: "u2", during: nil, program: nil})

    assert {:ok, {:agent, %{during: "Bash", tool_use: "u2"}}, ["u1", "u2"]} =
             Spool.chain([e1, e2], "a", "c")

    assert {:ok, {:agent, who}, _} = Spool.chain([e2], "b", "c")
    refute Map.has_key?(who, :during)
  end

  test "it survives the ledger: a reopen still says while" do
    dir = Path.join(System.tmp_dir!(), "geex_while_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    doc = Path.join(dir, "doc.txt")
    File.write!(doc, "a\n")
    ledger = Path.join(dir, "ledger")

    {:ok, buf} = Buffer.start_link(path: doc, ledger_dir: ledger)
    Process.unlink(buf)
    File.write!(doc, "b\n")
    :held = Buffer.attest(buf, attestation("a\n", "b\n", %{}))
    {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)
    GenServer.stop(buf, :shutdown)

    {:ok, buf} = Buffer.start_link(path: doc, ledger_dir: ledger)
    Process.unlink(buf)
    assert [{:agent, %{during: "Bash", program: "sed"}}] = actors(buf)
    GenServer.stop(buf, :shutdown)
  end

  test "a spooled credit by time, on reopen: the notice says changed while, not credited to" do
    dir = Path.join(System.tmp_dir!(), "geex_while_spool_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    doc = Path.join(dir, "doc.txt")
    File.write!(doc, "a\n")
    ledger = Path.join(dir, "ledger")

    {:ok, buf} = Buffer.start_link(path: doc, ledger_dir: ledger)
    Process.unlink(buf)
    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "x"})
    {:ok, _} = Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))
    {:ok, _} = Buffer.save(buf)
    GenServer.stop(buf, :shutdown)

    # An agent's Bash call changed the closed file; the payload spooled it (no program there).
    File.write!(doc, "xb\n")
    spool = Spool.file(Geex.Ledger.file(ledger, doc))

    line =
      JSON.encode!(%{
        "v" => 1,
        "path" => doc,
        "before" => hex("xa\n"),
        "sha256" => hex("xb\n"),
        "harness" => "claude-code",
        "session" => "s1",
        "tool_use" => "u1",
        "during" => "Bash",
        "at" => "2026-11-19T10:00:00Z"
      })

    File.write!(spool, line <> "\n")

    {:ok, buf} = Buffer.start_link(path: doc, ledger_dir: ledger)
    Process.unlink(buf)
    {:ok, _} = Buffer.subscribe(buf, self())
    assert_receive {:geex_buffer_notice, ^buf, notice}
    assert notice =~ "; changed while claude-code/s1 ran Bash (1 edit)"
    refute notice =~ "credited to"
    assert {:agent, %{during: "Bash"}} = List.last(Buffer.history(buf)).meta.actor
    GenServer.stop(buf, :shutdown)
  end

  test "it survives the edits log" do
    who = Attest.who(attestation("a", "b", %{}))

    row = %{
      path: "/r/f.ex",
      who: {:agent, who},
      at: ~N[2026-11-19 10:00:00],
      sha256: "h",
      tool_use: "u1"
    }

    assert {:ok, %{who: {:agent, %{during: "Bash", program: "sed"}}}} =
             row |> Log.encode() |> String.trim() |> Log.decode()
  end

  test "the status line, the edits pane, the revert's names and the gutter say while" do
    who = %{harness: "claude-code", session: "7ccbf3d1-aaaa", turn: "b60e1234", tool_use: "u"}
    bash = Map.merge(who, %{during: "Bash", program: "python3"})

    assert Loop.author_label([{{:agent, bash}, 1}], 0) ==
             "✎ claude-code/7ccbf3d1 · turn b60e… · while python3"

    assert Loop.author_label([{{:agent, Map.delete(bash, :program)}, 1}], 0) ==
             "✎ claude-code/7ccbf3d1 · turn b60e… · while Bash"

    assert Loop.author_label([{{:agent, who}, 1}], 0) == "✎ claude-code/7ccbf3d1 · turn b60e…"

    name = :"edits_#{Geex.Fixtures.uniq()}"
    start_supervised!({Edits, name: name})
    Edits.attested(attestation("a", "b", %{path: "/r/f.ex"}), name)
    [entry] = EditsPane.entries([], Edits.rows(name), "/r")
    assert entry.who == "claude-code/s1 (while Bash)"

    theme = Geex.Fixtures.birds()
    {screen, _cursor, _h} = Loop.frame("a\nb\nc", [], theme, {0, 0}, 30, 3, 0)
    blame = [{{:agent, bash}, 1}, {{:agent, who}, 2}, nil]
    marked = Loop.agent_marks(screen, blame, 0, 3, theme)
    assert Screen.get_cell(marked, 0, 0).char == "╎"
    assert Screen.get_cell(marked, 0, 1).char == "▌"
    # The session's colour either way: the same session, a weaker claim.
    assert Screen.get_cell(marked, 0, 0).fg == Screen.get_cell(marked, 0, 1).fg
  end

  defp actors(buf), do: Enum.map(Buffer.history(buf), & &1.meta.actor)
end
