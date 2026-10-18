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
    name = :"edits_#{Geex.Fixtures.uniq()}"
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

  describe "kept across restarts (ADR-0034 §6, amended 2026-10-18)" do
    alias Geex.Edits.Log

    setup do
      dir = Path.join(System.tmp_dir!(), "geex_edits_#{Geex.Fixtures.uniq()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{tmp_dir: dir}
    end

    doctest Geex.Edits
    doctest Geex.Edits.Log

    defp kept_row(path, who, sha256 \\ nil),
      do: %{path: path, who: who, at: ~N[2026-10-17 09:00:00], sha256: sha256, tool_use: nil}

    defp start_kept(file) do
      name = :"kept_#{Geex.Fixtures.uniq()}"
      pid = start_supervised!({Edits, name: name, file: file}, id: name)
      {name, pid}
    end

    test "the rows come back as earlier ones, in order, an upgrade as one row",
         %{tmp_dir: dir} do
      file = Path.join([dir, "state", "geex", "edits.jsonl"])
      {e, pid} = start_kept(file)
      Edits.disk_changed("/r/a.ex", "h1", e)
      Edits.attested(attestation("/r/a.ex", "h1"), e)
      Edits.saved("/r/b.ex", e)
      Edits.disk_changed("/r/c.ex", "h3", e)
      before = Edits.rows(e)
      stop_supervised!(e)
      refute Process.alive?(pid)

      # Three lines for a.ex's row and its upgrade, b.ex and c.ex: four in all.
      assert file |> File.read!() |> String.split("\n", trim: true) |> length() == 4
      assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(Path.dirname(file)).mode |> Bitwise.band(0o777) == 0o700

      {e2, _} = start_kept(file)
      rows = Edits.rows(e2)
      assert Enum.map(rows, &Map.delete(&1, :earlier)) == before
      assert Enum.all?(rows, & &1.earlier)
      assert [{"/r/c.ex", :outside}, {"/r/b.ex", :you}, {"/r/a.ex", {:agent, _}}] = whos(e2)

      # This run's rows come first, the earlier ones after.
      Edits.saved("/r/d.ex", e2)
      assert [%{path: "/r/d.ex"} = d | _] = Edits.rows(e2)
      refute Map.has_key?(d, :earlier)
      assert length(Edits.rows(e2)) == 4
    end

    @tag :capture_log
    test "a torn last line and lines that aren't rows are skipped; geex carries on",
         %{tmp_dir: dir} do
      file = Path.join(dir, "edits.jsonl")
      good = Log.encode(kept_row("/r/a.ex", :you))

      File.write!(file, [
        good,
        "not json\n",
        ~s|{"v":2,"path":"/r/x"}\n|,
        <<0xFF, 0xFE, ?\n>>,
        String.trim_trailing(good)
      ])

      {e, _} = start_kept(file)
      assert [{"/r/a.ex", :you}] = whos(e)

      # A file of garbage throughout: no rows, and the list still works.
      File.write!(file, :crypto.strong_rand_bytes(4096))
      {e, _} = start_kept(file)
      assert Edits.rows(e) == []
      Edits.saved("/r/b.ex", e)
      assert [{"/r/b.ex", :you}] = whos(e)
    end

    # The coordinator's repro: a write torn mid-line (a full disk, a crash), then geex appends.
    # The appended rows must start lines of their own, not join the fragment and be lost with it.
    @tag :capture_log
    test "a row appended after a torn line comes back", %{tmp_dir: dir} do
      file = Path.join(dir, "edits.jsonl")
      {e, _} = start_kept(file)
      Edits.saved("/r/a.ex", e)
      Edits.saved("/r/b.ex", e)
      _ = Edits.rows(e)
      stop_supervised!(e)
      File.write!(file, ~s|{"at":"2026-10-18T15:31:56","path":"/x/torn|, [:append])

      {e, _} = start_kept(file)
      Edits.saved("/r/c.ex", e)
      Edits.saved("/r/d.ex", e)
      _ = Edits.rows(e)
      stop_supervised!(e)

      assert {rows, 1} = Log.load(file)
      assert Enum.map(rows, & &1.path) == ~w(/r/a.ex /r/b.ex /r/c.ex /r/d.ex)
      {e, _} = start_kept(file)
      assert length(Edits.rows(e)) == 4
    end

    @tag :capture_log
    test "a file that can't be written stops the writing, not the list", %{tmp_dir: dir} do
      # Its directory would have to be a file.
      File.write!(Path.join(dir, "blocker"), "")
      {e, _} = start_kept(Path.join([dir, "blocker", "edits.jsonl"]))
      Edits.saved("/r/a.ex", e)
      Edits.saved("/r/b.ex", e)
      assert [{"/r/b.ex", :you}, {"/r/a.ex", :you}] = whos(e)
      assert :sys.get_state(e).file == nil
    end

    test "fold/1 leaves the rows as adding them one by one does" do
      :rand.seed(:exsss, {7, 7, 7})
      agent = {:agent, %{harness: "claude-code", session: "s"}}

      for _ <- 1..50 do
        loaded =
          for _ <- 1..60 do
            who = Enum.random([:you, :outside, :outside, agent])
            sha = if who == :you, do: nil, else: "h#{:rand.uniform(8)}"
            %{kept_row("/r/f#{:rand.uniform(4)}", who, sha) | tool_use: "t#{:rand.uniform(99)}"}
          end

        added =
          Enum.reduce(loaded, [], fn row, rows ->
            case Edits.add(rows, row) do
              {_how, rows, _row} -> rows
              :same -> rows
            end
          end)

        assert Edits.fold(loaded) == added
      end
    end

    test "past the bound the file rotates; loading reads both generations", %{tmp_dir: dir} do
      file = Path.join(dir, "edits.jsonl")
      # A row on disk: its line and the newline written before it.
      line = byte_size(Log.encode(kept_row("/r/f10", :you))) + 1

      # Rotate past three lines' worth: f10–f13 move to edits.1.jsonl, f14–f17 the next.
      for i <- 10..17, do: :ok = Log.append(file, kept_row("/r/f#{i}", :you), 3 * line)
      assert File.exists?(Log.previous(file))
      {rows, 0} = Log.load(file)
      assert Enum.map(rows, & &1.path) == Enum.map(14..17, &"/r/f#{&1}")
      assert {[], 0} == Log.load(Path.join(dir, "none.jsonl"))
    end

    test "two writers at once: every line lands whole", %{tmp_dir: dir} do
      file = Path.join(dir, "edits.jsonl")

      for w <- 1..2 do
        Task.async(fn ->
          for i <- 1..300,
              do: :ok = Log.append(file, kept_row("/r/w#{w}/#{i}", :outside, "h#{i}"))
        end)
      end
      |> Task.await_many(30_000)

      assert {rows, 0} = Log.load(file)
      assert length(rows) == 600
    end
  end

  test "the layout drops the edits band in a short terminal" do
    assert %{edits: nil, editor: %{h: 10}, status: 10} = Layout.resolve(80, 11, %{edits: true})
    assert %{edits: %{y: 20, h: 9}, editor: %{h: 20}} = Layout.resolve(80, 30, %{edits: true})
  end
end
