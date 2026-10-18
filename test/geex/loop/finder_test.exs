defmodule Geex.Loop.FinderTest do
  # Alt+O, the file finder (ADR-0028's 2026-10-17 amendment), through the loop's own
  # handle_info/2 with no terminal: the files are read and searched in processes of their own,
  # and their answers are delivered here as the loop would get them. Sets the global Session's
  # start, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Loop, Minibuffer, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_finder_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(Path.join(dir, "lib/loop"))

    for f <- ["lib/a.ex", "lib/loop.ex", "lib/loop/keymap.ex", "README.md"],
        do: File.write!(Path.join(dir, f), f <> "\n")

    Session.set_start(dir)
    {:ok, buf} = Session.open_file(Path.join(dir, "lib/a.ex"))

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      _ = buf
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp type(state, text), do: Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))

  # Deliver the next answer of `kind` (`:geex_tree` or `:geex_matches`) to the loop.
  defp deliver(state, kind) do
    assert_receive {^kind, _pid, _answer} = answer, 5_000
    {:noreply, state} = Loop.handle_info(answer, state)
    state
  end

  defp finder(width \\ 60), do: key(Loop.new_state(width, 30), {:alt, ?o})

  test "Alt+O reads the files in the background; a blank query lists them in order" do
    state = finder()
    assert %Minibuffer{mode: :files} = state.minibuffer
    assert {_pid, _ref} = state.tree.reading
    assert state.finder.matches == []

    state = deliver(state, :geex_tree)
    assert state.finder.matches == ["README.md", "lib/a.ex", "lib/loop.ex", "lib/loop/keymap.ex"]
  end

  test "typing searches in a process of its own; Enter opens the highlighted file", %{dir: dir} do
    state = finder() |> deliver(:geex_tree) |> type("loop")
    assert {pid, _ref} = state.finder.matching
    assert is_pid(pid)

    state = deliver(state, :geex_matches)
    assert state.finder.matching == nil
    assert state.finder.matches == ["lib/loop.ex", "lib/loop/keymap.ex"]

    state = state |> key({:alt, ?s}) |> key({:key, :enter})
    assert state.minibuffer.mode == :inactive
    assert state.focus == :editor
    assert {:ok, %{path: path}} = Session.snapshot()
    assert path == Path.join(dir, "lib/loop/keymap.ex")
  end

  test "Enter before the search answers opens the top match when it does", %{dir: dir} do
    state = finder() |> deliver(:geex_tree) |> type("loop") |> key({:key, :enter})
    assert state.finder.submit
    assert state.minibuffer.mode == :files

    state = deliver(state, :geex_matches)
    assert state.minibuffer.mode == :inactive
    assert {:ok, %{path: path}} = Session.snapshot()
    assert path == Path.join(dir, "lib/loop.ex")
  end

  test "Enter before the files are read opens the first file once they are", %{dir: dir} do
    state = finder() |> key({:key, :enter})
    assert state.finder.submit

    state = deliver(state, :geex_tree)
    assert state.minibuffer.mode == :inactive
    assert {:ok, %{path: path}} = Session.snapshot()
    assert path == Path.join(dir, "README.md")
  end

  test "a new key drops the old search; its late answer changes nothing" do
    state = finder() |> deliver(:geex_tree) |> type("l")
    {old, _ref} = state.finder.matching
    state = type(state, "o")
    {new, _ref} = state.finder.matching

    assert new != old
    refute Process.alive?(old)
    assert Loop.handle_info({:geex_matches, old, ["stale"]}, state) == {:noreply, state}
  end

  test "Esc closes the finder and stops its search" do
    state = finder() |> deliver(:geex_tree) |> type("loop")
    {pid, _ref} = state.finder.matching
    state = key(state, {:key, :esc})

    assert state.minibuffer.mode == :inactive
    assert state.finder == %{matches: [], matching: nil, submit: false}
    refute Process.alive?(pid)
  end

  test "no match: the finder closes and says so" do
    state = finder() |> deliver(:geex_tree) |> type("zzz") |> deliver(:geex_matches)
    assert state.finder.matches == []
    state = key(state, {:key, :enter})
    assert state.minibuffer.mode == :inactive
    assert state.notice == "no file matches “zzz”"
  end

  @tag :capture_log
  test "a search that dies says so and stops waiting" do
    state = finder() |> deliver(:geex_tree)
    {pid, ref} = spawn_monitor(fn -> exit(:boom) end)
    state = put_in(state.finder.matching, {pid, ref})
    assert_receive {:DOWN, ^ref, :process, ^pid, :boom} = down

    {:noreply, state} = Loop.handle_info(down, state)
    assert state.finder.matching == nil
    assert state.notice =~ "the file search failed"
  end

  test "`open` alone and `find`, typed, open the finder too" do
    for verb <- ["open", "find"] do
      state = Loop.new_state(60, 30) |> key({:alt, ?m}) |> type(verb) |> key({:key, :enter})
      assert %Minibuffer{mode: :files} = state.minibuffer
    end
  end
end
