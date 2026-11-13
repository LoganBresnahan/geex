defmodule Geex.Loop.PreviewTabsTest do
  # Preview tabs in the loop and the gate on the active buffer (ADR-0043 §1), through the loop's
  # own handle_info/2 with no terminal, not reachable from the UI yet (`Loop.toggle_preview/1`
  # stands in for the key). The test process plays the loop, so the preview process's renders
  # and Session's events arrive here and are handed to the loop. Each `describe` is one of the
  # review's failure cases (doc/research/adr-0043-review.md). Uses the global Session and
  # Renderer, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Screen, Session}
  alias Geex.Loop.Panes
  alias Geex.Markdown.Preview

  @doc_text "# Title\n\n" <> Enum.map_join(1..60, "\n\n", &"para #{&1}") <> "\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_preview_tabs_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.md"), @doc_text)
    File.write!(Path.join(dir, "b.txt"), "b\n")
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp type(state, text) do
    state = key(state, {:alt, ?m})
    state = Enum.reduce(String.graphemes(text), state, &key(&2, {:char, &1}))
    key(state, {:key, :enter})
  end

  defp open(state, dir, name) do
    {:ok, pid} = Session.open_file(Path.join(dir, name))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid}
  end

  defp start(dir, w \\ 100) do
    state = %{Loop.new_state(w, 24) | tree_shown: false, edits_shown: false}
    open(state, dir, "a.md")
  end

  # Hand the loop the preview's next render for `buf`.
  defp rendered(state, buf) do
    assert_receive {:geex_preview, ^buf, %{rows: rows}} = msg when rows != %{}, 3_000
    {:noreply, state} = Loop.handle_info(msg, state)
    state
  end

  defp text(buf), do: Buffer.get_text(buf)
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  defp frame(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    %Screen{} = screen = Geex.Renderer.current()

    rows =
      for y <- 0..(screen.h - 1),
          do: Enum.map_join(0..(screen.w - 1), &Screen.get_cell(screen, &1, y).char)

    {state, rows}
  end

  defp preview_tab(state), do: Enum.find_value(Panes.ids(state.panes), &find_preview(state, &1))

  defp find_preview(state, id),
    do: Enum.find(state.panes.panes[id].tabs, &Panes.preview?/1)

  describe "F8/F21: where a preview opens, and the source keeps focus" do
    test "with one pane, beside it: the source's pane stays current, its selection kept", ctx do
      {state, buf} = start(ctx.dir)
      Session.set_cursor({4, 1})
      sel = Geex.Selection.new({4, 0}) |> Geex.Selection.extend({4, 1})
      state = %{state | selection: sel, goal: 1}
      state = Loop.toggle_preview(state)

      assert Panes.ids(state.panes) == [1, 2]
      assert state.panes.pane == 1
      assert Panes.current(state.panes).view == :source
      assert Panes.shown(state.panes, 2) == Panes.preview_tab(buf, 1)
      assert {state.selection, state.goal} == {sel, 1}
      assert cursor() == {4, 1}
      assert {:ok, _} = Preview.lookup(buf)

      state = rendered(state, buf)
      {_state, rows} = frame(state)
      # The header names the file; the rendered rows start under it, a column in from the border.
      assert Enum.at(rows, 1) =~ ~r/│ a\.md/
      assert Enum.at(rows, 2) =~ ~r/│ Title/
    end

    test "where a split has no room, in the source's own pane after it, shown there", ctx do
      {state, buf} = start(ctx.dir, 24)
      state = Loop.toggle_preview(state)
      assert Panes.ids(state.panes) == [1]
      assert Enum.map(state.panes.panes[1].tabs, & &1.view) == [:source, :preview]
      assert Panes.current(state.panes) == Panes.preview_tab(buf, 1)
    end

    test "with more panes, in the next one after its shown tab; closing shows that tab again",
         ctx do
      {state, buf} = start(ctx.dir)
      {state, b} = open(state, ctx.dir, "b.txt")
      # Pane 1: a.md, b.txt (b shown). Split: pane 2 shows b; open a.md there too.
      state = key(state, {:alt, ?=})
      {state, ^buf} = open(state, ctx.dir, "a.md")
      assert state.panes.pane == 2
      state = Loop.toggle_preview(state)

      # Opened from pane 2, so in pane 1 (wrapping), after its shown tab (b.txt).
      assert state.panes.pane == 2
      assert Panes.current(state.panes).buffer == buf

      assert Enum.map(state.panes.panes[1].tabs, &{&1.buffer, &1.view}) ==
               [{buf, :source}, {b, :source}, {buf, :preview}]

      state = Loop.toggle_preview(state)
      assert Panes.shown(state.panes, 1).buffer == b
    end
  end

  describe "the toggle" do
    test "from a source tab it closes every preview of the file; the process stops", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      {:ok, pid} = Preview.lookup(buf)
      ref = Process.monitor(pid)
      state = Loop.toggle_preview(state)
      assert preview_tab(state) == nil
      assert Panes.ids(state.panes) == [1]
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    test "from a preview it closes that preview and focuses the pane it came from", ctx do
      {state, _buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      state = key(state, {:alt, ?>})
      assert state.panes.pane == 2
      state = Loop.toggle_preview(state)
      assert Panes.ids(state.panes) == [1]
      assert state.panes.pane == 1
      assert Panes.current(state.panes).view == :source
    end

    test "the typed verb `preview` and the palette's entry do the same", ctx do
      {state, buf} = start(ctx.dir)
      state = type(state, "preview")
      assert Panes.shown(state.panes, 2) == Panes.preview_tab(buf, 1)
      # Typed again from the source it closes it; the palette's entry is the same action.
      state = type(state, "preview")
      assert preview_tab(state) == nil
    end

    test "a file that isn't markdown has no preview", ctx do
      {state, _a} = start(ctx.dir)
      {state, _b} = open(state, ctx.dir, "b.txt")
      state = Loop.toggle_preview(state)
      assert preview_tab(state) == nil
      assert state.notice =~ "markdown"
    end
  end

  describe "F2/F20: closing" do
    test "Alt+W on the last source tab is refused while unsaved, the preview open elsewhere",
         ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      state = key(state, {:char, "x"})
      state = key(state, {:alt, ?w})
      assert state.notice =~ "unsaved"
      assert Panes.current(state.panes).buffer == buf
      assert preview_tab(state) != nil
    end

    test "Alt+W on the last source tab closes the file and its previews", ctx do
      {state, buf} = start(ctx.dir)
      ref = Process.monitor(buf)
      state = Loop.toggle_preview(state)
      state = key(state, {:alt, ?w})
      assert_receive {:DOWN, ^ref, :process, ^buf, _}
      assert preview_tab(state) == nil
    end

    test "Alt+W on a preview closes only it, never refused, the file staying open", ctx do
      {state, buf} = start(ctx.dir, 24)
      state = key(state, {:char, "x"})
      state = Loop.toggle_preview(state)
      assert Panes.preview?(Panes.current(state.panes))
      state = key(state, {:alt, ?w})
      assert preview_tab(state) == nil
      assert Process.alive?(buf)
      assert Panes.current(state.panes).buffer == buf
    end
  end

  describe "F3: opening the file from a preview's pane lands on text" do
    test "`open` adds a source tab where the pane had only the preview", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      state = key(state, {:alt, ?>})
      assert state.panes.pane == 2
      state = type(state, "open " <> Path.join(ctx.dir, "a.md"))
      assert %{buffer: ^buf, view: :source} = Panes.current(state.panes)
      assert state.panes.pane == 2
    end
  end

  describe "ADR-0051: the pane keys work from a preview" do
    test "Alt+<, Alt+> and their typed names move out of it, never refused", ctx do
      {state, _buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      # Alt+> moves into the preview's pane, beside the source.
      state = key(state, {:alt, ?>})
      assert state.panes.pane == 2 and Panes.preview?(Panes.current(state.panes))

      for event <- [{:alt, ?<}, {:alt, ?>}, {:typed, "pane-prev"}, {:typed, "pane-next"}] do
        s =
          case event do
            {:typed, verb} -> type(state, verb)
            key_event -> key(state, key_event)
          end

        refute s.notice && s.notice =~ "read-only", inspect(event)
        assert s.panes.pane == 1, inspect(event)
      end
    end
  end

  describe "F4/F7: a preview has no cursor" do
    test "entering and leaving one leaves Session's cursor as it was; a frame draws it", ctx do
      {state, _buf} = start(ctx.dir, 24)
      Session.set_cursor({6, 2})
      state = Loop.toggle_preview(state)
      assert cursor() == {6, 2}
      {state, _rows} = frame(state)
      state = key(state, {:alt, ?,})
      assert Panes.current(state.panes).view == :source
      assert cursor() == {6, 2}
    end
  end

  describe "F1/F22: what reaches the active buffer while a preview is current" do
    setup ctx do
      {state, buf} = start(ctx.dir, 24)
      {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "z"))
      state = Loop.toggle_preview(state)
      %{state: state, buf: buf}
    end

    test "typing, edit keys, undo, paste and grid change nothing and say why", %{
      state: state,
      buf: buf
    } do
      before = text(buf)

      for event <- [
            {:key, :delete},
            {:char, "x"},
            {:key, :enter},
            {:key, :backspace},
            {:alt, ?z},
            {:alt, ?v},
            {:alt, ?r},
            {:alt, ?s},
            {:alt, ?a},
            {:alt, ?x},
            {:alt, ?g},
            # The editing keys (ADR-0052).
            {:alt, ?2},
            {:alt, ?7},
            {:alt, ?8},
            {:alt, ?9},
            {:alt, ?/},
            {:alt, ?\\}
          ] do
        s = key(state, event)
        assert text(buf) == before, inspect(event)
        assert s.notice =~ "read-only", inspect(event)
        assert s.selection == nil
      end
    end

    test "typed verbs and `line N` are gated; the allowed ones work", %{state: state, buf: buf} do
      before = text(buf)

      for verb <- [
            "undo",
            "paste",
            "revert",
            "select-all",
            "line 3",
            "|cat",
            "duplicate",
            "comment"
          ] do
        s = type(state, verb)
        assert text(buf) == before, verb
        assert s.notice =~ "read-only", verb
      end

      s = type(state, "tree")
      assert s.tree_shown

      s = type(state, "save")
      refute Buffer.status(buf).dirty
      assert s.notice == nil or not (s.notice =~ "read-only")
    end

    test "Ctrl-O saves the file from the preview", %{state: state, buf: buf} do
      _ = key(state, {:ctrl, ?o})
      refute Buffer.status(buf).dirty
    end
  end

  describe "scrolling and keeping the reader's place" do
    test "the scroll keys move a preview by rows", ctx do
      {state, buf} = start(ctx.dir, 24)
      state = Loop.toggle_preview(state) |> rendered(buf)
      scroll = fn s -> Panes.current(s.panes).scroll end
      state = key(state, {:key, :down})
      assert scroll.(state) == 1
      state = key(state, {:alt, ?k})
      assert scroll.(state) == 2
      state = key(state, {:alt, ?i}) |> key({:key, :up})
      assert scroll.(state) == 0
      state = key(state, {:key, :end})
      bottom = scroll.(state)
      assert bottom > 50
      state = key(state, {:key, :down})
      assert scroll.(state) == bottom
      assert scroll.(key(state, {:key, :home})) == 0

      # Alt+H and Alt+; run `line start` and `line end` too, which a preview reads as its top
      # and bottom (ADR-0047 §4).
      state = key(state, {:alt, ?h})
      assert scroll.(state) == 0
      assert scroll.(key(state, {:alt, ?;})) == bottom
    end

    test "an edit above the reader keeps their row, and so does the user's save", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf)
      # Scroll the preview to "para 30".
      lines = state.previews[buf].rows |> Map.values() |> hd() |> Map.fetch!(:lines)
      at = Enum.find_index(Tuple.to_list(lines), &(&1 == 60))
      state = %{state | panes: Panes.update_shown(state.panes, 2, &%{&1 | scroll: at})}

      # An agent writes two lines at the top of the file: the reader stays on para 30.
      File.write!(Path.join(ctx.dir, "a.md"), "intro\n\n" <> @doc_text)
      Buffer.disk_changed(buf, File.read!(Path.join(ctx.dir, "a.md")))
      state = rendered(state, buf)
      lines = state.previews[buf].rows |> Map.values() |> hd() |> Map.fetch!(:lines)
      assert elem(lines, Panes.shown(state.panes, 2).scroll) == 62

      # Take it in, then edit para 10's line from the source and save: the preview re-renders and
      # stays where the reader was (para 30, line 62), not on the saved line.
      state = key(state, {:alt, ?d})
      Session.set_cursor({22, 0})
      state = key(state, {:char, "X"}) |> key({:ctrl, ?o})
      assert_receive {:geex_preview, ^buf, %{rows: rows} = msg} when rows != %{}, 3_000
      {:noreply, state} = Loop.handle_info({:geex_preview, buf, msg}, state)
      # Every render the save brings, not just the first.
      state = drain_renders(state, buf)
      assert "X" <> _ = Buffer.get_text(buf) |> String.split("\n") |> Enum.at(22)
      lines = state.previews[buf].rows |> Map.values() |> hd() |> Map.fetch!(:lines)
      assert elem(lines, Panes.shown(state.panes, 2).scroll) == 62
    end

    test "the preview is told the tab's text width", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      {:ok, pid} = Preview.lookup(buf)
      _ = rendered(state, buf)
      assert [w] = :sys.get_state(pid).wanted
      assert w in 40..50
    end
  end

  describe "the slice-4 review: widths, stale rows, the scroll bar's column, a failed jump" do
    defp resize(state, rows, cols) do
      {:noreply, state} = Loop.handle_info({:geex_io, {:resize, rows, cols}}, state)
      state
    end

    defp top_line(state, buf) do
      tab = Panes.shown(state.panes, 2)
      lines = state.previews[buf].rows[tab.rows_w].lines
      elem(lines, tab.scroll)
    end

    test "a width change keeps the reader's place, before and after its rows arrive", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf)
      %{rows_w: w1} = tab = Panes.shown(state.panes, 2)
      at = Enum.find_index(Tuple.to_list(state.previews[buf].rows[w1].lines), &(&1 == 60))
      state = %{state | panes: Panes.update_shown(state.panes, 2, &%{&1 | scroll: at})}
      assert tab.rows_w == w1

      # Narrower: until its own rows arrive the tab draws the rows its scroll indexes.
      {state, rows} = state |> resize(24, 70) |> frame()
      assert Enum.at(rows, 2) =~ "para 30"
      state = rendered(state, buf)
      assert %{rows_w: w2} = Panes.shown(state.panes, 2)
      assert w2 < w1
      assert top_line(state, buf) == 60
      # The rows of a width no tab shows any more are let go.
      assert Map.keys(state.previews[buf].rows) == [w2]
    end

    test "a render whose remap starts from other rows than the tab's isn't applied to it", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf)
      %{rows_w: w} = Panes.shown(state.panes, 2)
      at = Enum.find_index(Tuple.to_list(state.previews[buf].rows[w].lines), &(&1 == 60))
      state = %{state | panes: Panes.update_shown(state.panes, 2, &%{&1 | scroll: at})}

      # A render from a text this tab never had: its line map means nothing here.
      {:ok, g} = Geex.Markdown.handles()
      {:ok, parsed} = Geex.Markdown.parse("x\n\n" <> @doc_text, g)
      rows = Geex.Markdown.rows(parsed, w)
      lines = Geex.Markdown.Place.lines(rows, parsed.text)
      shift = List.to_tuple(Enum.map(0..200, &(&1 + 50)))

      msg = %{
        render: 99,
        rows: %{w => %{rows: rows, lines: lines}},
        status: :ok,
        remap: shift,
        hash: "new",
        from: "some other text",
        languages: []
      }

      {:noreply, state} = Loop.handle_info({:geex_preview, buf, msg}, state)
      assert top_line(state, buf) == 60
    end

    test "rows never reach the scroll bar's column", ctx do
      File.write!(Path.join(ctx.dir, "short.md"), String.duplicate("x", 300) <> "\n")
      state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
      {state, buf} = open(state, ctx.dir, "short.md")
      state = Loop.toggle_preview(state) |> rendered(buf)
      # Narrower: the wider rows are drawn until the narrow ones come, and must stop short of
      # the pane's last column.
      {_state, rows} = state |> resize(24, 70) |> frame()
      for y <- 2..6, do: assert(String.last(Enum.at(rows, y)) == " ", inspect(Enum.at(rows, y)))
    end

    test "an output-pane jump whose open fails leaves the file's cursor alone", ctx do
      locked = Path.join(ctx.dir, "locked.md")
      File.write!(locked, "x\n")
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o644) end)

      {state, _buf} = start(ctx.dir, 24)
      Session.set_cursor({2, 1})
      state = Loop.toggle_preview(state)
      state = type(state, "!echo locked.md:40:3")
      state = ran(state)
      state = key(state, {:key, :enter})
      assert state.notice =~ "couldn't open"
      assert cursor() == {2, 1}
    end
  end

  describe "slice 5: the keys, the glyph, links, the scroll bar and the status line" do
    defp mouse(state, action, x, y) do
      m = %{action: action, button: :left, x: x, y: y, mods: []}
      {:noreply, state} = Loop.handle_info({:geex_io, {:mouse, m}}, %{state | click: nil})
      state
    end

    test "Alt+P toggles from the source and from the preview; panels leave it alone", ctx do
      {state, buf} = start(ctx.dir)
      state = key(state, {:alt, ?p})

      assert Panes.shown(state.panes, 2) |> Map.take([:buffer, :view]) == %{
               buffer: buf,
               view: :preview
             }

      assert state.panes.pane == 1

      state = key(state, {:alt, ?>}) |> key({:alt, ?p})
      assert Panes.ids(state.panes) == [1]
      assert state.panes.pane == 1

      for focus <- [:tree, :edits] do
        s = %{state | tree_shown: true, edits_shown: true, focus: focus}
        s = key(s, {:alt, ?p})
        assert s.focus == focus and preview_tab(s) == nil
      end
    end

    test "the glyph is on a markdown file's tab, in the tab's colours; a click on it toggles",
         ctx do
      {state, buf} = start(ctx.dir)
      {state, _b} = open(state, ctx.dir, "b.txt")
      {state, rows} = frame(state)
      bar = hd(rows)
      assert bar =~ ~r/ 1 a\.md ◫ × /
      refute bar =~ ~r/b\.txt ◫/

      # A click on a.md's glyph shows that tab, then toggles its preview.
      x = :binary.match(bar, "◫") |> elem(0) |> then(&String.length(binary_part(bar, 0, &1)))
      state = mouse(state, :press, x, 0)
      assert Panes.current(state.panes).buffer == buf
      assert %{view: :preview} = Panes.shown(state.panes, 2)

      {_state, rows} = frame(state)
      # The preview's own tab has no glyph: its × closes it.
      assert hd(rows) =~ ~r/│ 1 a\.md × /
      # On the source tab the glyph is drawn as its × is.
      screen = Geex.Renderer.current()
      gx = String.length(binary_part(hd(rows), 0, elem(:binary.match(hd(rows), "◫"), 0)))
      glyph = Screen.get_cell(screen, gx, 0)
      cross = Screen.get_cell(screen, gx + 2, 0)
      assert {glyph.char, cross.char} == {"◫", "×"}
      assert {glyph.fg, glyph.bg, glyph.attrs} == {cross.fg, cross.bg, cross.attrs}
    end

    test "with markdown_inline missing there is no glyph, and the verb says what to install",
         ctx do
      dir = Geex.Installed.dir(:grammar, "markdown_inline")
      File.rename!(dir, dir <> ".aside")
      Geex.Installed.refresh()

      on_exit(fn ->
        File.rename(dir <> ".aside", dir)
        Geex.Installed.refresh()
      end)

      {state, _buf} = start(ctx.dir)
      {state, rows} = frame(state)
      refute hd(rows) =~ "◫"
      state = type(state, "preview")
      assert state.notice == "Markdown preview needs Markdown inline installed (Alt+Y)"
      state = key(state, {:alt, ?y})

      assert Enum.at(Geex.Loop.Settings.rows(state.settings, %{}), state.settings.sel).name ==
               "markdown_inline"
    end

    test "a click on a relative markdown link opens it in the pane the preview came from", ctx do
      File.write!(
        Path.join(ctx.dir, "a.md"),
        "# A\n\nSee [the other](b.md) or [web](https://x.y).\n"
      )

      File.write!(Path.join(ctx.dir, "b.md"), "# B\n")
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf)
      state = key(state, {:alt, ?>})
      assert state.panes.pane == 2
      {state, rows} = frame(state)
      # The preview's half of each row: right of the divider.
      right = fn row -> row |> String.split("│", parts: 2) |> List.last() end
      y = Enum.find_index(rows, &(right.(&1) =~ "the other"))
      line = Enum.at(rows, y)
      offset = String.length(hd(String.split(line, "│", parts: 2))) + 1
      x = offset + String.length(hd(String.split(right.(line), "the other"))) + 2

      # The web link: nothing opens.
      wx = offset + String.length(hd(String.split(right.(line), "web"))) + 1
      s = mouse(state, :press, wx, y)
      assert Panes.current(s.panes).view == :preview

      state = mouse(state, :press, x, y)
      assert state.panes.pane == 1
      assert %{view: :source, buffer: b} = Panes.current(state.panes)
      assert Buffer.status(b).path == Path.join(ctx.dir, "b.md")
    end

    test "the preview's scroll bar takes a press and a drag", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf)
      {state, rows} = frame(state)
      x = String.length(hd(rows)) - 1
      state = mouse(state, :press, x, 22)
      bottom = Panes.shown(state.panes, 2).scroll
      assert bottom > 50
      state = mouse(state, :drag, x, 3)
      assert Panes.shown(state.panes, 2).scroll < 10
      # Neither moved the file's cursor nor selected.
      assert cursor() == {0, 0} and state.selection == nil
    end

    test "with a preview current the status line names the file and says preview, no position",
         ctx do
      {state, _buf} = start(ctx.dir, 24)
      state = Loop.toggle_preview(state)
      {_state, rows} = frame(state)
      status = List.last(rows)
      assert status =~ "a.md"
      assert status =~ "preview"
      refute status =~ ~r/\d+:\d+/
    end
  end

  describe "the slice-5 review" do
    defp press(state, action, x, y) do
      m = %{action: action, button: :left, x: x, y: y, mods: []}
      {:noreply, state} = Loop.handle_info({:geex_io, {:mouse, m}}, %{state | click: nil})
      state
    end

    test "2: Alt+P's refusal is drawn: the key queues a repaint", ctx do
      {state, _a} = start(ctx.dir)
      {state, _b} = open(state, ctx.dir, "b.txt")
      {state, _rows} = frame(state)
      flush_repaints()
      state = key(state, {:alt, ?p})
      assert state.notice =~ "markdown"
      assert_received :repaint
    end

    test "3: a link to a file with a space in its name opens it (%20 decoded)", ctx do
      File.write!(Path.join(ctx.dir, "a.md"), "# A\n\nSee [it](my%20file.md).\n")
      File.write!(Path.join(ctx.dir, "my file.md"), "# Spaced\n")
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf) |> key({:alt, ?>})
      {state, rows} = frame(state)
      y = Enum.find_index(rows, &(&1 |> String.split("│", parts: 2) |> List.last() =~ "See it"))
      line = Enum.at(rows, y)
      offset = String.length(hd(String.split(line, "│", parts: 2))) + 1

      x =
        offset +
          String.length(hd(String.split(List.last(String.split(line, "│", parts: 2)), "it.")))

      state = press(state, :press, x, y)
      assert %{view: :source, buffer: b} = Panes.current(state.panes)
      assert Buffer.status(b).path == Path.join(ctx.dir, "my file.md")
    end

    test "10: a ~/ link is relative to the linking file, not $HOME", ctx do
      File.mkdir_p!(Path.join(ctx.dir, "~"))
      File.write!(Path.join(ctx.dir, "~/t.md"), "# Tilde\n")
      File.write!(Path.join(ctx.dir, "a.md"), "# A\n\nSee [it](~/t.md).\n")
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf) |> key({:alt, ?>})
      {state, rows} = frame(state)
      y = Enum.find_index(rows, &(&1 |> String.split("│", parts: 2) |> List.last() =~ "See it"))
      line = Enum.at(rows, y)
      offset = String.length(hd(String.split(line, "│", parts: 2))) + 1

      x =
        offset +
          String.length(hd(String.split(List.last(String.split(line, "│", parts: 2)), "it.")))

      state = press(state, :press, x, y)
      assert %{view: :source, buffer: b} = Panes.current(state.panes)
      assert Buffer.status(b).path == Path.join(ctx.dir, "~/t.md")
    end

    test "4: a first render that can't parse says what to update, and Alt+Y opens on it", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      assert_receive {:geex_preview, ^buf, _}, 3_000

      msg = %{
        render: 1,
        rows: %{},
        status: {:unavailable, :update},
        remap: nil,
        hash: nil,
        from: nil,
        languages: []
      }

      {:noreply, state} = Loop.handle_info({:geex_preview, buf, msg}, state)
      assert state.notice == "Markdown preview needs an update (Alt+Y)"
      assert hd(state.hinted) in Geex.Markdown.grammars()
    end

    test "5: Page Up/Down outside a preview leave a hold, the notice and an armed save alone",
         ctx do
      {state, _buf} = start(ctx.dir)
      tab = Panes.current(state.panes)
      held = %{tab | hold: {{0, 0}, {50, 20}}, scroll: 7}
      state = %{state | panes: Panes.update_current(state.panes, fn _ -> held end)}
      state = %{state | notice: "a notice", save_armed: true}

      for event <- [{:key, :page_up}, {:key, :page_down}] do
        s = key(state, event)
        assert Panes.current(s.panes) == held
        assert {s.notice, s.save_armed} == {"a notice", true}
      end
    end

    test "7: grid mode's submit doesn't reach the buffer behind a preview", ctx do
      {state, buf} = start(ctx.dir, 24)
      state = Loop.toggle_preview(state)
      before = text(buf)
      state = %{state | minibuffer: Geex.Minibuffer.open(:grid)}
      state = Enum.reduce(String.graphemes("cut x1 y1 - x3 y1"), state, &key(&2, {:char, &1}))
      state = key(state, {:key, :enter})
      assert text(buf) == before
      assert state.notice =~ "read-only"
    end

    test "8: a glyph click on the tab already shown keeps the selection", ctx do
      {state, _buf} = start(ctx.dir)
      {state, rows} = frame(state)
      sel = Geex.Selection.new({2, 0}) |> Geex.Selection.extend({2, 3})
      state = %{state | selection: sel, goal: 3}
      bar = hd(rows)
      x = :binary.match(bar, "◫") |> elem(0) |> then(&String.length(binary_part(bar, 0, &1)))
      state = press(state, :press, x, 0)
      assert %{view: :preview} = Panes.shown(state.panes, 2)
      assert {state.selection, state.goal} == {sel, 3}
    end

    test "9: the preview's bar keeps the grabbed cell under the pointer, as the source bars do",
         ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state) |> rendered(buf)
      {state, rows} = frame(state)
      x = String.length(hd(rows)) - 1
      # The thumb is at the top, a few cells long: a press on its second cell doesn't jump.
      assert Enum.at(rows, 3) |> String.last() == "┃"
      state = press(state, :press, x, 3)
      assert Panes.shown(state.panes, 2).scroll == 0
      # Dragged down a row, the thumb moves a row, the grabbed cell staying under the pointer.
      state = press(state, :drag, x, 4)
      s1 = Panes.shown(state.panes, 2).scroll
      assert s1 > 0
      state = press(state, :drag, x, 5)
      assert Panes.shown(state.panes, 2).scroll > s1
    end
  end

  defp drain_renders(state, buf) do
    receive do
      {:geex_preview, ^buf, msg} ->
        {:noreply, state} = Loop.handle_info({:geex_preview, buf, msg}, state)
        drain_renders(state, buf)
    after
      700 -> state
    end
  end

  defp flush_repaints do
    receive do
      :repaint -> flush_repaints()
    after
      0 -> :ok
    end
  end

  defp ran(%{shell: nil} = state), do: state

  defp ran(%{shell: %{pid: pid}} = state) do
    assert_receive {:geex_shell, ^pid, _} = msg, 10_000
    {:noreply, state} = Loop.handle_info(msg, state)
    ran(state)
  end

  test "Page Up/Down change nothing outside a preview", ctx do
    {state, buf} = start(ctx.dir)
    before = text(buf)
    Session.set_cursor({4, 0})

    for event <- [{:key, :page_up}, {:key, :page_down}] do
      s = key(state, event)
      assert {text(buf), cursor(), s.panes} == {before, {4, 0}, state.panes}

      m = state |> key({:alt, ?m}) |> key(event)
      assert Geex.Minibuffer.value(m.minibuffer) == ""

      shown = %{state | tree_shown: true, edits_shown: true}
      for focus <- [:tree, :edits], do: assert(key(%{shown | focus: focus}, event).focus == focus)

      settings = state |> key({:alt, ?y}) |> key(event)
      assert settings.settings != nil
    end
  end

  defp insert(line, col, text) do
    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: line, col: col, text: text})
    Geex.Command.put_meta(cmd, Geex.Command.Meta.human())
  end
end
