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
      # The header names the file; the rendered rows start under it.
      assert Enum.at(rows, 1) =~ ~r/│ a\.md/
      assert Enum.at(rows, 2) =~ ~r/│Title/
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
      state = key(state, {:alt, ?p})
      assert state.panes.pane == 2
      state = Loop.toggle_preview(state)
      assert Panes.ids(state.panes) == [1]
      assert state.panes.pane == 1
      assert Panes.current(state.panes).view == :source
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
    test "Alt+K on the last source tab is refused while unsaved, the preview open elsewhere",
         ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      state = key(state, {:char, "x"})
      state = key(state, {:alt, ?k})
      assert state.notice =~ "unsaved"
      assert Panes.current(state.panes).buffer == buf
      assert preview_tab(state) != nil
    end

    test "Alt+K on the last source tab closes the file and its previews", ctx do
      {state, buf} = start(ctx.dir)
      ref = Process.monitor(buf)
      state = Loop.toggle_preview(state)
      state = key(state, {:alt, ?k})
      assert_receive {:DOWN, ^ref, :process, ^buf, _}
      assert preview_tab(state) == nil
    end

    test "Alt+K on a preview closes only it, never refused, the file staying open", ctx do
      {state, buf} = start(ctx.dir, 24)
      state = key(state, {:char, "x"})
      state = Loop.toggle_preview(state)
      assert Panes.preview?(Panes.current(state.panes))
      state = key(state, {:alt, ?k})
      assert preview_tab(state) == nil
      assert Process.alive?(buf)
      assert Panes.current(state.panes).buffer == buf
    end
  end

  describe "F3: opening the file from a preview's pane lands on text" do
    test "`open` adds a source tab where the pane had only the preview", ctx do
      {state, buf} = start(ctx.dir)
      state = Loop.toggle_preview(state)
      state = key(state, {:alt, ?p})
      assert state.panes.pane == 2
      state = type(state, "open " <> Path.join(ctx.dir, "a.md"))
      assert %{buffer: ^buf, view: :source} = Panes.current(state.panes)
      assert state.panes.pane == 2
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
            {:char, "x"},
            {:key, :enter},
            {:key, :backspace},
            {:alt, ?z},
            {:alt, ?v},
            {:alt, ?u},
            {:alt, ?h},
            {:alt, ?b},
            {:alt, ?x},
            {:alt, ?g}
          ] do
        s = key(state, event)
        assert text(buf) == before, inspect(event)
        assert s.notice =~ "read-only", inspect(event)
        assert s.selection == nil
      end
    end

    test "typed verbs and `line N` are gated; the allowed ones work", %{state: state, buf: buf} do
      before = text(buf)

      for verb <- ["undo", "paste", "revert", "select all", "line 3", "|cat"] do
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
      state = key(state, {:alt, ?s})
      assert scroll.(state) == 2
      state = key(state, {:alt, ?w}) |> key({:key, :up})
      assert scroll.(state) == 0
      state = key(state, {:key, :end})
      bottom = scroll.(state)
      assert bottom > 50
      state = key(state, {:key, :down})
      assert scroll.(state) == bottom
      assert scroll.(key(state, {:key, :home})) == 0
    end

    test "an edit above the reader keeps their row; the user's save scrolls to its line", ctx do
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

      # Take it in, put the cursor on para 10's line and save: the preview goes there.
      state = key(state, {:alt, ?j})
      Session.set_cursor({22, 0})
      state = key(state, {:ctrl, ?o})

      state =
        Stream.repeatedly(fn -> :ok end)
        |> Enum.reduce_while(state, fn _, s ->
          assert_receive {:geex_preview, ^buf, msg}, 3_000
          {:noreply, s} = Loop.handle_info({:geex_preview, buf, msg}, s)
          if msg.anchor, do: {:halt, s}, else: {:cont, s}
        end)

      lines = state.previews[buf].rows |> Map.values() |> hd() |> Map.fetch!(:lines)
      assert elem(lines, Panes.shown(state.panes, 2).scroll) == 22
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

  defp insert(line, col, text) do
    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: line, col: col, text: text})
    Geex.Command.put_meta(cmd, Geex.Command.Meta.human())
  end
end
