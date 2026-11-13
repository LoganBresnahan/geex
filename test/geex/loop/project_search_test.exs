defmodule Geex.Loop.ProjectSearchTest do
  # ADR-0053 slice C through the loop's own handle_info/2 against real repositories: Alt+Shift+Q
  # runs `search project` (or `search all`, by the General setting) into the output pane; Alt+N
  # opens each result, selecting its match. Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Loop, Selection, Session}
  alias Geex.Loop.Output

  setup do
    root = Path.join(System.tmp_dir!(), "geex_project_search_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(root)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  # A git repository at `root`: `files` committed, `untracked` left untracked, `.gitignore`
  # ignoring `_build/` and `*.log`.
  defp repo(root, files, untracked \\ %{}) do
    git = fn args -> {_, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true) end
    git.(["init", "-q"])
    write(root, Map.put(files, ".gitignore", "*.log\n"))
    git.(["add", "-A"])
    git.(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])
    write(root, untracked)
    Session.set_start(root)
  end

  defp write(root, files) do
    for {path, text} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, text)
    end
  end

  defp editing(root, path) do
    {:ok, pid} = Session.open_file(Path.join(root, path))
    state = %{Loop.new_state(120, 30) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    state
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp type(state, text), do: Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))

  # Run a search for `query` with Alt+Shift+Q and deliver the runner's messages until it ends.
  defp search(state, query),
    do: state |> key({:alt, ?Q}) |> type(query) |> key({:key, :enter}) |> ran()

  defp ran(%{shell: nil} = state), do: state

  defp ran(%{shell: %{pid: pid}} = state) do
    assert_receive {:geex_shell, ^pid, _} = msg, 10_000
    {:noreply, state} = Loop.handle_info(msg, state)
    ran(state)
  end

  defp results(state),
    do: for(i <- 0..(Output.size(state.output) - 1)//1, do: Output.line(state.output, i))

  defp cursor, do: elem(Session.snapshot(), 1).cursor
  defp shown_path, do: elem(Session.snapshot(), 1).path
  defp sel(%{selection: %Selection{anchor: a, active: b}}), do: {a, b}
  defp sel(_state), do: nil

  describe "search project in git" do
    test "tracked and untracked files, spaces and é in paths, the common dirs left out", %{
      root: root
    } do
      repo(
        root,
        %{
          "lib/a.ex" => "x = 1 # needle\n",
          "sub dir/café notes.txt" => "a needle here\n",
          "_build/out.txt" => "needle in build\n",
          "lib/deps/d.txt" => "needle in deps\n"
        },
        %{"new.txt" => "untracked needle\n", "x.log" => "ignored needle\n"}
      )

      state = editing(root, "lib/a.ex") |> search("needle")
      lines = results(state)
      assert Enum.any?(lines, &(&1 =~ "lib/a.ex:1:"))
      assert Enum.any?(lines, &(&1 =~ "sub dir/café notes.txt:1:"))
      assert Enum.any?(lines, &(&1 =~ "new.txt:1:"))
      refute Enum.any?(lines, &(&1 =~ ~r/_build|deps|x\.log/))
      assert state.focus == :output
      assert Output.title(state.output, 0) =~ ~r/search project “needle” · 3 lines/
      assert state.recall.search.entries == ["needle"]
    end

    test "search all finds the ignored and the excluded too", %{root: root} do
      repo(root, %{"a.txt" => "needle\n", "_build/b.txt" => "needle\n"}, %{"x.log" => "needle\n"})
      state = editing(root, "a.txt")
      state = put_in(state.keys[{:alt, ?Q}], :search_all) |> search("needle")
      lines = results(state)
      assert Enum.any?(lines, &(&1 =~ "_build/b.txt:1:"))
      assert Enum.any?(lines, &(&1 =~ "x.log:1:"))
      assert Output.title(state.output, 0) =~ "search all"
    end

    test "the query quoted: ' $ ` and \\ are searched for as typed", %{root: root} do
      repo(root, %{"q.txt" => ~S|it's $HOME `id` a\b| <> "\n", "other.txt" => "nothing\n"})
      state = editing(root, "q.txt")

      for q <- [~S|it's|, ~S|$HOME|, ~S|`id`|, ~S|a\b|] do
        state = search(state, q)
        assert [line] = results(state), q
        assert line =~ "q.txt:1:", q
      end
    end

    test "no matches says so, not a failure", %{root: root} do
      repo(root, %{"a.txt" => "hay\n"})
      state = editing(root, "a.txt") |> search("needle")
      assert state.notice == "no matches"
      assert Output.title(state.output, 0) =~ "no matches"
    end

    test "smart case: lower case finds any case, a capital only itself", %{root: root} do
      repo(root, %{"a.txt" => "Needle\nneedle\n"})
      state = editing(root, "a.txt")
      assert length(results(search(state, "needle"))) == 2
      assert length(results(search(state, "Needle"))) == 1
    end

    test "past 5,000 result lines, the first 5,000 kept, and it says so", %{root: root} do
      repo(root, %{"big.txt" => Enum.map_join(1..6000, &"needle #{&1}\n")})
      state = editing(root, "big.txt") |> search("needle")
      lines = results(state)
      assert length(lines) == 5000
      assert hd(lines) =~ "big.txt:1:needle 1"
      assert List.last(lines) =~ "big.txt:5000:needle 5000"
      assert state.notice =~ "the first 5000 lines"
      assert Output.title(state.output, 0) =~ "the first 5000 lines"
    end
  end

  describe "mod-verify's review of slice C" do
    test "a Latin-1 query from a selection finds its line in git (no -i on it)", %{root: root} do
      repo(root, %{"l.txt" => "le caf" <> <<0xE9>> <> " noir\n", "u.txt" => "un café\n"})
      state = editing(root, "l.txt")
      state = state |> key({:alt, ?l}) |> key({:alt, ?l}) |> key({:alt, ?l}) |> key({:alt, ?s})
      state = state |> key({:alt, ?l}) |> key({:alt, ?l}) |> key({:alt, ?l}) |> key({:alt, ?l})
      state = key(state, {:alt, ?Q})
      assert Geex.Minibuffer.value(state.minibuffer) == "caf" <> <<0xE9>>
      state = state |> key({:key, :enter}) |> ran()
      assert [line] = results(state)
      assert line =~ "l.txt:1:"
    end

    test "a Latin-1 file outside git is searched (grep in the C locale)", %{root: root} do
      write(root, %{"l.txt" => "le caf" <> <<0xE9>> <> " noir needle\n"})
      Session.set_start(root)
      state = editing(root, "l.txt") |> search("needle")
      assert [line] = results(state)
      assert line =~ "l.txt:1:"
    end

    test "a query starting with - is searched for as typed", %{root: root} do
      repo(root, %{"a.txt" => "use -n here\n", "b.txt" => "plain\n"})
      state = editing(root, "a.txt") |> search("-n")
      assert [line] = results(state)
      assert line =~ "a.txt:1:"
    end

    test "Alt+N after the highlight was moved starts from it", %{root: root} do
      repo(root, %{"a.txt" => "needle\n", "b.txt" => "needle\n", "c.txt" => "needle\n"})
      state = editing(root, "a.txt") |> search("needle")
      assert length(results(state)) == 3
      # The highlight moved up from the last result (where it followed the output) to the second.
      state = %{state | output: Output.move(state.output, -1)}
      state = key(state, {:alt, ?n})
      assert Path.basename(shown_path()) == "b.txt"
    end

    test "one result says 1 line", %{root: root} do
      repo(root, %{"a.txt" => "needle\n"})
      state = editing(root, "a.txt") |> search("needle")
      assert Output.title(state.output, 0) =~ "· 1 line ·"
    end

    test "refused through a symlink to home, and above home", %{root: root} do
      home = Path.join(root, "home/me")
      write(home, %{"a.txt" => "needle\n"})
      File.ln_s!(home, Path.join(root, "link"))
      old = System.get_env("HOME")
      System.put_env("HOME", home)

      try do
        for start <- [Path.join(root, "link"), Path.join(root, "home")] do
          Session.set_start(start)
          state = editing(home, "a.txt") |> key({:alt, ?Q}) |> type("needle")
          state = key(state, {:key, :enter})
          assert state.shell == nil, start
          assert state.notice =~ ~r/home directory|above your home/, start
        end
      after
        System.put_env("HOME", old)
      end
    end

    test "home kept in git: searched, its tracked files only, saying so", %{root: root} do
      repo(root, %{"tracked.txt" => "needle\n"}, %{"untracked.txt" => "needle\n"})
      old = System.get_env("HOME")
      System.put_env("HOME", root)

      try do
        state = editing(root, "tracked.txt") |> key({:alt, ?Q}) |> type("needle")
        state = key(state, {:key, :enter})
        assert state.notice =~ "tracked files only"
        state = ran(state)
        assert [line] = results(state)
        assert line =~ "tracked.txt:1:"
      after
        System.put_env("HOME", old)
      end
    end
  end

  describe "Alt+N through the results (§7)" do
    test "one stop per line, the match selected, wrapping; Enter on a line opens it too", %{
      root: root
    } do
      repo(root, %{"a.txt" => "one Needle two needle\n", "sub dir/b é.txt" => "x\nthe needle\n"})
      state = editing(root, "a.txt") |> search("needle")
      assert length(results(state)) == 2

      state = key(state, {:alt, ?n})
      assert state.focus == :editor
      assert Path.basename(shown_path()) == "a.txt"
      assert sel(state) == {{0, 4}, {0, 10}}

      state = key(state, {:alt, ?n})
      assert Path.basename(shown_path()) == "b é.txt"
      assert sel(state) == {{1, 4}, {1, 10}}

      state = key(state, {:alt, ?n})
      assert Path.basename(shown_path()) == "a.txt"
      assert state.notice == "wrapped to the first result"

      # Enter on the second result line in the output pane.
      state = %{state | focus: :output, output: Output.move(state.output, 1)}
      state = key(state, {:key, :enter})
      assert Path.basename(shown_path()) == "b é.txt"
      assert cursor() == {1, 10}
    end

    test "a result line whose match isn't there (an unsaved edit): the line's start", %{
      root: root
    } do
      repo(root, %{"a.txt" => "needle\nhay\n"})
      state = editing(root, "a.txt") |> search("needle")
      # An unsaved edit takes the needle off line 1.
      state = %{state | focus: :editor} |> key({:alt, ?a}) |> type("hay")
      state = key(state, {:alt, ?n})
      assert cursor() == {0, 0}
      assert sel(state) == nil
      assert state.notice =~ "isn't on line 1"
    end

    test "a `!` replacing the results: Alt+N is the file's search again (Q14)", %{root: root} do
      repo(root, %{"a.txt" => "zz needle zz\n"})
      state = editing(root, "a.txt")
      # A file search for "zz" kept, then a project search, then a `!` in the output pane.
      state = state |> key({:alt, ?q}) |> type("zz") |> key({:key, :enter})
      state = search(state, "needle")

      state =
        %{state | focus: :editor} |> key({:alt, ?m}) |> type("!echo hi") |> key({:key, :enter})

      state = ran(state)
      Session.set_cursor({0, 0})
      # From the cursor, inclusive (R4): the "zz" at the line's start.
      state = key(%{state | focus: :editor, selection: nil}, {:alt, ?n})
      assert state.search.last == :file
      assert sel(state) == {{0, 0}, {0, 2}}
    end
  end

  describe "outside git" do
    test "grep -r, the common dirs left out", %{root: root} do
      write(root, %{"a.txt" => "needle\n", "node_modules/m.js" => "needle\n"})
      Session.set_start(root)
      state = editing(root, "a.txt") |> search("needle")
      assert [line] = results(state)
      assert line =~ "a.txt:1:"
    end

    test "refused from the home directory", %{root: root} do
      write(root, %{"a.txt" => "needle\n"})
      Session.set_start(root)
      home = System.get_env("HOME")
      System.put_env("HOME", root)

      try do
        state = editing(root, "a.txt") |> key({:alt, ?Q}) |> type("needle") |> key({:key, :enter})
        assert state.shell == nil
        assert state.notice =~ "home directory"
      after
        System.put_env("HOME", home)
      end
    end
  end

  test "the General setting switches what Alt+Shift+Q runs, and the help shows it", %{root: root} do
    repo(root, %{"a.txt" => "x\n"})
    state = editing(root, "a.txt")
    assert Loop.Bindings.translate({:alt, ?Q}, state.keys) == {:cmd, :search_project}
    state = Loop.apply_settings(state, %{"search_key" => "search all"})
    assert Loop.Bindings.translate({:alt, ?Q}, state.keys) == {:cmd, :search_all}
    state = key(state, {:alt, ?Q})
    assert state.minibuffer.mode == :search_all
  end
end
