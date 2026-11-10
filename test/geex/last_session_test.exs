defmodule Geex.LastSessionTest do
  # The last session (roadmap item 18.9): what is kept, read back and rebuilt, the file, and the
  # loop and startup ends. Uses the global Session, so not async.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Geex.{LastSession, Loop, Session}
  alias Geex.Loop.Panes

  doctest Geex.LastSession

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_session_#{Geex.Fixtures.uniq()}")
    sessions = Path.join(dir, "state/sessions")
    File.mkdir_p!(Path.join(dir, "proj"))
    for f <- ["a.txt", "b.txt", "c.txt"], do: File.write!(Path.join([dir, "proj", f]), "#{f}\n")
    Application.put_env(:geex, :sessions_dir, sessions)

    on_exit(fn ->
      Application.delete_env(:geex, :sessions_dir)
      Application.put_env(:geex, :session_memory, false)

      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir, proj: Path.join(dir, "proj"), sessions: sessions}
  end

  defp open(proj, name) do
    {:ok, pid} = Session.open_file(Path.join(proj, name))
    pid
  end

  defp path_of(pid), do: Geex.Buffer.status(pid).path

  # a.txt and b.txt in pane 1 (b shown), c.txt in pane 2 on the right, current.
  defp two_panes(proj) do
    [a, b, c] = for f <- ["a.txt", "b.txt", "c.txt"], do: open(proj, f)

    panes = %{
      split: {:cols, {:pane, 1}, {:pane, 2}, 0.25},
      panes: %{
        1 => %{tabs: [Panes.tab(a), %{Panes.tab(b, {0, 2}) | scroll: 0}], at: 1},
        2 => %{tabs: [Panes.tab(c, {0, 1}), Panes.preview_tab(a, 2)], at: 0}
      },
      pane: 2,
      next: 3
    }

    {panes, [a, b, c]}
  end

  test "what is kept reads back and rebuilds the panes; previews aren't kept", %{proj: proj} do
    {panes, [a, b, c]} = two_panes(proj)
    map = LastSession.encode(panes, &path_of/1, 40, 12)
    # Through JSON, as the file holds it.
    {:ok, saved} = map |> JSON.encode!() |> JSON.decode!() |> LastSession.decode()
    assert {saved.tree_w, saved.edits_h, saved.pane} == {40, 12, 2}

    assert LastSession.paths(saved) ==
             Enum.map(["a.txt", "b.txt", "c.txt"], &Path.join(proj, &1))

    pids = Map.new([a, b, c], &{path_of(&1), &1})
    rebuilt = LastSession.panes(saved, pids)
    assert rebuilt.split == panes.split
    assert rebuilt.pane == 2
    assert [%{buffer: ^a}, %{buffer: ^b, cursor: {0, 2}}] = rebuilt.panes[1].tabs
    assert rebuilt.panes[1].at == 1
    assert [%{buffer: ^c, cursor: {0, 1}}] = rebuilt.panes[2].tabs
  end

  test "a scratch buffer isn't kept, and the shown tab is counted among those kept", %{
    proj: proj
  } do
    a = open(proj, "a.txt")
    {:ok, scratch} = Geex.BufferSupervisor.start_scratch()

    panes = %{
      split: {:pane, 1},
      panes: %{1 => %{tabs: [Panes.tab(scratch), Panes.tab(a)], at: 1}},
      pane: 1,
      next: 2
    }

    assert %{"panes" => %{"1" => %{"at" => 0, "tabs" => [%{"path" => path}]}}} =
             LastSession.encode(panes, &path_of/1, nil, nil)

    assert path == Path.join(proj, "a.txt")
  end

  test "written whole and private; read back; a broken file is no session", %{
    proj: proj,
    sessions: sessions
  } do
    {panes, _} = two_panes(proj)
    map = LastSession.encode(panes, &path_of/1, 40, nil)
    assert LastSession.write(proj, map) == :ok

    file = LastSession.file(proj)
    assert Path.dirname(file) == sessions
    assert Path.basename(file) =~ ~r/^[0-9a-f]{16}\.json$/
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(sessions).mode |> Bitwise.band(0o777) == 0o700
    assert {:ok, %{tree_w: 40, pane: 2}} = LastSession.read(proj)

    File.write!(file, ~s({"v": 1, "split": {"pane": 9}, "pane": 1, "panes": {}}))
    assert LastSession.read(proj) == :none
    File.write!(file, "not json")
    assert LastSession.read(proj) == :none
  end

  test "sizes only (geex FILE) keeps the project's files, or starts with the sizes alone", %{
    proj: proj
  } do
    {panes, _} = two_panes(proj)
    :ok = LastSession.write(proj, LastSession.encode(panes, &path_of/1, 40, 12))

    one = %{split: {:pane, 1}, panes: %{1 => %{tabs: [], at: 0}}, pane: 1, next: 2}
    :ok = LastSession.write(proj, LastSession.encode(one, &path_of/1, 50, nil), sizes_only: true)
    assert {:ok, saved} = LastSession.read(proj)
    assert {saved.tree_w, saved.edits_h, map_size(saved.panes)} == {50, nil, 2}

    File.rm!(LastSession.file(proj))
    :ok = LastSession.write(proj, LastSession.encode(one, &path_of/1, 33, 7), sizes_only: true)
    assert {:ok, %{tree_w: 33, edits_h: 7, split: {:pane, 1}}} = LastSession.read(proj)
  end

  describe "the loop" do
    test "a restore shows the panes, makes the current tab active, and takes the sizes", %{
      proj: proj
    } do
      Session.set_start(proj)
      {panes, [_a, _b, c]} = two_panes(proj)
      panes = put_in(panes.panes[2].tabs, [Panes.tab(c, {0, 1})])
      state = Loop.new_state(120, 30)

      {:noreply, state} =
        Loop.handle_info(
          {:geex_restore, %{mode: :project, panes: panes, tree_w: 40, edits_h: 6}},
          state
        )

      assert state.panes.split == panes.split
      assert {state.tree_w, state.edits_h, state.session} == {40, 6, :project}
      assert Session.active_buffer() == {:ok, c}
      assert elem(Session.snapshot(), 1).cursor == {0, 1}
    end

    test "the tick keeps the session when it changed, and only then", %{proj: proj} do
      Session.set_start(proj)
      {panes, _} = two_panes(proj)
      panes = update_in(panes.panes[2].tabs, &Enum.take(&1, 1))
      state = Loop.new_state(120, 30)

      {:noreply, state} =
        Loop.handle_info({:geex_restore, %{mode: :project, panes: panes}}, state)

      {:noreply, state} = Loop.handle_info(:geex_session_tick, state)
      assert_receive {:geex_session_written, _map, :ok} = written, 1_000
      file = LastSession.file(Session.start().root)

      assert {:ok, %{pane: 2, split: {:cols, _, _, 0.25}}} =
               LastSession.read(Session.start().root)

      {:noreply, state} = Loop.handle_info(written, state)

      File.rm!(file)
      {:noreply, _state} = Loop.handle_info(:geex_session_tick, state)
      refute_receive {:geex_session_written, _, _}, 100
      refute File.exists?(file)
    end

    # The review's item 4: a failed write was counted as kept, so it was never tried again.
    test "a failed write is tried again on the next tick", %{proj: proj, dir: dir} do
      Session.set_start(proj)
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "a file where the sessions directory should be")
      Application.put_env(:geex, :sessions_dir, Path.join(blocker, "sessions"))
      {panes, _} = two_panes(proj)
      state = Loop.new_state(120, 30)

      {:noreply, state} =
        Loop.handle_info({:geex_restore, %{mode: :project, panes: panes}}, state)

      {:noreply, state} = Loop.handle_info(:geex_session_tick, state)
      assert_receive {:geex_session_written, _map, {:error, _}} = failed, 1_000
      {:noreply, state} = Loop.handle_info(failed, state)
      assert {state.session_kept, state.session_pending} == {nil, nil}

      Application.put_env(:geex, :sessions_dir, Path.join(dir, "state/sessions"))
      {:noreply, _state} = Loop.handle_info(:geex_session_tick, state)
      assert_receive {:geex_session_written, _map, :ok}, 1_000
      assert {:ok, _} = LastSession.read(Session.start().root)
    end

    test "a geex FILE session writes only when the sizes change", %{proj: proj} do
      Session.set_start(proj)
      state = Loop.new_state(120, 30)
      {:noreply, state} = Loop.handle_info({:geex_restore, %{mode: :sizes, tree_w: 30}}, state)
      {:noreply, state} = Loop.handle_info(:geex_session_tick, state)
      assert_receive {:geex_session_written, _, :ok} = written, 1_000
      {:noreply, state} = Loop.handle_info(written, state)

      a = open(proj, "a.txt")
      state = %{state | panes: elem(Panes.show(state.panes, a), 0)}
      {:noreply, state} = Loop.handle_info(:geex_session_tick, state)
      refute_receive {:geex_session_written, _, _}, 100

      {:noreply, _} = Loop.handle_info(:geex_session_tick, %{state | tree_w: 40})
      assert_receive {:geex_session_written, _, :ok}, 1_000
      assert {:ok, %{tree_w: 40}} = LastSession.read(proj)
    end

    test "with no session mode, nothing is kept", %{proj: proj} do
      Session.set_start(proj)
      {:noreply, _} = Loop.handle_info(:geex_session_tick, Loop.new_state(120, 30))
      Process.sleep(50)
      refute File.exists?(LastSession.file(Session.start().root))
    end
  end

  describe "the writer" do
    test "a quit's write waits, and lands after any sent before it", %{proj: proj} do
      writer = LastSession.writer(self())
      one = %{split: {:pane, 1}, panes: %{1 => %{tabs: [], at: 0}}, pane: 1, next: 2}
      old = LastSession.encode(one, &path_of/1, 10, nil)
      new = LastSession.encode(one, &path_of/1, 20, nil)

      :ok = LastSession.keep(writer, proj, old, [])
      assert LastSession.keep_now(writer, proj, new, [], 1_000) == :ok
      assert {:ok, %{tree_w: 20}} = LastSession.read(proj)
    end

    test "a write that raises is reported, and the writer goes on", %{proj: proj} do
      writer = LastSession.writer(self())
      bad = %{"v" => 1, "panes" => %{"1" => %{"tabs" => [%{"path" => <<255>>}]}}}
      assert {:error, _} = LastSession.keep_now(writer, proj, bad, [], 1_000)
      assert Process.alive?(writer)
      refute Path.wildcard(LastSession.file(proj) <> ".*.tmp") != []
    end
  end

  # The review's item 5: a sizes-only write replaced a session it couldn't read.
  test "a sizes-only write leaves a session it can't read alone", %{proj: proj} do
    file = LastSession.file(proj)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, ~s({"v": 2, "something": "newer"}))
    one = %{split: {:pane, 1}, panes: %{1 => %{tabs: [], at: 0}}, pane: 1, next: 2}

    assert LastSession.write(proj, LastSession.encode(one, &path_of/1, 50, nil), sizes_only: true) ==
             {:error, :unreadable}

    assert File.read!(file) == ~s({"v": 2, "something": "newer"})
  end

  test "a relative path in the file is no session" do
    map = %{
      "v" => 1,
      "split" => %{"pane" => 1},
      "pane" => 1,
      "panes" => %{
        "1" => %{"at" => 0, "tabs" => [%{"path" => "a.txt", "cursor" => [0, 0], "scroll" => 0}]}
      }
    }

    assert LastSession.decode(map) == :error
  end

  # ADR-0044: what is kept reads back as it was, and rebuilds the same panes.
  property "encode, JSON and decode give back the panes" do
    pids = for _ <- 1..4, do: spawn(fn -> :ok end)
    paths = for n <- 1..4, do: "/p/f#{n}.txt"
    path_of = Map.new(Enum.zip(pids, paths))

    check all(
            n <- integer(1..4),
            split <- split_of(Enum.to_list(1..n)),
            panes <- panes_of(n, pids),
            pane <- integer(1..n),
            tree_w <- one_of([constant(nil), integer(1..200)]),
            edits_h <- one_of([constant(nil), integer(1..80)])
          ) do
      ps = %{split: split, panes: panes, pane: pane, next: n + 1}

      {:ok, saved} =
        ps
        |> LastSession.encode(&path_of[&1], tree_w, edits_h)
        |> JSON.encode!()
        |> JSON.decode!()
        |> LastSession.decode()

      assert {saved.tree_w, saved.edits_h} == {tree_w, edits_h}
      assert LastSession.panes(saved, Map.new(Enum.zip(paths, pids))) == ps
    end
  end

  defp split_of([id]), do: constant({:pane, id})

  defp split_of(ids) do
    bind(integer(1..(length(ids) - 1)), fn k ->
      {a, b} = Enum.split(ids, k)

      tuple(
        {member_of([:rows, :cols]), split_of(a), split_of(b), map(integer(1..99), &(&1 / 100))}
      )
    end)
  end

  defp panes_of(n, pids) do
    tab =
      bind(tuple({member_of(pids), integer(0..50), integer(0..50), integer(0..50)}), fn {pid, l,
                                                                                         c, sc} ->
        constant(%{Panes.tab(pid, {l, c}) | scroll: sc})
      end)

    # One tab per buffer in a pane, as `Panes.show/3` keeps them.
    pane =
      list_of(tab, min_length: 1, max_length: 4)
      |> map(&Enum.uniq_by(&1, fn t -> t.buffer end))
      |> bind(fn tabs -> map(integer(0..(length(tabs) - 1)), &%{tabs: tabs, at: &1}) end)

    map(fixed_list(List.duplicate(pane, n)), fn panes ->
      panes |> Enum.with_index(1) |> Map.new(fn {p, id} -> {id, p} end)
    end)
  end

  describe "starting" do
    test "geex DIR reopens the project's last session's files", %{proj: proj} do
      Application.put_env(:geex, :session_memory, true)
      {panes, _} = two_panes(proj)
      :ok = LastSession.write(proj, LastSession.encode(panes, &path_of/1, 40, nil))

      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      File.rm!(Path.join(proj, "b.txt"))
      Geex.open_paths(proj)

      open = Session.buffers() |> Enum.map(& &1.path) |> Enum.sort()
      assert open == Enum.map(["a.txt", "c.txt"], &Path.join(proj, &1))
      assert Session.start().dir == Path.expand(proj)
    end

    test "geex FILE opens just that file", %{proj: proj} do
      Application.put_env(:geex, :session_memory, true)
      {panes, _} = two_panes(proj)
      :ok = LastSession.write(proj, LastSession.encode(panes, &path_of/1, 40, nil))

      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Geex.open_paths([Path.join(proj, "b.txt")])
      assert Enum.map(Session.buffers(), & &1.path) == [Path.join(proj, "b.txt")]
    end
  end

  defp wait_for(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_for(fun, tries - 1)
    end
  end
end
