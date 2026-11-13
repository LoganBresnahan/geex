defmodule Geex.Loop.SearchLoopTest do
  # ADR-0053 slice B through the loop's own handle_info/2, no terminal: Alt+Q searches the file
  # as the query is typed, its match the selection; Enter keeps it, Esc puts everything back;
  # Alt+N the next match, in the prompt and out of it; the other matches drawn, the count shown.
  # Uses the global Session and Renderer, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Screen, Selection, Session}
  alias Geex.Commands.Insert

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_search_loop_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # A file of `text` open in a fresh loop, the cursor at `cursor`. `inline: 0` searches every
  # text in a process of its own (the async path).
  defp open(dir, name, text, cursor \\ {0, 0}, opts \\ []) do
    path = Path.join(dir, name)
    File.write!(path, text)
    {:ok, pid} = Session.open_file(path)
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    state = put_in(state.search.inline, Keyword.get(opts, :inline, 1_000_000))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    Session.set_cursor(cursor)
    {state, pid}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp keys(state, events), do: Enum.reduce(events, state, &key(&2, &1))
  defp type(state, text), do: keys(state, Enum.map(String.graphemes(text), &{:char, &1}))
  defp cursor, do: elem(Session.snapshot(), 1).cursor
  defp sel(%{selection: %Selection{anchor: a, active: b}}), do: {a, b}
  defp sel(_state), do: nil

  # The answers of the search processes that report to this process, in the order they came.
  defp answers(state) do
    receive do
      {:geex_search, _pid, _msg} = m ->
        {:noreply, state} = Loop.handle_info(m, state)
        answers(state)
    after
      200 -> state
    end
  end

  defp repaint(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    state
  end

  defp prompt(state) do
    repaint(state)
    screen = Geex.Renderer.current()

    Enum.map_join(0..(screen.w - 1), &Screen.get_cell(screen, &1, screen.h - 1).char)
    |> String.trim()
  end

  describe "Alt+Q: the match is the selection as the query is typed (§1, §2)" do
    test "the first match from the cursor, wrapping; the count at the prompt's end; Enter keeps",
         %{
           dir: dir
         } do
      {state, _buf} = open(dir, "a.txt", "one foo\ntwo foo\nthree foo\n", {1, 0})
      state = key(state, {:alt, ?q})
      assert state.minibuffer.mode == :search
      state = type(state, "foo")
      assert sel(state) == {{1, 4}, {1, 7}}
      assert prompt(state) =~ ~r/^search:foo +2 of 3$/

      state = key(state, {:key, :enter})
      assert state.minibuffer.mode == :inactive
      assert sel(state) == {{1, 4}, {1, 7}}
      assert state.search.query == "foo" and state.search.active
      assert state.recall.search.entries == ["foo"]
    end

    test "wraps past the end to the first match, saying so", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "foo\nbar\n", {1, 0})
      state = state |> key({:alt, ?q}) |> type("foo")
      assert sel(state) == {{0, 0}, {0, 3}}
      assert prompt(state) =~ "wrapped to the top"
    end

    test "smart case: lower case finds any case, a capital only itself", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "Foo foo\n")
      state = state |> key({:alt, ?q}) |> type("foo")
      assert sel(state) == {{0, 0}, {0, 3}}

      state =
        state |> key({:key, :backspace}) |> key({:key, :backspace}) |> key({:key, :backspace})

      state = type(state, "foO")
      assert sel(state) == nil
      assert prompt(state) =~ "no match"
    end

    test "Esc puts back the cursor, the selection and the scroll", %{dir: dir} do
      text = Enum.map_join(0..199, &"line #{&1}\n") <> "needle\n"
      {state, _buf} = open(dir, "a.txt", text, {3, 2})
      # A selection over two lines: nothing to fill the prompt with.
      state = state |> key({:alt, ?s}) |> key({:alt, ?k}) |> repaint()
      before = {cursor(), sel(state), Geex.Loop.Panes.current(state.panes).scroll}
      state = state |> key({:alt, ?q}) |> type("needle") |> repaint()
      assert sel(state) == {{200, 0}, {200, 6}}
      assert Geex.Loop.Panes.current(state.panes).scroll > 0

      state = key(state, {:key, :esc})
      assert state.minibuffer.mode == :inactive
      assert {cursor(), sel(state), Geex.Loop.Panes.current(state.panes).scroll} == before
      refute state.search.active
    end

    test "an emptied query puts back what was there; no match clears the selection", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "abc abc\n", {0, 1})
      state = state |> key({:alt, ?q}) |> type("b")
      assert sel(state) == {{0, 1}, {0, 2}}
      state = key(state, {:key, :backspace})
      assert {sel(state), cursor()} == {nil, {0, 1}}
      refute prompt(state) =~ "no match"

      state = type(state, "zz")
      assert {sel(state), cursor()} == {nil, {0, 1}}
      assert prompt(state) =~ "no match"
    end

    test "a one-line selection fills the prompt; its occurrence is match 1", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "x cat cat\n", {0, 6})
      state = state |> key({:alt, ?s}) |> keys([{:alt, ?l}, {:alt, ?l}, {:alt, ?l}])
      state = key(state, {:alt, ?q})
      assert Geex.Minibuffer.value(state.minibuffer) == "cat"
      assert sel(state) == {{0, 6}, {0, 9}}
      assert prompt(state) =~ "2 of 2"
    end

    test "a selection holding a byte that isn't UTF-8 fills the prompt with that byte", %{
      dir: dir
    } do
      {state, _buf} =
        open(dir, "l.txt", "caf" <> <<0xE9>> <> " and caf" <> <<0xE9>> <> "\n", {0, 9})

      state = state |> key({:alt, ?s}) |> keys(List.duplicate({:alt, ?l}, 4))
      state = key(state, {:alt, ?q})
      assert Geex.Minibuffer.value(state.minibuffer) == "caf" <> <<0xE9>>
      assert sel(state) == {{0, 9}, {0, 13}}
      assert prompt(state) =~ "2 of 2"
    end

    test "Enter on an empty prompt runs the last query again (Q4)", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "ab ab ab\n")
      state = state |> key({:alt, ?q}) |> type("ab") |> key({:key, :enter})
      # No selection to fill the prompt with: Enter on it empty runs "ab" from the cursor.
      state = %{state | selection: nil} |> key({:alt, ?q}) |> key({:key, :enter})
      assert state.minibuffer.mode == :inactive
      assert sel(state) == {{0, 3}, {0, 5}}
    end

    test "Alt+Q from the tree searches the file pane (Q7)", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "find me\n")
      state = %{state | tree_shown: true, focus: :tree}
      state = state |> key({:alt, ?q}) |> type("me")
      assert state.focus == :editor
      assert sel(state) == {{0, 5}, {0, 7}}
    end
  end

  describe "the maintainer's answers of 2026-11-13" do
    test "the first plain move after a search drops its match; a later selection extends", %{
      dir: dir
    } do
      {state, _pid} = open(dir, "a.txt", "x needle y\n")
      state = state |> key({:alt, ?q}) |> type("needle") |> key({:key, :enter})
      assert sel(state) == {{0, 2}, {0, 8}}
      state = key(state, {:cmd, :right})
      assert {sel(state), cursor()} == {nil, {0, 9}}

      # Alt+N's match too; then Alt+S starts a selection a move extends, as before.
      state = key(state, {:alt, ?n}) |> key({:cmd, :left})
      assert sel(state) == nil
      state = state |> key({:alt, ?s}) |> key({:cmd, :right})
      assert sel(state) != nil
    end

    test "typing over the match replaces it, as before: no selection left to drop", %{dir: dir} do
      {state, _pid} = open(dir, "a.txt", "needle a\nneedle b\n")
      state = state |> key({:alt, ?q}) |> type("needle") |> key({:key, :enter})
      # Typing over the match replaces it: no selection is left to drop.
      state = type(state, "N")
      assert sel(state) == nil
      assert Buffer.snapshot(Session.active_buffer() |> elem(1)).text =~ "N a"
    end

    test "a pre-fill from the selection is replaced by the first key, kept by Backspace", %{
      dir: dir
    } do
      {state, _pid} = open(dir, "a.txt", "Needle needle\n")
      state = state |> key({:alt, ?8}) |> key({:alt, ?q})
      assert {state.minibuffer.input, state.minibuffer.fresh} == {"Needle", true}
      # Drawn as selected: the pre-fill the other way round from the prompt before it.
      reverse? = fn x ->
        screen = Geex.Renderer.current()
        :reverse in Screen.get_cell(screen, x, screen.h - 1).attrs
      end

      repaint(state)
      assert reverse?.(7) != reverse?.(0)
      assert reverse?.(12) == reverse?.(7)
      state = type(state, "needle")
      repaint(state)
      assert reverse?.(7) == reverse?.(0)
      assert state.minibuffer.input == "needle"
      # Smart case: the lower-case query found the first `Needle`, now selected.
      assert sel(state) == {{0, 0}, {0, 6}}

      # Esc puts back the selection the search started from; Alt+Q pre-fills it again.
      state = key(state, {:key, :esc}) |> key({:alt, ?q})
      assert {state.minibuffer.input, state.minibuffer.fresh} == {"Needle", true}
      state = state |> key({:key, :backspace}) |> type("x")
      assert {state.minibuffer.input, state.minibuffer.fresh} == {"Needlx", false}
    end
  end

  describe "typed at Alt+M: `search TEXT` (2026-11-13)" do
    defp command(state, line), do: state |> key({:alt, ?m}) |> type(line) |> key({:key, :enter})

    test "selects the first match from the cursor, the prompt closed, Alt+N goes on", %{dir: dir} do
      {state, _pid} = open(dir, "a.txt", "x needle\nNeedle y\n")
      state = command(state, "search needle")
      assert state.minibuffer.mode == :inactive
      assert sel(state) == {{0, 2}, {0, 8}}
      state = key(state, {:alt, ?n})
      assert sel(state) == {{1, 0}, {1, 6}}
    end

    test "the text replaces a selection's pre-fill; a capital keeps smart case", %{dir: dir} do
      {state, _pid} = open(dir, "a.txt", "needle Needle\n")
      state = state |> key({:alt, ?7}) |> key({:alt, ?7})
      state = command(state, "search Needle")
      assert sel(state) == {{0, 7}, {0, 13}}
    end

    test "searched off the loop, the answer selects it", %{dir: dir} do
      {state, _pid} = open(dir, "a.txt", "x\nthe needle\n", {0, 0}, inline: 0)
      state = state |> command("search needle") |> answers()
      assert state.minibuffer.mode == :inactive
      assert sel(state) == {{1, 4}, {1, 10}}
    end

    test "an unknown command says so", %{dir: dir} do
      {state, _pid} = open(dir, "a.txt", "x\n")
      state = command(state, "word back")
      assert state.notice == "unknown command: word back"
    end
  end

  describe "from a preview" do
    test "Alt+Q searches the pane the preview was opened from", %{dir: dir} do
      {state, _buf} = open(dir, "n.md", "# Title\n\nsome words\n")
      state = state |> Loop.toggle_preview() |> key({:alt, ?>})
      assert Geex.Loop.Panes.preview?(Geex.Loop.Panes.current(state.panes))
      state = state |> key({:alt, ?q}) |> type("words")
      refute Geex.Loop.Panes.preview?(Geex.Loop.Panes.current(state.panes))
      assert sel(state) == {{2, 5}, {2, 10}}
    end
  end

  describe "Alt+N: the next match (§3)" do
    test "in the prompt it steps and the prompt stays open", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "a.a.a\n")
      state = state |> key({:alt, ?q}) |> type("a")
      assert sel(state) == {{0, 0}, {0, 1}}
      state = key(state, {:alt, ?n})
      assert state.minibuffer.mode == :search
      assert sel(state) == {{0, 2}, {0, 3}}
      assert prompt(state) =~ "2 of 3"
      state = keys(state, [{:alt, ?n}, {:alt, ?n}])
      assert sel(state) == {{0, 0}, {0, 1}}
      assert prompt(state) =~ "1 of 3 · wrapped to the top"
    end

    test "outside it, the last query from the selection's end, wrapping with a notice", %{
      dir: dir
    } do
      {state, _buf} = open(dir, "a.txt", "x y x y\n")
      state = state |> key({:alt, ?q}) |> type("y") |> key({:key, :enter})
      assert sel(state) == {{0, 2}, {0, 3}}
      state = key(state, {:alt, ?n})
      assert sel(state) == {{0, 6}, {0, 7}}
      state = key(state, {:alt, ?n})
      assert sel(state) == {{0, 2}, {0, 3}}
      assert state.notice == "wrapped to the top"
    end

    test "with no query, the selection's text; with neither, a notice naming Alt+Q", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "ox ox\n")
      state = key(state, {:alt, ?n})
      assert state.notice == "nothing to search for (Alt+Q searches)"

      state = state |> key({:alt, ?s}) |> keys([{:alt, ?l}, {:alt, ?l}])
      state = key(state, {:alt, ?n})
      assert sel(state) == {{0, 3}, {0, 5}}
      assert state.search.query == "ox"
    end

    test "the last query is every file's (Q6)", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "zebra\n")
      state = state |> key({:alt, ?q}) |> type("zeb") |> key({:key, :enter})
      {state, _} = {state, File.write!(Path.join(dir, "b.txt"), "a zebra\n")}
      {:ok, b} = Session.open_file(Path.join(dir, "b.txt"))
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, b}, state)
      Session.set_cursor({0, 0})
      state = key(state, {:alt, ?n})
      assert sel(state) == {{0, 2}, {0, 5}}
    end
  end

  describe "off the loop (ADR-0035, R6–R9)" do
    test "the first match comes first, then the count; a newer query's search replaces it", %{
      dir: dir
    } do
      {state, _buf} = open(dir, "a.txt", "ab ab abc\n", {0, 0}, inline: 0)
      state = state |> key({:alt, ?q}) |> type("ab")
      old = state.search.task.pid
      state = type(state, "c")
      refute Process.alive?(old)
      state = answers(state)
      assert sel(state) == {{0, 6}, {0, 9}}
      assert prompt(state) =~ "1 of 1"
    end

    test "Alt+N pressed while the search runs moves as many matches when it answers", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "q q q q q\n", {0, 0}, inline: 0)
      state = state |> key({:alt, ?q}) |> type("q") |> answers() |> key({:key, :enter})
      # An edit makes the kept answer stale: the next presses wait on a new search.
      state = key(%{state | selection: nil}, {:key, :end})
      state = state |> type(" q") |> repaint()
      Session.set_cursor({0, 0})
      state = keys(state, [{:alt, ?n}, {:alt, ?n}, {:alt, ?n}])
      state = answers(state)
      assert sel(state) == {{0, 4}, {0, 5}}
    end

    test "the text changing under the open prompt searches again from where it started", %{
      dir: dir
    } do
      {state, buf} = open(dir, "a.txt", "aaa x\n", {0, 0}, inline: 0)
      state = state |> key({:alt, ?q}) |> type("x") |> answers()
      assert sel(state) == {{0, 4}, {0, 5}}
      # An outside edit (an agent's) puts another x first.
      {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "x"})

      {:ok, _} =
        Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.new(:external)))

      state = state |> repaint() |> answers()
      assert sel(state) == {{0, 0}, {0, 1}}
      assert prompt(state) =~ "1 of 2"
    end
  end

  describe "an answer still to come (mod-verify's review of slice B)" do
    # "q" kept as the last query, its answer made stale by an edit: Alt+N then waits on a search.
    defp stale(dir, opts \\ []) do
      {state, buf} = open(dir, "a.txt", Keyword.get(opts, :text, "q q q\n"), {0, 0}, inline: 0)
      state = state |> key({:alt, ?q}) |> type("q") |> answers() |> key({:key, :enter})
      # Esc stops showing the matches, so the frame doesn't search again after the edit.
      state = state |> key({:key, :esc}) |> key({:key, :end}) |> type(" z") |> repaint()
      refute state.search.task

      Session.set_cursor({0, 0})
      {%{state | selection: nil}, buf}
    end

    test "Esc after Alt+N: the answer selects nothing", %{dir: dir} do
      {state, _buf} = stale(dir)
      state = state |> key({:alt, ?n}) |> key({:key, :esc}) |> answers()
      assert {sel(state), cursor()} == {nil, {0, 0}}
    end

    test "a motion after Alt+N: the answer doesn't pull the cursor back", %{dir: dir} do
      {state, _buf} = stale(dir, text: "q q q\nnext line\n")
      state = state |> key({:alt, ?n}) |> key({:alt, ?k}) |> answers()
      assert sel(state) == nil
      assert {1, _} = cursor()
    end

    test "another file shown before the answer: nothing selected there", %{dir: dir} do
      {state, _buf} = stale(dir)
      state = key(state, {:alt, ?n})
      File.write!(Path.join(dir, "b.txt"), "other text here\n")
      {:ok, b} = Session.open_file(Path.join(dir, "b.txt"))
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, b}, state)
      state = answers(state)
      assert sel(state) == nil
      state = type(state, "Y")
      assert Buffer.get_text(b) =~ "Y"
    end

    test "presses queued past the last match wrap to the first", %{dir: dir} do
      {state, _buf} = stale(dir)
      state = keys(state, [{:alt, ?n}, {:alt, ?n}, {:alt, ?n}, {:alt, ?n}]) |> answers()
      assert sel(state) == {{0, 0}, {0, 1}}
    end

    test "a superseded search is stopped while it still runs", %{dir: dir} do
      big = String.duplicate("the quick brown fox jumps over the lazy dog\n", 100_000)
      {state, _buf} = open(dir, "big.txt", big, {0, 0}, inline: 0)
      state = state |> key({:alt, ?q}) |> type("zebra")
      old = state.search.task.pid
      assert Process.alive?(old)
      state = type(state, "s")
      refute Process.alive?(old)
      _ = answers(state)
    end
  end

  describe "the goal's paths (mod-verify's pass of slice B)" do
    test "a selection started after the press: the answer keeps it", %{dir: dir} do
      {state, _buf} = stale(dir)
      state = state |> key({:alt, ?n}) |> key({:alt, ?s}) |> answers()
      assert %Selection{anchor: {0, 0}, active: {0, 0}} = state.selection
    end

    test "a press after a move starts from there, not one match further", %{dir: dir} do
      {state, _buf} = stale(dir, text: "q\nq\nx\nx\nq\n")
      state = state |> key({:alt, ?n}) |> keys([{:alt, ?k}, {:alt, ?k}]) |> key({:alt, ?n})
      state = answers(state)
      assert sel(state) == {{4, 0}, {4, 1}}
    end

    test "two presses, then a move: the full answer selects nothing", %{dir: dir} do
      {state, _buf} = stale(dir, text: "q q q\nnext\n")
      state = state |> keys([{:alt, ?n}, {:alt, ?n}]) |> key({:alt, ?k}) |> answers()
      assert sel(state) == nil
      assert {1, _} = cursor()
    end

    test "two presses, then another file: nothing selected there", %{dir: dir} do
      {state, _buf} = stale(dir)
      state = keys(state, [{:alt, ?n}, {:alt, ?n}])
      File.write!(Path.join(dir, "b.txt"), "other\n")
      {:ok, b} = Session.open_file(Path.join(dir, "b.txt"))
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, b}, state)
      assert sel(answers(state)) == nil
    end

    test "a query past 64 graphemes is searched in a process of its own", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", String.duplicate("a", 100) <> "\n")
      state = state |> key({:alt, ?q}) |> type(String.duplicate("a", 64))
      assert state.search.task == nil
      state = type(state, "a")
      assert state.search.task != nil
      _ = answers(state)
    end

    test "a frame after the text changed under the prompt draws the moved cursor", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "ab xy\n")
      state = state |> key({:alt, ?q}) |> type("xy")
      assert cursor() == {0, 5}
      {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "zz"})

      {:ok, _} =
        Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.new(:external)))

      state = repaint(state)
      assert cursor() == {0, 7}
      assert Geex.Loop.Panes.current(state.panes).cursor == {0, 7}
    end
  end

  describe "what the prompt keeps (mod-verify's review of slice B)" do
    test "Esc after the text changed under the prompt puts back no stale selection", %{dir: dir} do
      {state, buf} = open(dir, "a.txt", "aa bb\ncc dd\n", {0, 0})
      # A selection over two lines (nothing to fill the prompt with).
      state = state |> key({:alt, ?s}) |> key({:alt, ?k})
      assert sel(state) != nil
      state = state |> key({:alt, ?q}) |> type("dd")
      {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "x"})

      {:ok, _} =
        Buffer.dispatch(buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.new(:external)))

      state = state |> repaint() |> key({:key, :esc})
      assert sel(state) == nil
    end

    test "a selection after an emoji before a bad byte fills the prompt", %{dir: dir} do
      {state, _buf} = open(dir, "l.txt", "©" <> <<0xE9>> <> " cat cat\n", {0, 7})
      state = state |> key({:alt, ?s}) |> keys([{:alt, ?l}, {:alt, ?l}, {:alt, ?l}])
      state = key(state, {:alt, ?q})
      assert Geex.Minibuffer.value(state.minibuffer) == "cat"
      assert prompt(state) =~ "2 of 2"
    end
  end

  describe "the other matches (§5, Q1, Q2)" do
    defp cell(x, y), do: Screen.get_cell(Geex.Renderer.current(), x, y)

    test "drawn in the theme's search colour, and gone after Esc", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "ab ab\n")
      state = %{state | theme: Geex.Fixtures.birds()}
      state = state |> key({:alt, ?q}) |> type("ab") |> key({:key, :enter}) |> repaint()
      gw = Loop.gutter_width("ab ab\n")
      # The second match (not selected) wears the search colour; the first is the selection.
      assert cell(gw + 3, 1).bg == state.theme.palette.search
      assert cell(gw, 1).bg == state.theme.palette.selection
      state = state |> key({:key, :esc}) |> repaint()
      assert cell(gw + 3, 1).bg != state.theme.palette.search
    end

    test "only the query shown: an older query's matches aren't drawn while a newer one runs", %{
      dir: dir
    } do
      {state, _buf} = open(dir, "a.txt", "ab ab\n", {0, 0}, inline: 0)
      state = %{state | theme: Geex.Fixtures.birds()}
      state = state |> key({:alt, ?q}) |> type("ab") |> answers()
      # "abx" is searching; "ab"'s answer is still kept.
      state = state |> type("x") |> repaint()
      gw = Loop.gutter_width("ab ab\n")
      assert cell(gw + 3, 1).bg != state.theme.palette.search
      _ = answers(state)
    end

    test "underlined in the terminal's own colours, where the selection is reverse video", %{
      dir: dir
    } do
      {state, _buf} = open(dir, "a.txt", "ab ab\n")
      assert state.theme.palette.search == nil
      _state = state |> key({:alt, ?q}) |> type("ab") |> key({:key, :enter}) |> repaint()
      gw = Loop.gutter_width("ab ab\n")
      assert :underline in cell(gw + 3, 1).attrs
    end

    test "they follow an edit: a new match shows without searching again by hand", %{dir: dir} do
      {state, _buf} = open(dir, "a.txt", "ab\n")
      state = %{state | theme: Geex.Fixtures.birds()}
      state = state |> key({:alt, ?q}) |> type("ab") |> key({:key, :enter})
      state = %{state | selection: nil} |> key({:key, :end}) |> type(" ab") |> repaint()
      gw = Loop.gutter_width("ab ab\n")
      assert cell(gw + 3, 1).bg == state.theme.palette.search
    end

    test "a line of a million matches draws its row's, fast", %{dir: dir} do
      line = String.duplicate("ab", 1_000_000)
      {state, _buf} = open(dir, "l.txt", line <> "\n", {0, 1_999_990}, inline: 0)
      state = state |> key({:alt, ?q}) |> type("ab") |> answers() |> key({:key, :enter})
      {us, _} = :timer.tc(fn -> repaint(state) end)
      assert div(us, 1000) < 500
    end
  end
end
