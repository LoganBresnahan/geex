defmodule Geex.Loop.ClickableOutputTest do
  # ADR-0042's 2026-11-23 amendment: the output pane's locations, resolved off the loop as the
  # lines arrive (`Geex.Loop.Resolver`), drawn as links, opened by a click, stepped by Alt+N; and
  # BUG-26 (a project search's Alt+N stepped by a look at the disk per line, in the loop). Through
  # the loop's own handle_info/2 with real `sh` commands; the runner's and the resolver's answers
  # are delivered by hand. Uses the global Session and Renderer, so not async.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Geex.{Loop, Renderer, Session}
  alias Geex.Loop.{Output, Resolver}

  doctest Geex.Loop.Resolver

  setup do
    root = Path.join(System.tmp_dir!(), "geex_clickable_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "one\ntwo\nthree\nfour\n")
    File.write!(Path.join(root, "lib/b.ex"), "uno\ndos\ntres\n")
    File.write!(Path.join(root, "notes.txt"), "find me\nand find me\n")
    Session.set_start(root)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  ## Helpers

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp type(state, text), do: Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))

  defp typed(state, line), do: state |> key({:alt, ?m}) |> type(line) |> key({:key, :enter})

  defp click(state, x, y),
    do:
      key(%{state | click: nil}, {:mouse, %{action: :press, button: :left, x: x, y: y, mods: []}})

  defp repaint(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    state
  end

  defp editing(root, path, state \\ nil) do
    state = state || %{Loop.new_state(120, 30) | tree_shown: false, edits_shown: false}
    {:ok, pid} = Session.open_file(Path.join(root, path))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    state
  end

  # Deliver the runner's messages until the command has ended, then the resolver's answers.
  defp ran(%{shell: nil} = state), do: linked(state)

  defp ran(%{shell: %{pid: pid}} = state) do
    assert_receive {:geex_shell, ^pid, _} = msg, 10_000
    {:noreply, state} = Loop.handle_info(msg, state)
    ran(state)
  end

  defp linked(%{resolver: %{pid: pid}, output: %Output{} = out} = state) do
    if Output.pending?(out) do
      assert_receive {:geex_links, ^pid, _, _} = msg, 10_000
      {:noreply, state} = Loop.handle_info(msg, state)
      linked(state)
    else
      state
    end
  end

  defp linked(state), do: state

  # The runner's messages only: the resolver's answers left in the mailbox.
  defp ran_only(%{shell: nil} = state), do: state

  defp ran_only(%{shell: %{pid: pid}} = state) do
    assert_receive {:geex_shell, ^pid, _} = msg, 10_000
    {:noreply, state} = Loop.handle_info(msg, state)
    ran_only(state)
  end

  defp screen_text(screen, y),
    do: Enum.map_join(0..119, &Geex.Screen.get_cell(screen, &1, y).char)

  # Where `needle` is drawn: `{x, y}` of its first cell, on the lowest row that has it (the
  # output pane's title repeats the command above its lines).
  defp drawn_at(screen, needle) do
    y = Enum.find(29..0//-1, &String.contains?(screen_text(screen, &1), needle))
    assert y, "#{inspect(needle)} isn't on the screen"
    {at, _} = :binary.match(screen_text(screen, y), needle)
    {String.length(binary_part(screen_text(screen, y), 0, at)), y}
  end

  defp cursor, do: elem(Session.snapshot(), 1).cursor
  defp shown, do: Path.basename(elem(Session.snapshot(), 1).path)

  ## The pure parts

  describe "Output's links" do
    # Lines fed through take_unsent/put_links as the loop feeds them, in batches, answered in any
    # interleaving with more lines arriving and old ones trimmed: every kept line answered has a
    # link exactly when the resolver would find one, and draining answers every line.
    property "a line has a link exactly when its answer names a file, through trims" do
      check all(
              ops <-
                list_of(
                  one_of([
                    tuple({constant(:add), list_of(member_of(["f", "-"]), max_length: 6)}),
                    constant(:answer)
                  ]),
                  max_length: 30
                ),
              max <- integer(3..12)
            ) do
        answer = fn line -> if(line == "f", do: link()) end

        {out, batch} =
          Enum.reduce(ops, {Output.new("x", :show, 0, max: max), nil}, fn
            {:add, lines}, {out, batch} ->
              out = Output.add(out, lines, "")
              take(out, batch)

            :answer, {out, nil} ->
              {out, nil}

            :answer, {out, {first, lines}} ->
              take(Output.put_links(out, first, Enum.map(lines, answer)), nil)
          end)

        out = drain(out, batch, answer)
        refute Output.pending?(out)

        for i <- 0..(out.count - 1)//1 do
          assert Output.answered?(out, i)
          assert Output.link(out, i) != nil == (Output.line(out, i) == "f")
        end
      end
    end

    property "next_link stops at the next line with a link, wrapping, and nowhere between" do
      check all(
              marks <- list_of(boolean(), min_length: 1, max_length: 20),
              at <- one_of([constant(nil), integer(0..19)]),
              sel <- integer(0..19)
            ) do
        lines = Enum.map(marks, &if(&1, do: "f", else: "-"))
        n = length(lines)
        out = Output.new("x", :show, 0) |> Output.add(lines, "")
        {out, 0, _} = Output.take_unsent(out)
        out = Output.put_links(out, 0, Enum.map(marks, &if(&1, do: link())))
        out = Output.move(out, min(sel, n - 1) - out.sel)
        at = at && min(at, n - 1)
        from = at || if(out.follow, do: -1, else: out.sel - 1)

        case Output.next_link(out, at) do
          nil ->
            refute Enum.any?(marks)

          {i, wrapped?} ->
            assert Enum.at(marks, i)
            assert wrapped? == i <= from
            between = for k <- 1..n, j = Integer.mod(from + k, n), j != i, do: j
            between = Enum.take_while(between, &(&1 != i))
            skipped = Enum.take(between, Integer.mod(i - from, n) - 1)
            refute Enum.any?(skipped, &Enum.at(marks, &1))
        end
      end
    end

    test "a trim drops the links of the lines it drops, and the line Alt+N last opened" do
      out = Output.new("x", :show, 0, max: 4) |> Output.add(["f", "-"], "")
      {out, 0, _} = Output.take_unsent(out)
      out = %{Output.put_links(out, 0, [link(), nil]) | at: 0}
      out = Output.add(out, ~w(- - - -), "")
      assert out.dropped == 2 and out.at == nil
      refute Output.links?(out)
      # The batch answered after its lines went is dropped too.
      {out, 2, ["-", "-", "-", "-"]} = Output.take_unsent(out)
      out = Output.put_links(out, 0, [link()])
      refute Output.links?(out)
    end

    defp link, do: %{at: 0, len: 1, full: "/r/f", path: "f", line: 1, col: nil}

    defp take(out, nil) do
      case Output.take_unsent(out) do
        {out, _first, []} -> {out, nil}
        {out, first, lines} -> {out, {first, lines}}
      end
    end

    defp take(out, batch), do: {out, batch}

    defp drain(out, nil, answer) do
      case take(out, nil) do
        {out, nil} -> out
        {out, batch} -> drain(out, batch, answer)
      end
    end

    defp drain(out, {first, lines}, answer),
      do: drain(Output.put_links(out, first, Enum.map(lines, answer)), nil, answer)
  end

  describe "the resolver" do
    test "answers in order, asking about each path once", %{root: root} do
      me = self()
      file? = fn full -> send(me, {:asked, full}) && Geex.Disk.regular?(full) end
      {pid, ref} = Resolver.start(:show, root, regular?: file?)

      lines = [
        "lib/a.ex:2: x",
        "at 10:16:05",
        "lib/a.ex:3:1: y",
        "nope.ex:1",
        "lib/b.ex(2,1): error"
      ]

      Resolver.resolve(pid, 7, lines)
      assert_receive {:geex_links, ^pid, 7, answers}, 5_000

      assert [
               %{path: "lib/a.ex", line: 2, col: nil},
               nil,
               %{path: "lib/a.ex", line: 3, col: 1},
               nil,
               %{path: "lib/b.ex", line: 2, col: 1, at: 0, len: 13}
             ] = answers

      asked = for _ <- 1..10, full <- receive_asked(), do: full
      assert Enum.frequencies(asked)[Path.join(root, "lib/a.ex")] == 1
      Resolver.stop(pid, ref)
    end

    test "it ends with its owner, and stop/2 ends one held by a disk that never answers",
         %{root: root} do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {pid, _ref} = Resolver.start(:show, root, owner: owner)
      ref = Process.monitor(pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      stalled = fn _ -> Process.sleep(:infinity) end
      {pid, ref} = Resolver.start(:show, root, regular?: stalled)
      Resolver.resolve(pid, 0, ["lib/a.ex:1"])
      watch = Process.monitor(pid)
      Resolver.stop(pid, ref)
      assert_receive {:DOWN, ^watch, :process, ^pid, :killed}, 5_000
    end

    defp receive_asked do
      receive do
        {:asked, full} -> [full]
      after
        0 -> []
      end
    end
  end

  ## In the loop

  describe "links in the output pane" do
    test "only the lines naming a file under the root are links, underlined in the accent",
         %{root: root} do
      state = editing(root, "notes.txt")

      state =
        typed(
          state,
          "!echo 'lib/a.ex:3:2: warning'; echo 'at 10:16:05'; echo 'localhost:5173'; " <>
            "echo 'gone.ex:4: x'; echo 'see lib/b.ex:2 here'"
        )
        |> ran()

      links =
        for i <- 0..(Output.size(state.output) - 1),
            l = Output.link(state.output, i),
            do: {i, l.path, l.line, l.col}

      assert links == [{0, "lib/a.ex", 3, 2}, {4, "lib/b.ex", 2, nil}]

      state = repaint(state)
      screen = Renderer.current()
      {x, y} = drawn_at(screen, "lib/a.ex:3:2")

      for dx <- 0..11 do
        cell = Geex.Screen.get_cell(screen, x + dx, y)
        assert :underline in cell.attrs and cell.fg == state.theme.palette.accent
      end

      refute :underline in Geex.Screen.get_cell(screen, x + 12, y).attrs
      {x, y} = drawn_at(screen, "10:16:05")
      refute :underline in Geex.Screen.get_cell(screen, x, y).attrs
      {x, y} = drawn_at(screen, "lib/b.ex:2")
      assert :underline in Geex.Screen.get_cell(screen, x, y).attrs
      {x, y} = drawn_at(screen, "see lib/b.ex")
      refute :underline in Geex.Screen.get_cell(screen, x, y).attrs
    end

    test "the focused pane's hint names Alt+N while a line is a link", %{root: root} do
      state = editing(root, "notes.txt") |> typed("!echo hi") |> ran() |> repaint()
      {_, y} = drawn_at(Renderer.current(), "! echo hi")
      refute screen_text(Renderer.current(), y) =~ "Alt+N next"

      state = typed(state, "!echo lib/a.ex:3") |> ran() |> repaint()
      assert state.focus == :output
      {_, y} = drawn_at(Renderer.current(), "! echo lib/a.ex:3")
      assert screen_text(Renderer.current(), y) =~ "Enter opens · Alt+N next · ! again · q closes"
    end

    test "a click on a link opens its file there; a click beside it only highlights the row",
         %{root: root} do
      state =
        editing(root, "notes.txt") |> typed("!echo 'x'; echo 'see lib/a.ex:3:2 now'") |> ran()

      state = repaint(state)
      screen = Renderer.current()
      {x, y} = drawn_at(screen, "see lib/a.ex")

      state = click(state, x, y)
      assert shown() == "notes.txt"
      assert state.focus == :output and state.output.sel == 1

      state = click(state, x + 5, y)
      assert shown() == "a.ex"
      assert cursor() == {2, 1}
      assert state.focus == :editor
      assert state.output.at == 1
    end

    test "a link whose file went after it was found says so when clicked", %{root: root} do
      state = editing(root, "notes.txt") |> typed("!echo 'lib/b.ex:2'") |> ran()
      state = repaint(state)
      {x, y} = drawn_at(Renderer.current(), "lib/b.ex:2")
      File.rm!(Path.join(root, "lib/b.ex"))
      state = click(state, x, y)
      assert state.notice == "no such file here: lib/b.ex"
      assert shown() == "notes.txt"
    end

    test "Enter opens a line before its answer has come", %{root: root} do
      state = editing(root, "notes.txt") |> typed("!echo 'lib/a.ex:4'") |> ran_only()
      assert Output.link(state.output, 0) == nil
      state = key(state, {:key, :enter})
      assert shown() == "a.ex" and cursor() == {3, 0}
      assert state.output.at == 0
    end
  end

  describe "Alt+N through a ! command's locations" do
    test "one stop per line, wrapping; after q, the file's matches again", %{root: root} do
      state =
        editing(root, "notes.txt")
        |> typed("!echo 'lib/a.ex:2'; echo '--'; echo 'lib/b.ex:3:2'")
        |> ran()

      assert state.search.last == :output
      state = key(state, {:alt, ?n})
      assert shown() == "a.ex" and cursor() == {1, 0}
      state = key(state, {:alt, ?n})
      assert shown() == "b.ex" and cursor() == {2, 1}
      state = key(state, {:alt, ?n})
      assert shown() == "a.ex" and state.notice == "wrapped to the first location"

      # Closing the pane gives Alt+N back to the file's matches.
      state = key(state, {:alt, ?>}) |> key({:char, "q"})
      assert state.output == nil
      state = editing(root, "notes.txt", state)
      state = %{state | search: %{state.search | query: "find"}}
      state = key(state, {:alt, ?n})
      assert state.search.last == :file
      assert shown() == "notes.txt"
      assert state.selection != nil
    end

    test "a ! naming no file gives Alt+N back to the file's matches", %{root: root} do
      state = editing(root, "notes.txt") |> typed("!echo hello") |> ran()
      state = %{state | search: %{state.search | query: "find"}, focus: :editor}
      state = key(state, {:alt, ?n})
      assert state.search.last == :file
      assert state.selection != nil
    end

    # BUG-26: Alt+N steps by the resolver's answers alone. A resolver told lib/a.ex isn't there
    # makes its line no stop, though the file is: the loop didn't look.
    test "a project search's Alt+N steps only lines the resolver found a file for", %{root: root} do
      {_, 0} = System.cmd("git", ["-C", root, "init", "-q"])
      {_, 0} = System.cmd("git", ["-C", root, "add", "-A"])
      not_a = fn full -> not String.ends_with?(full, "/lib/a.ex") and Geex.Disk.regular?(full) end

      state = %{
        Loop.new_state(120, 30)
        | tree_shown: false,
          edits_shown: false,
          resolver_opts: [regular?: not_a]
      }

      state = editing(root, "notes.txt", state)
      File.write!(Path.join(root, "lib/a.ex"), "one\ndos\n")
      {_, 0} = System.cmd("git", ["-C", root, "add", "-A"])

      state = state |> key({:alt, ?Q}) |> type("dos") |> key({:key, :enter}) |> ran()

      assert Enum.sort(for i <- 0..1, do: Output.line(state.output, i)) == [
               "lib/a.ex:2:dos",
               "lib/b.ex:2:dos"
             ]

      state = key(state, {:alt, ?n})
      assert shown() == "b.ex"
      state = key(state, {:alt, ?n})
      assert shown() == "b.ex" and state.notice == "wrapped to the first result"
    end
  end

  describe "a disk that stalls" do
    test "the loop keeps working, no line is a link, and q stops the held resolver",
         %{root: root} do
      stalled = fn _ -> Process.sleep(:infinity) end

      state = %{
        Loop.new_state(120, 30)
        | tree_shown: false,
          edits_shown: false,
          resolver_opts: [regular?: stalled]
      }

      state =
        editing(root, "notes.txt", state)
        |> typed("!echo 'lib/a.ex:2'; echo 'lib/b.ex:1'")
        |> ran_only()

      %{pid: pid} = state.resolver
      watch = Process.monitor(pid)

      assert Output.pending?(state.output)
      refute Output.links?(state.output)
      refute_receive {:geex_links, ^pid, _, _}, 100

      # Keys still work: move the highlight, Enter still opens by reading the line itself.
      state = key(state, {:cmd, :up}) |> key({:key, :enter})
      assert shown() == "a.ex" and cursor() == {1, 0}

      state = key(state, {:alt, ?>}) |> key({:char, "q"})
      assert state.output == nil and state.resolver == nil
      assert_receive {:DOWN, ^watch, :process, ^pid, :killed}, 5_000
    end
  end
end
