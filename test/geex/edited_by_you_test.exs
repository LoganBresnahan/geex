defmodule Geex.EditedByYouTest do
  # ADR-0034 build step 5: you edited the agent's proposed change in the permission prompt
  # (Claude Code's userModified). The intake reads `user_modified`, the actor keeps it through
  # attestation, the spool's chain and the ledger, and the status line and the edits pane say
  # "edited by you".
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Geex.{Attest, Buffer, Edits, Reconcile}
  alias Geex.Ledger.{Restore, Spool}
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
        user_modified: false
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

    test "user_modified: true, false, or absent (false); anything else is refused" do
      assert {:ok, %{user_modified: true}} = Attest.parse(Map.put(@msg, "user_modified", true))
      assert {:ok, %{user_modified: false}} = Attest.parse(Map.put(@msg, "user_modified", false))
      assert {:ok, %{user_modified: false}} = Attest.parse(@msg)
      assert {:error, msg} = Attest.parse(Map.put(@msg, "user_modified", "yes"))
      assert msg =~ "true or false"
    end
  end

  test "the actor keeps it; an unedited write's actor is as before" do
    buf = start_supervised!({Buffer, text: "a\n"})
    :held = Buffer.attest(buf, attestation("a\n", "b\n", %{user_modified: true}))
    {:reconciled, _} = Reconcile.reconcile(buf, "b\n")
    assert [{:agent, %{user_modified: true, tool_use: "u1"}}] = actors(buf)

    other = start_supervised!({Buffer, text: "a\n"}, id: :other)
    {:reconciled, _} = Reconcile.reconcile(other, "b\n")
    :attested = Buffer.attest(other, attestation("a\n", "b\n", %{}))
    assert [{:agent, who}] = actors(other)
    refute Map.has_key?(who, :user_modified)
  end

  test "a chain is marked if you edited any of its writes" do
    e1 = Map.put(attestation("a", "b", %{tool_use: "u1"}), :user_modified, true)
    e2 = attestation("b", "c", %{tool_use: "u2"})

    assert {:ok, {:agent, %{user_modified: true, tool_use: "u2"}}, ["u1", "u2"]} =
             Spool.chain([e1, e2], "a", "c")

    assert {:ok, {:agent, who}, _} = Spool.chain([e2], "b", "c")
    refute Map.has_key?(who, :user_modified)
  end

  test "it survives the ledger: a reopen keeps it" do
    dir = Path.join(System.tmp_dir!(), "geex_ebu_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    doc = Path.join(dir, "doc.txt")
    File.write!(doc, "a\n")
    ledger = Path.join(dir, "ledger")

    {:ok, buf} = Buffer.start_link(path: doc, ledger_dir: ledger)
    Process.unlink(buf)
    File.write!(doc, "b\n")
    :held = Buffer.attest(buf, attestation("a\n", "b\n", %{user_modified: true}))
    {:fast_forwarded, _, 0} = Reconcile.fast_forward(buf)
    GenServer.stop(buf, :shutdown)

    {:ok, buf} = Buffer.start_link(path: doc, ledger_dir: ledger)
    Process.unlink(buf)
    assert [{:agent, %{user_modified: true}}] = actors(buf)
    GenServer.stop(buf, :shutdown)
  end

  test "the status line and the edits pane say so" do
    who = %{harness: "claude-code", session: "7ccbf3d1-aaaa", turn: "b60e1234", tool_use: "u"}

    assert Geex.Loop.author_label([{{:agent, Map.put(who, :user_modified, true)}, 1}], 0) ==
             "✎ claude-code/7ccbf3d1 · turn b60e… · edited by you"

    assert Geex.Loop.author_label([{{:agent, who}, 1}], 0) ==
             "✎ claude-code/7ccbf3d1 · turn b60e…"

    name = :"edits_#{Geex.Fixtures.uniq()}"
    start_supervised!({Edits, name: name})
    Edits.attested(attestation("a", "b", %{path: "/r/f.ex", user_modified: true}), name)
    [entry] = EditsPane.entries([], Edits.rows(name), "/r")
    assert entry.who == "claude-code/s1, edited by you"
  end

  defp actors(buf), do: Enum.map(Buffer.history(buf), & &1.meta.actor)
end
