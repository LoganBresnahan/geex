defmodule Geex.Loop.ComfortTest do
  # The maintainer's editor-comfort list (roadmap item 18) through the loop's own handle_info/2,
  # with no terminal. Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_comfort_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "hello world\nline 2\n")
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    {:ok, pid} = Session.open_file(Path.join(dir, "a.txt"))
    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    %{dir: dir, buf: pid, state: state}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp keys(state, events), do: Enum.reduce(events, state, &key(&2, &1))
  defp text(buf), do: Buffer.get_text(buf)
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  # Alt+S at the cursor, then `n` steps right: "hello world" with `hel` selected from {0, 0}.
  defp select_right(state, n), do: keys(state, [{:alt, ?s} | List.duplicate({:alt, ?l}, n)])

  describe "typing over a selection (18.1)" do
    test "Delete deletes the selection, one undoable edit", %{state: state, buf: buf} do
      state = state |> select_right(3) |> key({:key, :delete})

      assert text(buf) == "lo world\nline 2\n"
      assert cursor() == {0, 0}
      assert state.selection == nil
      assert length(Buffer.history(buf)) == 1

      key(state, {:alt, ?z})
      assert text(buf) == "hello world\nline 2\n"
    end

    test "Backspace deletes the selection too", %{state: state, buf: buf} do
      state |> select_right(5) |> key({:key, :backspace})
      assert text(buf) == " world\nline 2\n"
      assert cursor() == {0, 0}
    end

    test "a selection made backwards deletes the same range", %{state: state, buf: buf} do
      Session.set_cursor({0, 5})
      state |> keys([{:alt, ?s}, {:alt, ?j}, {:alt, ?j}]) |> key({:key, :delete})
      assert text(buf) == "hel world\nline 2\n"
      assert cursor() == {0, 3}
    end

    test "a printable key replaces the selection; Enter does too", %{state: state, buf: buf} do
      state = state |> select_right(5) |> key({:char, "J"})
      assert text(buf) == "J world\nline 2\n"
      assert cursor() == {0, 1}

      Session.set_cursor({0, 2})
      state |> select_right(5) |> key({:key, :enter})
      assert text(buf) == "J \n\nline 2\n"
      assert cursor() == {1, 0}
    end

    test "a selection across lines is deleted whole", %{state: state, buf: buf} do
      # Moved by keys, so the goal column follows: Alt+K keeps column 5.
      state
      |> keys(List.duplicate({:alt, ?l}, 5) ++ [{:alt, ?s}, {:alt, ?k}])
      |> key({:key, :delete})

      assert text(buf) == "hello2\n"
    end

    test "with no selection, or a collapsed one, Delete deletes one grapheme", %{
      state: state,
      buf: buf
    } do
      state = key(state, {:key, :delete})
      assert text(buf) == "ello world\nline 2\n"

      state |> key({:alt, ?s}) |> key({:key, :delete})
      assert text(buf) == "llo world\nline 2\n"
    end
  end

  describe "[+] follows the text (18.2)" do
    test "a space typed and deleted with Backspace is clean again", %{state: state, buf: buf} do
      state = key(state, {:char, " "})
      assert Buffer.status(buf).dirty
      key(state, {:key, :backspace})
      refute Buffer.status(buf).dirty
      assert text(buf) == "hello world\nline 2\n"
    end
  end

  describe "a final newline on save (18.4)" do
    defp open_file(state, dir, name, text) do
      path = Path.join(dir, name)
      File.write!(path, text)
      {:ok, pid} = Session.open_file(path)
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
      {state, pid, path}
    end

    # Off by default; the maintainer's word for on: every save, edited or not.
    defp on(state), do: %{state | final_newline: true}

    test "on, a save adds the missing newline, as an edit Alt+Z takes back", %{
      state: state,
      dir: dir
    } do
      {state, buf, path} = open_file(on(state), dir, "b.txt", "no newline")
      Session.set_cursor({0, 3})
      state = state |> key({:char, "!"}) |> key({:ctrl, ?o})

      assert File.read!(path) == "no !newline\n"
      assert text(buf) == "no !newline\n"
      refute Buffer.status(buf).dirty
      assert cursor() == {0, 4}

      assert [%Geex.Commands.Insert{text: "!"}, %Geex.Commands.Insert{text: "\n"} = nl] =
               Buffer.history(buf)

      assert nl.meta.actor == :human

      key(state, {:alt, ?z})
      assert text(buf) == "no !newline"
      assert Buffer.status(buf).dirty
    end

    test "on, an untouched file gets one too; an empty one, or one that ends in one, is as it is",
         %{state: state, dir: dir} do
      {state, buf, path} = open_file(on(state), dir, "u.txt", "never touched")
      state = key(state, {:ctrl, ?o})
      assert File.read!(path) == "never touched\n"
      assert [%Geex.Commands.Insert{text: "\n"}] = Buffer.history(buf)

      {state, buf, path} = open_file(state, dir, "c.txt", "")
      state = key(state, {:ctrl, ?o})
      assert File.read!(path) == ""
      assert Buffer.history(buf) == []

      {state, buf, _path} = open_file(state, dir, "d.txt", "done\n")
      state |> key({:char, "x"}) |> key({:ctrl, ?o})
      assert text(buf) == "xdone\n"
    end

    test "on, a CRLF file gets CRLF; one ending in a bare CR gets only the LF", %{
      state: state,
      dir: dir
    } do
      {state, _buf, path} = open_file(on(state), dir, "w.txt", "a\r\nb")
      state = state |> key({:char, "x"}) |> key({:ctrl, ?o})
      assert File.read!(path) == "xa\r\nb\r\n"

      # geex-d3's last pass: a CRLF file whose last line break lost its LF.
      {state, _buf, path} = open_file(state, dir, "cr.txt", "a\r\nb\r")
      key(state, {:ctrl, ?o})
      assert File.read!(path) == "a\r\nb\r\n"
    end

    # The review's first finding: the newline went in before the save caught up with the disk,
    # so a clean buffer whose file an agent changed merged with conflict markers. Now the save
    # catches up first, then adds it.
    test "on, a clean buffer whose file changed catches up first, with no conflict", %{
      state: state,
      dir: dir
    } do
      {state, buf, path} = open_file(on(state), dir, "g.txt", "x\ny")
      File.write!(path, "x\nz")
      key(state, {:ctrl, ?o})

      assert text(buf) == "x\nz\n"
      assert File.read!(path) == "x\nz\n"
      refute Buffer.status(buf).dirty
      assert [%Geex.Commands.Insert{text: "\n"} = nl | _] = Enum.reverse(Buffer.history(buf))
      assert nl.meta.actor == :human

      refute Enum.any?(
               Buffer.history(buf),
               &match?(%{meta: %{actor: :human}, text: "<" <> _}, &1)
             )
    end

    test "on, with your edits and the file changed elsewhere, the merge comes first", %{
      state: state,
      dir: dir
    } do
      # Hunks apart, as git's merge needs them (adjacent ones conflict).
      {state, buf, path} = open_file(on(state), dir, "m.txt", "one\n2\n3\ntwo")
      state = key(state, {:char, "1"})
      File.write!(path, "one\n2\n3\ntwo\nthree")
      key(state, {:ctrl, ?o})

      assert text(buf) == "1one\n2\n3\ntwo\nthree\n"
      assert File.read!(path) == "1one\n2\n3\ntwo\nthree\n"
    end

    test "on, a save that fails leaves no newline behind", %{state: state, dir: dir} do
      {state, buf, path} = open_file(on(state), dir, "r.txt", "abc")
      File.chmod!(path, 0o444)
      on_exit(fn -> File.chmod(path, 0o644) end)
      state |> key({:char, "x"}) |> key({:ctrl, ?o})

      assert text(buf) == "xabc"
      assert File.read!(path) == "abc"
      assert Buffer.status(buf).dirty
      assert [%Geex.Commands.Insert{text: "x"}] = Buffer.history(buf)
    end

    test "off, the default, a save writes the text as it is", %{state: state, dir: dir} do
      refute state.final_newline
      {state, _buf, path} = open_file(state, dir, "e.txt", "bare")
      state |> key({:char, "x"}) |> key({:ctrl, ?o})
      assert File.read!(path) == "xbare"
    end

    test "settings.json's final_newline: true turns it on; it is off without" do
      assert Loop.apply_settings(Loop.new_state(80, 24), %{"final_newline" => true}).final_newline
      refute Loop.apply_settings(Loop.new_state(80, 24), %{}).final_newline
    end
  end

  describe "the tab bar scrolls (18.5)" do
    alias Geex.Loop.Panes

    # Seven tabs of 16 columns (` N file_N.txt × `) in a 60-column pane: three fit with a mark.
    defp many_tabs(state, dir) do
      Enum.reduce(1..7, state, fn n, acc ->
        path = Path.join(dir, "file_#{n}.txt")
        File.write!(path, "#{n}\n")
        {:ok, pid} = Session.open_file(path)
        {:noreply, acc} = Loop.handle_info({:geex_active_buffer, pid}, acc)
        acc
      end)
    end

    defp bar_row(state) do
      {:noreply, _} = Loop.handle_info(:repaint, state)
      screen = Geex.Renderer.current()
      Enum.map_join(0..(screen.w - 1), &Geex.Screen.get_cell(screen, &1, 0).char)
    end

    defp wheel(state, button, x, y) do
      key(state, {:mouse, %{action: :wheel, button: button, x: x, y: y, mods: []}})
    end

    defp click(state, x, y) do
      state
      |> key({:mouse, %{action: :press, button: :left, x: x, y: y, mods: []}})
      |> key({:mouse, %{action: :release, button: :left, x: x, y: y, mods: []}})
    end

    test "the marks count the tabs out of view; the bar follows the shown tab", %{
      state: state,
      dir: dir
    } do
      state = many_tabs(%{state | w: 60}, dir)
      # a.txt is tab 1, file_7.txt tab 8 and shown: the bar ends with it, five hidden at the left.
      row = bar_row(state)
      assert row =~ ~r/^‹5 +6 file_5\.txt × +7 file_6\.txt × +8 file_7\.txt ×/
      refute row =~ "›"

      # `tab 1`: tab 1 shown, the bar starts at it, five hidden at the right.
      row = state |> key({:cmd, {:tab, 0}}) |> bar_row()
      assert row =~ ~r/^ 1 a\.txt ×.* 5›/
      refute row =~ "‹"
    end

    test "the wheel over the bar scrolls it, leaving the shown tab", %{state: state, dir: dir} do
      state = many_tabs(%{state | w: 60}, dir)
      shown = state.panes.panes[1].at
      state = wheel(state, :up, 30, 0)
      assert Panes.bar_first(state.panes.panes[1]) == 4
      assert state.panes.panes[1].at == shown
      assert bar_row(state) =~ ~r/^‹4 +5 file_4\.txt ×.* 1›/

      # Scrolled past either end, it stops.
      state = Enum.reduce(1..10, state, fn _, acc -> wheel(acc, :up, 30, 0) end)
      assert Panes.bar_first(state.panes.panes[1]) == 0
      state = Enum.reduce(1..10, state, fn _, acc -> wheel(acc, :down, 30, 0) end)
      assert Panes.bar_first(state.panes.panes[1]) == 5

      # A tab switch follows the shown tab again.
      state = key(state, {:cmd, {:tab, 0}})
      assert Panes.bar_first(state.panes.panes[1]) == nil
      assert bar_row(state) =~ ~r/^ 1 a\.txt/
    end

    # The review's item 8: the scroll was kept by the shown tab's index alone, so leaving the
    # tab and coming back brought the old scroll back, hiding the tab you were on.
    test "leaving the shown tab and coming back follows it, not the old scroll", %{
      state: state,
      dir: dir
    } do
      state = many_tabs(%{state | w: 60}, dir)
      state = wheel(state, :up, 30, 0) |> wheel(:up, 30, 0)
      assert Panes.bar_first(state.panes.panes[1]) == 3
      state = state |> key({:alt, ?,}) |> key({:alt, ?.})
      assert Panes.bar_first(state.panes.panes[1]) == nil
      assert bar_row(state) =~ "8 file_7.txt ×"
    end

    test "a click on a mark scrolls a tab that way", %{state: state, dir: dir} do
      state = many_tabs(%{state | w: 60}, dir)
      state = click(state, 0, 0)
      assert Panes.bar_first(state.panes.panes[1]) == 4
      row = bar_row(state)
      right = row |> String.graphemes() |> Enum.find_index(&(&1 == "›"))
      state = click(state, right, 0)
      assert Panes.bar_first(state.panes.panes[1]) == 5
    end
  end

  describe "the tab size (18.7)" do
    test "Tab inserts the tab size's spaces", %{state: state, buf: buf} do
      state = key(state, {:key, :tab})
      assert text(buf) == "  hello world\nline 2\n"
      assert cursor() == {0, 2}

      key(%{state | tab_size: 4}, {:key, :tab})
      assert text(buf) == "      hello world\nline 2\n"
      assert cursor() == {0, 6}
    end

    test "a tab character draws to its stop; the cursor and a click agree (BUG-10)" do
      theme = Geex.Theme.default()
      text = "\tx\nab\ty"
      # The gutter is 4 columns: line 1's `x` at 4 + 4, line 2's `y` at 4 + 4 (a tab from 2).
      {screen, cursor, _} = Loop.frame(text, [], theme, {0, 1}, 30, 3, 0, 0, nil, true, 4)
      assert Geex.Screen.get_cell(screen, 8, 0).char == "x"
      assert Geex.Screen.get_cell(screen, 8, 1).char == "y"
      assert Geex.Screen.get_cell(screen, 6, 1).char == " "
      assert cursor == {8, 0}

      assert Loop.max_line_width(text, 4) == 5
      assert Loop.max_line_width("ab\n\t\tx", 4) == 9
      assert Loop.max_line_width("ab\n\t\tx", 2) == 5
      # A click on any column of the tab lands on it; past it, on `x`.
      rect = %Geex.Rect{x: 0, y: 0, w: 30, h: 5}
      assert {{0, 0}, _} = Geex.Loop.Mouse.text_pos(text, rect, {0, 0}, {6, 1}, 4)
      assert {{0, 1}, _} = Geex.Loop.Mouse.text_pos(text, rect, {0, 0}, {8, 1}, 4)
    end

    # The review's item 10: the tab size reaches every width walk the loop makes. At tab size
    # 4, `\tx` puts `x` at display column 4 (0-based), and the second line (10 tabs, 90 `x`) is
    # 130 wide: wider than the 116 text columns, so it scrolls and has a bar. At 2 it would be
    # 110 and fit; every assertion below would come out differently.
    test "the tab size reaches the frame, the mouse, the wheel, the scroll bar and grid mode", %{
      state: state,
      dir: dir
    } do
      path = Path.join(dir, "tabs.txt")
      File.write!(path, "\tx\n" <> String.duplicate("\t", 10) <> String.duplicate("x", 90))
      {:ok, pid} = Session.open_file(path)
      state = %{state | w: 120, h: 30, tab_size: 4}
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)

      mouse = fn st, action, x, y, mods ->
        key(st, {:mouse, %{action: action, button: :left, x: x, y: y, mods: mods}})
      end

      # The frame: the gutter is 4 columns, so `x` is at 8; the bar's thumb on row 28.
      {:noreply, state} = Loop.handle_info(:repaint, state)
      screen = Geex.Renderer.current()
      assert Geex.Screen.get_cell(screen, 8, 1).char == "x"
      assert Enum.any?(0..119, &(Geex.Screen.get_cell(screen, &1, 28).char == "━"))

      # A click on display column 3 is inside the tab; a drag to column 4 reaches `x`.
      state = state |> mouse.(:press, 7, 1, []) |> mouse.(:release, 7, 1, [])
      assert cursor() == {0, 0}
      state = state |> mouse.(:press, 5, 1, []) |> mouse.(:drag, 8, 1, [])
      assert state.selection.active == {0, 1}
      state = mouse.(state, :release, 8, 1, [])

      # Shift+wheel scrolls sideways, as far as the 130-column line goes.
      state =
        key(state, {:mouse, %{action: :wheel, button: :down, x: 50, y: 5, mods: [:shift]}})

      assert Geex.Loop.Panes.current(state.panes).hscroll == 6

      # A press on the horizontal bar takes it (it isn't a click in the text).
      state = mouse.(state, :press, 60, 28, [])
      assert state.scrolling != nil
      state = mouse.(state, :release, 60, 28, [])

      # A drag held past the right edge scrolls on its tick, as far as the long line goes.
      before = Geex.Loop.Panes.current(state.panes).hscroll
      state = state |> mouse.(:press, 50, 2, []) |> mouse.(:drag, 119, 2, [])
      assert_receive {:geex_drag_scroll, _ref} = tick, 1_000
      {:noreply, state} = Loop.handle_info(tick, state)
      assert Geex.Loop.Panes.current(state.panes).hscroll > before
      state = mouse.(state, :release, 119, 2, [])

      # Grid mode: display column 5 (1-based) of line 1 is `x`; 4 is still the tab.
      grid = fn st, line ->
        st = key(st, {:alt, ?g})
        st = Enum.reduce(String.graphemes(line), st, &key(&2, {:char, &1}))
        key(st, {:key, :enter})
      end

      state = grid.(state, "x5 y1")
      assert cursor() == {0, 1}
      grid.(state, "copy x1 y1 - x4 y1")
      assert Geex.Clipboard.top() == "\t"
    end

    # The maintainer's word: Tab follows the file; Alt+1 the other kind (a tab here, ADR-0050, ADR-0051).
    test "Tab inserts a tab in a file that indents with tabs; Alt+1 a tab where Tab doesn't",
         %{
           state: state,
           dir: dir,
           buf: buf
         } do
      # setup's file has no indented line: spaces; Alt+1: a tab.
      state = key(state, {:alt, ?1})
      assert text(buf) == "\thello world\nline 2\n"
      assert cursor() == {0, 1}

      path = Path.join(dir, "t.go")
      File.write!(path, "func f() {\n\tx := 1\n}\n")
      {:ok, go} = Session.open_file(path)
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, go}, state)
      Session.set_cursor({2, 0})
      key(state, {:key, :tab})
      assert text(go) == "func f() {\n\tx := 1\n\t}\n"
      assert cursor() == {2, 1}
    end

    # Alt+1 over a selection and in the files whose Tab gives a tab: indent_lines_test.exs
    # (ADR-0050).

    test "Shift+Tab elsewhere (the tree, the edits pane, the settings view, the minibuffer) is harmless",
         %{state: state, buf: buf} do
      for st <- [
            %{state | focus: :tree, tree_shown: true},
            %{state | focus: :edits, edits_shown: true},
            key(state, {:alt, ?y}),
            key(state, {:alt, ?m})
          ] do
        key(st, {:key, :shift_tab})
      end

      assert text(buf) == "hello world\nline 2\n"
    end

    test "settings.json's tab_size sets it; anything but 2, 4 or 8 is ignored" do
      state = Loop.new_state(80, 24)
      assert Loop.apply_settings(state, %{"tab_size" => 4}).tab_size == 4
      assert Loop.apply_settings(state, %{"tab_size" => 3}).tab_size == 2
      assert Loop.apply_settings(state, %{}).tab_size == 2
    end
  end

  describe "resizing from the keyboard (18.8)" do
    alias Geex.Layout

    # 120 × 30, the tree and the edits pane shown: the tree is 30 wide, the band 9 high.
    defp panels(state), do: %{state | w: 120, h: 30, tree_shown: true, edits_shown: true}

    defp sizes(state) do
      l =
        Layout.resolve(state.w, state.h, %{
          tree: state.tree_shown,
          edits: state.edits_shown,
          tree_w: state.tree_w,
          edits_h: state.edits_h
        })

      {l.tree && l.tree.w, l.edits && l.edits.h}
    end

    test "from the editor with no split: the tree's edge and the band's top", %{state: state} do
      state = panels(state)
      assert sizes(state) == {30, 9}
      state = key(state, {:alt, :right})
      assert sizes(state) == {34, 9}
      state = key(state, {:alt, :left})
      assert sizes(state) == {30, 9}
      # Down moves the editor's bottom edge down: the band shrinks; Up grows it.
      state = key(state, {:alt, :down})
      assert sizes(state) == {30, 7}
      state = state |> key({:alt, :up}) |> key({:alt, :up})
      assert sizes(state) == {30, 11}
    end

    test "from a split pane: its own divider moves, either side", %{state: state} do
      state = %{state | w: 121, h: 30, tree_shown: false, edits_shown: false}
      # Alt+= splits side by side; the new pane (on the right) is current.
      state = key(state, {:alt, ?=})
      {:cols, _, _, before} = state.panes.split
      state = key(state, {:alt, :left})
      {:cols, _, _, ratio} = state.panes.split
      assert ratio < before

      # Back in the left pane, Right moves the same divider right.
      state = key(state, {:alt, ?>}) |> key({:alt, :right}) |> key({:alt, :right})
      {:cols, _, _, after_right} = state.panes.split
      assert after_right > ratio

      # Up and down: no split that way and no band, nothing moves.
      assert key(state, {:alt, :up}).panes.split == state.panes.split
    end

    test "from the tree, its edge; from the edits pane, the band's top", %{state: state} do
      state = panels(state)
      state = key(%{state | focus: :tree}, {:alt, :right})
      assert sizes(state) == {34, 9}
      assert key(state, {:alt, :up}) |> sizes() == {34, 9}

      state = key(%{state | focus: :edits}, {:alt, :up})
      assert sizes(state) == {34, 11}
    end

    test "Alt+I/J/K/L move the cursor, Shift or not: only Alt with an arrow resizes", %{
      state: state
    } do
      # Alt+Shift+W/A/S/D resized until 2026-11-11 (the maintainer: "alt arrow keys is enough").
      state = panels(state)
      state = key(state, {:alt, ?l})
      assert cursor() == {0, 1}
      state = key(state, {:alt, ?L})
      assert cursor() == {0, 2}
      state = key(state, {:alt, ?J})
      assert cursor() == {0, 1}
      assert sizes(state) == {30, 9}
    end
  end
end
