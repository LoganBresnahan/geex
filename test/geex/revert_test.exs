defmodule Geex.RevertTest do
  use ExUnit.Case, async: true

  alias Geex.{Buffer, Command, History, Reconcile, Revert}
  alias Geex.Command.Meta
  alias Geex.Commands.Insert
  alias Geex.Ledger
  alias Geex.Loop.Verbs

  @agent {:agent, %{harness: "claude-code", session: "7ccbf3d1-aaaa", turn: "t", tool_use: "u"}}

  # An out-of-band write recorded the way reconcile records it, credited to `actor`.
  defp outside(h, new_text, actor \\ @agent) do
    old = History.text(h)

    commands =
      old
      |> Reconcile.external_commands(new_text, h.synced, new_text)
      |> Enum.map(&History.put_actor(&1, actor))

    {:ok, h} = History.group(h, commands, new_text)
    h
  end

  defp type(h, line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    {:ok, h} = History.dispatch(h, Command.put_meta(cmd, Meta.human()))
    h
  end

  defp apply_plan(h, line, scope) do
    {:ok, commands, info} = Revert.plan(h, line, scope)
    {:ok, h} = History.group(h, commands, nil)
    {h, commands, info}
  end

  describe "plan/3" do
    setup do
      # the agent rewrites lines 2 and 4 in one tool call (two hunks); you then edit line 1
      h = History.new("1\n2\n3\n4\n5\n") |> outside("1\nTWO\n3\nFOUR\n5\n") |> type(0, 0, "my-")
      %{h: h}
    end

    test "revert-call takes back the whole tool call and keeps your later edit", %{h: h} do
      {h, commands, info} = apply_plan(h, 1, :call)
      assert History.text(h) == "my-1\n2\n3\n4\n5\n"
      assert info == %{actor: @agent, group: 1, hunks: 2}

      for c <- commands do
        assert c.meta.actor == :human
        assert c.meta.reverts == %{group: 1, scope: :call}
      end

      # the reverted lines are yours now: no agent mark left
      refute Enum.any?(h.blame, &match?({{:agent, _}, _}, &1))
    end

    test "revert (one hunk) takes back only the hunk under the cursor", %{h: h} do
      {h, _commands, info} = apply_plan(h, 3, :hunk)
      assert History.text(h) == "my-1\nTWO\n3\n4\n5\n"
      assert info.hunks == 1
      assert {{:agent, _}, 1} = Enum.at(h.blame, 1)
    end

    test "your later edit on the agent's lines refuses it, naming the lines", %{h: h} do
      h = type(h, 1, 0, "x")
      # your edits on lines 1 and 2 are adjacent, so they read as one change, lines 1-2
      assert Revert.plan(h, 3, :call) == {:error, {:overlap, @agent, [{1, 2}]}}
      # the other hunk is untouched by your edit, so it alone can still go
      assert {:ok, _commands, %{hunks: 1}} = Revert.plan(h, 3, :hunk)
    end

    test "an edit on one agent line names exactly that line", %{h: h} do
      h = type(h, 3, 0, "x")
      assert Revert.plan(h, 1, :call) == {:error, {:overlap, @agent, [{4, 4}]}}
    end

    test "lines shifted by later inserts still map to the right hunk", %{h: h} do
      h = type(h, 0, 0, "new top\n")
      {h, _commands, _info} = apply_plan(h, 4, :hunk)
      assert History.text(h) == "new top\nmy-1\nTWO\n3\n4\n5\n"
    end

    test "a later agent change on an adjacent line doesn't block", %{h: h} do
      h = outside(h, "my-1\nTWO\nTHREE\nFOUR\n5\n", {:agent, %{harness: "x", session: "other"}})
      {h, _commands, _info} = apply_plan(h, 1, :call)
      assert History.text(h) == "my-1\n2\nTHREE\n4\n5\n"
    end

    test "lines no change wrote: loaded text, your own edits", %{h: h} do
      assert Revert.plan(h, 2, :call) == {:error, :not_a_change}
      assert Revert.plan(h, 0, :call) == {:error, :not_a_change}
    end
  end

  test "a deletion in the tool call comes back with revert-call" do
    h = History.new("a\nb\nc\n") |> outside("A\nc\n")
    {h, _commands, _info} = apply_plan(h, 0, :call)
    assert History.text(h) == "a\nb\nc\n"
  end

  test "an outside (unattested) change can be reverted too" do
    h = History.new("a\nb\n") |> outside("a\nSED\n", :external)
    {h, _commands, info} = apply_plan(h, 1, :hunk)
    assert History.text(h) == "a\nb\n"
    assert info.actor == :external
  end

  test "Alt+U reverts the hunk under the cursor; Alt+R is still line start" do
    assert Geex.Loop.Keymap.resolve({:alt, ?u}, {3, 2}, "a\nb\nc\nd") == :revert_hunk
    assert Geex.Loop.Keymap.resolve({:alt, ?r}, {3, 2}, "a\nb\nc\nd") == {:move, {3, 0}}
  end

  test "the typed verbs" do
    assert Verbs.parse("revert") == {:action, :revert_hunk}
    assert Verbs.parse("revert-call") == {:action, :revert_call}
  end

  describe "through the buffer" do
    test "a revert is an ordinary edit: undo brings the agent's change and its mark back" do
      buf = start_supervised!({Buffer, text: "1\n2\n"})
      {:reconciled, _} = Reconcile.reconcile(buf, "1\nTWO\n")

      Buffer.attest(buf, %{
        before: Ledger.Restore.sha256("1\n2\n"),
        sha256: Ledger.Restore.sha256("1\nTWO\n"),
        harness: "claude-code",
        session: "7ccbf3d1-aaaa",
        turn: "t",
        tool_use: "u"
      })

      {:ok, snap, %{hunks: 1}} = Buffer.revert(buf, 1, :hunk)
      assert snap.text == "1\n2\n"
      assert snap.dirty

      {:ok, snap, _} = Buffer.undo(buf)
      assert snap.text == "1\nTWO\n"
      assert {{:agent, _}, _} = Enum.at(snap.blame, 1)
    end

    test "a refused revert changes nothing" do
      buf = start_supervised!({Buffer, text: "1\n"})
      before = Buffer.snapshot(buf)
      assert {:error, :not_a_change} = Buffer.revert(buf, 0, :call)
      assert Buffer.snapshot(buf) == before
    end

    test "the revert's provenance survives the ledger" do
      dir = Path.join(System.tmp_dir!(), "geex_revert_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "f.txt")
      File.write!(path, "a\nb\n")

      {:ok, buf} = Buffer.start_link(path: path, ledger_dir: Path.join(dir, "ledger"))
      Process.unlink(buf)
      File.write!(path, "a\nB\n")
      {:reconciled, _} = Reconcile.reconcile(buf, "a\nB\n")
      {:ok, _, _} = Buffer.revert(buf, 1, :call)
      live = :sys.get_state(buf).history
      GenServer.stop(buf, :shutdown)

      {:ok, restored} =
        Ledger.load(%{Ledger.new(Path.join(dir, "ledger"), path) | locked: true})

      assert restored.history == live

      assert List.last(History.commands_oldest_first(live)).meta.reverts == %{
               group: 1,
               scope: :call
             }
    end
  end
end
