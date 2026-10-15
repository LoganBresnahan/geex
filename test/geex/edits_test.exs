defmodule Geex.EditsTest do
  # The edits list and pane (ADR-0034 build step 3): rows from attestations, disk changes and
  # saves, joined by {path, sha256}; the pane's entries and text; the layout. Each test starts
  # its own Geex.Edits.
  use ExUnit.Case, async: true
  doctest Geex.Layout
  doctest Geex.Loop.EditsPane

  alias Geex.{Edits, Layout}
  alias Geex.Loop.EditsPane

  setup do
    name = :"edits_#{System.unique_integer([:positive])}"
    start_supervised!({Edits, name: name, max: 5})
    %{edits: name}
  end

  defp attestation(path, sha, session \\ "s1", tool_use \\ "u1"),
    do: %{
      path: path,
      before: "b",
      sha256: sha,
      harness: "claude-code",
      session: session,
      turn: "t",
      tool_use: tool_use
    }

  defp whos(edits), do: edits |> Edits.rows() |> Enum.map(&{&1.path, &1.who})

  test "an attestation is a row, newest first; subscribers hear of it", %{edits: e} do
    :ok = Edits.subscribe(self(), e)
    Edits.attested(attestation("/r/a.ex", "h1"), e)
    Edits.saved("/r/b.ex", e)

    assert_receive {:geex_edits, :changed}
    assert [{"/r/b.ex", :you}, {"/r/a.ex", {:agent, %{session: "s1", tool_use: "u1"}}}] = whos(e)
    assert %NaiveDateTime{} = hd(Edits.rows(e)).at
  end

  test "a disk change the attestation already explains adds nothing", %{edits: e} do
    Edits.attested(attestation("/r/a.ex", "h1"), e)
    Edits.disk_changed("/r/a.ex", "h1", e)
    assert [{"/r/a.ex", {:agent, _}}] = whos(e)
  end

  test "an outside row becomes the agent's when its attestation arrives", %{edits: e} do
    Edits.disk_changed("/r/a.ex", "h1", e)
    assert [{"/r/a.ex", :outside}] = whos(e)

    Edits.attested(attestation("/r/a.ex", "h1"), e)
    assert [%{who: {:agent, %{tool_use: "u1"}}, tool_use: "u1"}] = Edits.rows(e)
    # a repeat of it adds nothing
    Edits.attested(attestation("/r/a.ex", "h1"), e)
    assert length(Edits.rows(e)) == 1
  end

  test "a different change to the same file is its own row", %{edits: e} do
    Edits.disk_changed("/r/a.ex", "h1", e)
    Edits.disk_changed("/r/a.ex", "h2", e)
    assert [{"/r/a.ex", :outside}, {"/r/a.ex", :outside}] = whos(e)
  end

  test "bounded: the oldest rows go", %{edits: e} do
    for i <- 1..7, do: Edits.disk_changed("/r/f#{i}", "h#{i}", e)
    assert e |> Edits.rows() |> Enum.map(& &1.path) == ~w(/r/f7 /r/f6 /r/f5 /r/f4 /r/f3)
  end

  describe "the pane's entries" do
    test "behind buffers are pinned first; only files under the root" do
      at = ~N[2026-10-15 09:05:00]
      behind = %{sha256: "x", at: ~U[2026-10-15 12:00:00Z]}

      buffers = [
        %{pid: self(), path: "/r/held.ex", dirty: false, behind: behind},
        %{pid: self(), path: "/r/fine.ex", dirty: false, behind: nil},
        %{pid: self(), path: nil, dirty: false, behind: nil}
      ]

      rows = [
        %{path: "/r/x.ex", who: :outside, at: at, sha256: "s", tool_use: nil},
        %{path: "/other/y.ex", who: :you, at: at, sha256: nil, tool_use: nil}
      ]

      assert [
               %{kind: :behind, path: "/r/held.ex", who: "disk is newer"},
               %{kind: :edit, path: "/r/x.ex", who: "outside", time: "09:05"}
             ] = EditsPane.entries(buffers, rows, "/r")

      # no root: everything
      assert length(EditsPane.entries(buffers, rows, nil)) == 3
    end

    test "rows scroll to keep the selection visible, and long names are cut" do
      entries =
        for i <- 1..6,
            do: %{kind: :edit, path: "/r/file#{i}.ex", who: "you", time: "10:0#{i}", row: nil}

      lines = EditsPane.lines(entries, "/r", 40, 3, 5, true)

      assert Enum.map(lines, fn {_t, e, sel} -> {e.path, sel} end) ==
               [{"/r/file4.ex", false}, {"/r/file5.ex", false}, {"/r/file6.ex", true}]

      assert {"▸ file6.ex" <> _, _, true} = List.last(lines)

      long = %{
        kind: :edit,
        path: "/r/" <> String.duplicate("a", 50),
        who: "you",
        time: "10:00",
        row: nil
      }

      [{text, _, _}] = EditsPane.lines([long], "/r", 30, 1, 0, false)
      assert String.length(text) <= 30
      assert text =~ "…"
    end
  end

  test "the layout drops the edits band in a short terminal" do
    assert %{edits: nil, editor: %{h: 10}, status: 10} = Layout.resolve(80, 11, %{edits: true})
    assert %{edits: %{y: 20, h: 9}, editor: %{h: 20}} = Layout.resolve(80, 30, %{edits: true})
  end
end
