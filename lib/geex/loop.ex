defmodule Geex.Loop do
  @moduledoc """
  The interactive editor loop ([ADR-0024](../../doc/adr/0024-tui-core-extractable.md))
  — the **event-driven** frame owner.

  It sits *above* `Geex.Session` and **drives** the generic TUI core from editor
  state. Session owns the active buffer and its cursor; `Geex.Buffer` owns the text + history.
  The loop owns the file panes and their tabs (`Geex.Loop.Panes`, ADR-0038: every other tab's
  cursor, every tab's scroll) and the event→repaint cycle:

      Geex.TerminalIO          (resize, keys)        ┐
      Geex.Session             (active-buffer change) ├─▶ mark dirty ─▶ coalesce
      Geex.Buffer              (text change)          │        │
      Geex.Highlight.Reactor   (overlay ready)        ┘        ▼
                                          Geex.Highlight.Paint.to_screen + cursor
                                                               │
                                          Geex.Renderer.flush/2 (cells + hardware cursor)

  **Event-driven:** a frame is rebuilt only when something changes, and a burst of
  events coalesces to a single repaint (`schedule_repaint/1` sets a flag and posts
  one `:repaint` to self; further events while it is pending are folded in).

  Both halves are live: it paints the active buffer + the reactor's overlay, and
  routes keys to `%Command{}` edits on the one shared path (ADR-0003) or view-local
  cursor moves (via `Geex.Loop.Keymap`). The frame reserves its **bottom row** for a
  status line (buffer label · `line:col` · dirty flag); the buffer renders into the
  rows above, and a **scrolloff** margin keeps the cursor off the viewport edges. The
  next chrome slice is the line-number gutter — a left-column analog of the status
  row that shares the same viewport-region math.

  Needs a real terminal (`Geex.TerminalIO` over `:prim_tty`), so it starts only
  when the terminal is enabled — off under `mix test`, like `Geex.TerminalIO`. Its
  pure render core (`cursor_xy/3`, `frame/7`) is testable without a terminal.
  """

  use GenServer
  require Logger

  alias Geex.{
    Buffer,
    Cell,
    Clipboard,
    Command,
    Coord,
    Dispatch,
    Edits,
    Finder,
    Fuzzy,
    Highlight,
    Layout,
    Tree,
    Minibuffer,
    Reconcile,
    Renderer,
    Screen,
    Selection,
    Session,
    TerminalIO,
    Theme,
    Width
  }

  alias Geex.Buffer.Doc
  alias Geex.Command.Catalog
  alias Geex.Command.Meta
  alias Geex.Commands.{Delete, Insert, Replace}
  alias Geex.Highlight.{Paint, Reactor}
  alias Geex.Loop.{EditsPane, Keymap, Mouse, Panes, Settings, TabBar, Verbs}
  alias Geex.MCP.ViewActions

  # Rows of context kept between the cursor and the top/bottom of the viewport
  # (vim's `scrolloff`). A fixed default for now; a future per-user config knob
  # (ADR-0025). Clamped to half the window so the bands never cross.
  @scrolloff 3

  # Columns of context kept between the cursor and the left/right of the text area
  # (vim's `sidescrolloff`) — the horizontal analogue, applied via the same
  # `scroll_for/4` along the column axis.
  @hscrolloff 8

  # Most candidate rows the command palette (ADR-0028 §3) shows at once; a longer match list
  # scrolls to keep the highlighted row in view. The column the command name is padded to.
  @palette_rows 8
  @palette_name_col 14

  # The most files the finder (Alt+O) keeps for a query: far more than the popup shows at once.
  @finder_limit 100

  # The minibuffer modes with a candidate popup.
  @pickers [:palette, :buffers, :files]

  # The status line's mark for a buffer behind its file on disk; a click on it fast-forwards.
  @behind "behind disk (Alt+J)"

  ## Public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Pure render core (no terminal needed — unit-tested directly)

  @doc """
  The on-screen `{x, y}` of the buffer cursor. `cursor` is `{line, col}` in
  **grapheme** coordinates (Doc semantics); `x` accounts for **display width** (a
  wide glyph before the cursor shifts it by two — [`Geex.Width`](`Geex.Width`)) and
  `y` is the buffer line minus `scroll`.
  """
  @spec cursor_xy(String.t(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()) ::
          {non_neg_integer(), integer()}
  def cursor_xy(text, {line, col}, scroll) do
    x =
      text
      |> line_at(line)
      |> String.graphemes()
      |> Enum.take(col)
      |> Enum.reduce(0, fn g, acc -> acc + Width.cells(g) end)

    {x, line - scroll}
  end

  @doc """
  The next `Geex.Screen`, the cursor's on-screen position, and the horizontal scroll, for
  the given inputs (the previous `hscroll` carries the column offset between frames).

  Reserves a **line-number gutter** of `gutter_width/1` columns on the left: the text is
  painted inset by that width, the gutter drawn over the left columns (1-based logical line
  numbers, [ADR-0027](../../doc/adr/0027-grid-command-addressing.md) — the number you read
  *is* the command grid's `y`). The text area `[gutter, w)` also scrolls **horizontally** to
  keep the cursor's column visible (the same `scroll_for/4` along the column axis, with an
  `@hscrolloff` margin); the cursor's `x` is shifted by the gutter width and the horizontal
  scroll to match. Returns the resolved `hscroll` so the caller can persist it. With `follow?`
  false the given `hscroll` is kept even if the cursor is out of view (the mouse scrolled it,
  ADR-0039).
  """
  @spec frame(
          String.t(),
          [map()],
          Theme.t(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Selection.t() | nil,
          boolean()
        ) ::
          {Screen.t(), {non_neg_integer(), integer()}, non_neg_integer()}
  def frame(
        text,
        spans,
        %Theme{} = theme,
        {cursor_line, _} = cursor,
        w,
        h,
        scroll,
        hscroll \\ 0,
        selection \\ nil,
        follow? \\ true
      ) do
    gw = gutter_width(text)
    text_w = max(w - gw, 0)
    {dcol, cy} = cursor_xy(text, cursor, scroll)
    hscroll = if follow?, do: scroll_for(hscroll, dcol, text_w, @hscrolloff), else: hscroll

    screen =
      text
      |> Paint.to_screen(spans, theme, w, h, scroll, gw, hscroll, selection)
      |> draw_gutter(text, theme, h, scroll, gw, cursor_line)
      |> cursor_line_overlay(theme, w, cy, selection)

    {screen, {gw + dcol - hscroll, cy}, hscroll}
  end

  # The current-line tint and the selection are two background overlays; show the
  # cursor-line tint only when nothing is selected (Paint already drew the selection),
  # so the two never fight over the cursor's row.
  defp cursor_line_overlay(screen, _theme, _w, _cy, %Selection{}), do: screen

  defp cursor_line_overlay(screen, theme, w, cy, nil),
    do: highlight_line(screen, w, cy, theme.palette.active_line_bg)

  @doc """
  The width in columns of the line-number gutter for `text`: enough digits for the
  highest line number (1-based) — minimum two — plus a one-column margin on each side.
  Grows as the file crosses a power of ten, so the numbers stay right-aligned.
  """
  @spec gutter_width(String.t()) :: pos_integer()
  def gutter_width(text), do: max(digits(line_count(text)), 2) + 2

  defp line_at(text, line), do: text |> String.split("\n") |> Enum.at(line, "")
  defp line_count(text), do: text |> String.split("\n") |> length()
  defp digits(n), do: n |> Integer.to_string() |> String.length()

  @doc """
  The viewport top (first visible buffer line) that keeps cursor `line` visible in
  a window of `h` rows, given the previous `scroll`. Keeps `scrolloff` rows of
  context between the cursor and the top/bottom edge: scrolls when the cursor comes
  within the margin, otherwise leaves the viewport put. The margin is clamped to
  half the window (so the top and bottom bands never cross) and the top of the file
  still pins `scroll` at 0 — near line 0 the cursor simply rides above the margin.
  """
  @spec scroll_for(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def scroll_for(scroll, line, h, scrolloff \\ 0)

  def scroll_for(scroll, line, h, scrolloff) when h > 0 do
    margin = min(max(scrolloff, 0), div(h - 1, 2))

    cond do
      line - margin < scroll -> max(line - margin, 0)
      line + margin > scroll + h - 1 -> line + margin - h + 1
      true -> scroll
    end
  end

  def scroll_for(scroll, _line, _h, _scrolloff), do: scroll

  @doc """
  The status line as one string of exactly `w` columns: `left` (the buffer label
  and any dirty marker) padded so `right` (`line:col`) sits flush against the right
  edge, each with a one-column margin from the edges. If the two segments together
  exceed `w` the string runs long and the renderer clips it at the screen edge — the
  right segment (the position) is the first to go.
  """
  @spec status_text(String.t(), String.t(), non_neg_integer()) :: String.t()
  def status_text(left, right, w) do
    l = " " <> left
    r = right <> " "
    # At least one space, so a long left segment (a notice) never runs into the position.
    pad = max(w - Width.string(l) - Width.string(r), 1)
    l <> String.duplicate(" ", pad) <> r
  end

  ## GenServer

  @impl true
  def init(_opts) do
    TerminalIO.subscribe()
    active = Session.subscribe()
    safe_subscribe_edits()
    {w, h} = safe_window_size()
    state = new_state(w, h) |> apply_settings(Geex.Settings.load())
    # Say whether the mouse is on, in case this loop restarted after the `mouse` verb turned it
    # off, or the settings start it off.
    TerminalIO.set_mouse(state.mouse)
    {:ok, schedule_repaint(adopt_active(state, active))}
  end

  @doc false
  # What the settings view kept (`Geex.Settings`, ADR-0040 §7), over the defaults: the theme,
  # the mouse, and whether the tree and the edits pane start shown. Anything malformed is
  # ignored.
  def apply_settings(state, settings) do
    state =
      case settings["theme"] do
        name when is_binary(name) ->
          if name in Theme.names(), do: retheme(state, name), else: state

        _ ->
          state
      end

    Enum.reduce([{"mouse", :mouse}, {"tree", :tree_shown}, {"edits", :edits_shown}], state, fn
      {key, field}, acc ->
        case settings[key] do
          on? when is_boolean(on?) -> Map.put(acc, field, on?)
          _ -> acc
        end
    end)
  end

  @doc false
  # The loop's state for a `w` × `h` terminal, attached to no buffer. Public so a test can
  # drive `handle_info/2` without a terminal.
  def new_state(w, h) do
    %{
      w: w,
      h: h,
      goal: 0,
      selection: nil,
      theme: Theme.default(),
      # The theme's name, as `theme NAME` takes it, and the terminal's background once it has
      # answered OSC 11 (`{:rgb, r, g, b}`), which the built-in terminal theme tints from
      # (ADR-0040 §1).
      theme_id: "birds-of-paradise",
      terminal_bg: nil,
      # The settings view (`Alt+Y`, ADR-0040 §7): `Geex.Loop.Settings` while it is open, else
      # nil; the theme to put back if it closes without one being chosen; the installs it
      # started, `%{name => %{pid, ref, then}}`; and the languages a file's opening has already
      # hinted at (once each), the last of them first in the view.
      settings: nil,
      settings_theme: nil,
      installing: %{},
      hinted: [],
      # The file panes and their tabs (ADR-0038); `watched` every buffer in a tab: its monitor
      # and its highlight reactor, `%{pid => %{ref, reactor}}`.
      panes: Panes.new(),
      watched: %{},
      repaint?: false,
      minibuffer: Minibuffer.new(),
      # A one-line message from the buffer (`{:geex_buffer_notice, …}`, e.g. a reconcile
      # conflict, ADR-0032), shown on the status line until the next key.
      notice: nil,
      # Ctrl-O was just refused over a leftover conflict block: the next key, if it is
      # Ctrl-O again, saves anyway (ADR-0034 §3).
      save_armed: false,
      # The edits pane (ADR-0034 §6): shown at start when the terminal has 20 rows; `edits`
      # toggles it (Alt+L). `focus` is where keys go (`Alt+P`); `edits_sel` its highlighted entry.
      edits_shown: h >= 20,
      focus: :editor,
      edits_sel: 0,
      edits_view: %{top: 0, hold: nil, entries: []},
      # The file tree (ADR-0034 §5): shown at start from 100 columns (once geex knows its
      # root); `tree` toggles it. The files are read when it is first drawn, shown, or focused,
      # in a process of their own: `reading` is that process's `{pid, monitor}` until its
      # `index` arrives.
      tree_shown: w >= 100,
      # `files` is the same read's file list, packed for the finder (`Geex.Finder.pack/1`).
      # `top` is the first row shown and `hold` the `sel` the wheel last scrolled at
      # (`settle_lists/3`, ADR-0039).
      # `again` when the files changed on disk while a read ran (`Geex.Tree.Watcher`), so it
      # reads once more when that one answers.
      tree: %{
        index: nil,
        files: nil,
        reading: nil,
        again: false,
        open: MapSet.new(),
        rows: [],
        sel: 0,
        top: 0,
        hold: nil
      },
      # The file finder (Alt+O, `:files` minibuffer mode): the best paths for the typed query;
      # `matching` the search's `{pid, monitor}` until they arrive; `submit` when Enter came
      # first, so the top match opens on arrival.
      finder: %{matches: [], matching: nil, submit: false},
      # The mouse (ADR-0039): whether the terminal reports it (the `mouse` verb); a drag under
      # way (`%{pane, anchor, at, timer}`: the pane it started in, the selection's fixed end,
      # the pointer, the auto-scroll's pending tick); the last press (`{ms, x, y}`), for a
      # double-click.
      mouse: true,
      drag: nil,
      click: nil,
      # Resizing by a handle (ADR-0039 step 3): what is being dragged, until the release. The
      # tree's width and the edits pane's height once dragged (`nil`: the default, by the
      # terminal's size); the splits keep their ratios in `panes`.
      resizing: nil,
      tree_w: nil,
      edits_h: nil
    }
  end

  # --- events that dirty the frame ---

  @impl true
  def handle_info({:geex_active_buffer, pid}, state),
    do: {:noreply, schedule_repaint(adopt_active(state, pid))}

  def handle_info({:geex_open_tabs, [_ | _] = pids}, state) do
    state = leave(state)

    panes =
      Enum.reduce(pids, state.panes, fn pid, acc -> acc |> Panes.show(pid) |> elem(0) end)

    %{tabs: tabs} = pane = panes.panes[panes.pane]
    {given, others} = Enum.split_with(tabs, &(&1.buffer in pids))
    given = Enum.sort_by(given, fn tab -> Enum.find_index(pids, &(&1 == tab.buffer)) end)
    panes = put_in(panes.panes[panes.pane], %{pane | tabs: given ++ others, at: 0})
    {:noreply, schedule_repaint(state |> put_panes(panes) |> enter())}
  end

  # Any buffer change drops the live selection: our own edits already cleared it, and an
  # out-of-band edit (agent/reconcile) would otherwise leave a stale selection whose carets
  # no longer match the text — a later copy/cut would grab the wrong region.
  # Any pane showing the buffer repaints; only the current tab's selection is affected.
  def handle_info({:geex_buffer_change, buffer, _v, _footprint}, %{watched: w} = state)
      when is_map_key(w, buffer) do
    # A drag's anchor was in the text before the change: the drag ends with the selection.
    state =
      if current_buffer(state) == buffer,
        do: %{state | selection: nil, drag: nil},
        else: state

    {:noreply, schedule_repaint(state)}
  end

  # A notice from a buffer you aren't looking at (another tab or pane) names its file, so it
  # doesn't read as being about the current one.
  def handle_info({:geex_buffer_notice, buffer, text}, %{watched: w} = state)
      when is_map_key(w, buffer) do
    text =
      if buffer == current_buffer(state),
        do: text,
        else: status_label(safe_status(buffer)[:path]) <> ": " <> text

    {:noreply, schedule_repaint(%{state | notice: text})}
  end

  # A late attestation relabelled an agent's lines (ADR-0032): repaint so the gutter mark and
  # the status-line author show now, not on the next keystroke.
  def handle_info({:geex_buffer_attested, buffer, _group, _actor}, %{watched: w} = state)
      when is_map_key(w, buffer),
      do: {:noreply, schedule_repaint(state)}

  # The file changed on disk, or caught up (ADR-0034): the status line says "behind disk".
  def handle_info({:geex_buffer_behind, buffer, _behind}, %{watched: w} = state)
      when is_map_key(w, buffer),
      do: {:noreply, schedule_repaint(state)}

  # The edits list changed: an agent wrote, a file changed on disk, you saved (ADR-0034 §6).
  def handle_info({:geex_edits, :changed}, %{edits_shown: true} = state),
    do: {:noreply, schedule_repaint(state)}

  def handle_info({:geex_highlights, buffer, _v}, %{watched: w} = state)
      when is_map_key(w, buffer),
      do: {:noreply, schedule_repaint(state)}

  # Someone else moved the view cursor (an agent's `line` view action, ADR-0030) — treat
  # it as the jump it is, mirroring jump_to_line: drop the live selection (its active end
  # is no longer the cursor — the same staleness rule as the buffer-change handler above)
  # and refresh the goal from the landing, then repaint so the move is visible. Our own
  # set_cursor calls are not echoed back, so this fires only for out-of-band moves.
  def handle_info({:geex_cursor, cursor}, state) do
    goal =
      case safe_session_snapshot() do
        {:ok, %{text: text}} -> Keymap.goal_column(cursor, text)
        _ -> 0
      end

    {:noreply, schedule_repaint(%{state | selection: nil, goal: goal})}
  end

  def handle_info({:geex_io, {:resize, rows, cols}}, state) do
    Renderer.resize(cols, rows)
    {:noreply, schedule_repaint(%{state | w: cols, h: rows})}
  end

  # End of input (terminal closed / Ctrl-D) → quit the editor. Stopping the loop
  # alone would just restart it (a permanent child), so stop the VM — the app's
  # shutdown restores the terminal.
  def handle_info({:geex_io, :eof}, state) do
    Geex.stop()
    {:noreply, state}
  end

  # The settings view (`Alt+Y`) takes the mouse while it is open (ADR-0040 §7, ADR-0039).
  def handle_info({:geex_io, {:mouse, m}}, %{settings: %Settings{} = view} = state) do
    {view, action} = Settings.mouse(view, m, settings_rows(view, state), {state.w, state.h})
    {:noreply, schedule_repaint(settings_action(action, %{state | settings: view}))}
  end

  # The mouse (ADR-0039). A release ends a drag wherever it is; while the minibuffer is open, only
  # its pickers take the mouse.
  def handle_info({:geex_io, {:mouse, %{action: :release}}}, state),
    do: {:noreply, stop_drag(state)}

  def handle_info({:geex_io, {:mouse, m}}, %{minibuffer: %Minibuffer{mode: mode}} = state)
      when mode != :inactive,
      do: {:noreply, picker_mouse(m, state)}

  def handle_info({:geex_io, {:mouse, m}}, state), do: {:noreply, apply_mouse(m, state)}

  # A drag held past the edge of the text scrolls a line (or a column) at a time.
  def handle_info({:geex_drag_scroll, ref}, %{drag: %{timer: ref}} = state),
    do: {:noreply, drag_to(put_in(state.drag.timer, nil), :scroll)}

  # A grammar was installed (`Geex.Install`, ADR-0040 §4): every open file it covers starts
  # highlighting (or starts again with the new build), and the loop follows its new reactor.
  def handle_info({:geex_installed, :grammar, name}, state) do
    paths = Map.new(safe_buffers(), &{&1.pid, &1.path})

    state =
      Enum.reduce(state.watched, state, fn {pid, entry}, acc ->
        path = paths[pid]

        if is_binary(path) and Highlight.language_for_path(path) == {:ok, name} do
          if is_pid(entry.reactor), do: Reactor.unsubscribe(entry.reactor, self())
          Reactor.rewatch(pid, path)

          reactor =
            case Reactor.for_buffer(pid) do
              {:ok, r} ->
                Reactor.subscribe(r)
                r

              :error ->
                nil
            end

          put_in(acc.watched[pid].reactor, reactor)
        else
          acc
        end
      end)

    display =
      case Geex.Installed.grammar(name) do
        %{"display" => display} when is_binary(display) -> display
        _ -> name
      end

    {:noreply, schedule_repaint(%{state | notice: "#{display} highlighting installed"})}
  end

  # An install the settings view started has finished: say how it went there, and do what was
  # waiting on it (choosing the theme just installed).
  def handle_info({:geex_install_done, pid, name, result}, %{installing: installing} = state)
      when is_map_key(installing, name) do
    %{pid: ^pid, ref: ref, then: then} = installing[name]
    Process.demonitor(ref, [:flush])
    state = %{state | installing: Map.delete(installing, name)}

    message =
      case result do
        {:ok, %{unchanged: true, display: display}} -> "#{display} is up to date"
        {:ok, %{display: display}} -> "installed #{display}"
        {:error, reason} -> "#{name}: #{Geex.Install.describe(reason)}"
      end

    state = say(state, message)

    state =
      case {result, then} do
        {{:ok, _}, {:choose_theme, theme}} -> settings_action({:choose_theme, theme}, state)
        _ -> state
      end

    {:noreply, schedule_repaint(state)}
  end

  # A theme: the one in use is loaded again (an update); another is announced.
  def handle_info({:geex_installed, :theme, name}, %{theme_id: name} = state),
    do: {:noreply, schedule_repaint(%{retheme(state) | notice: "theme #{name} updated"})}

  def handle_info({:geex_installed, :theme, name}, state),
    do:
      {:noreply, schedule_repaint(%{state | notice: "theme #{name} installed (`theme #{name}`)"})}

  # The terminal's background (its answer to OSC 11, ADR-0040 §1). The terminal theme tints
  # its active line and selection from it. Not a key: nothing else about the state changes.
  def handle_info({:geex_io, {:osc, "11", spec}}, state) do
    case Theme.Terminal.parse_rgb(spec) do
      {:ok, bg} when state.theme_id == "terminal" ->
        {:noreply, retheme(%{state | terminal_bg: bg})}

      {:ok, bg} ->
        {:noreply, %{state | terminal_bg: bg}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:geex_io, {:osc, _ps, _pt}}, state), do: {:noreply, state}

  # A key. When the minibuffer is open it captures input; otherwise resolve the key against
  # the current text + cursor (read fresh from Session) and apply via the one shared path
  # (edits) or a view-local cursor move.
  def handle_info({:geex_io, event}, state) do
    # Any key dismisses a notice (it has been seen), and any key but Ctrl-O disarms a refused save.
    # A key ends a drag (ADR-0039): what it does may take the drag's pane or text away.
    state = if state.notice, do: schedule_repaint(%{state | notice: nil}), else: state
    state = stop_drag(state)
    state = %{state | save_armed: state.save_armed and event in [{:ctrl, ?o}, {:ctrl, ?O}]}

    cond do
      # The settings view, while it is open, takes every key (ADR-0040 §7).
      state.settings != nil ->
        {view, action} =
          Settings.key(state.settings, event, settings_rows(state.settings, state), state.h)

        {:noreply, schedule_repaint(settings_action(action, %{state | settings: view}))}

      event in [{:alt, ?y}, {:alt, ?Y}] and not Minibuffer.active?(state.minibuffer) ->
        {:noreply, schedule_repaint(open_settings(state))}

      Minibuffer.active?(state.minibuffer) ->
        {:noreply, apply_minibuffer_key(event, state)}

      # A pane can have gone (hidden by a resize); then the keys are the editor's again.
      state.focus != :editor ->
        case focused(state, layout(state)) do
          :edits -> {:noreply, apply_edits_key(event, state)}
          :tree -> {:noreply, apply_tree_key(event, state)}
          :editor -> {:noreply, apply_editor_key(event, %{state | focus: :editor})}
        end

      true ->
        {:noreply, apply_editor_key(event, state)}
    end
  end

  # The tree's files, from the process reload_tree/1 started. An answer from any other process
  # (a read that was superseded) falls through to the catch-all.
  def handle_info(
        {:geex_tree, pid, {files, index}},
        %{tree: %{reading: {pid, ref}} = tree} = state
      ) do
    Process.demonitor(ref, [:flush])
    rows = Tree.rows(index, tree.open)
    # The highlight stays on its row's path when rows come or go above it.
    sel =
      with %{path: path} <- Enum.at(tree.rows, tree.sel),
           i when is_integer(i) <- Enum.find_index(rows, &(&1.path == path)) do
        i
      else
        _ -> min(tree.sel, max(length(rows) - 1, 0))
      end

    again = tree.again
    tree = %{tree | index: index, files: files, reading: nil, again: false, rows: rows, sel: sel}
    # An open finder searches the new list; if Enter is waiting and no search is needed (a blank
    # query), it opens the first file now.
    state = refresh_matches(%{state | tree: tree})
    state = if again, do: reload_tree(state), else: state

    if state.finder.submit and state.finder.matching == nil and
         state.minibuffer.mode == :files,
       do: {:noreply, submit_minibuffer(state)},
       else: {:noreply, schedule_repaint(state)}
  end

  # The finder's search answered (`refresh_matches/1`); an answer for an older query falls
  # through to the catch-all. Enter pressed while it ran opens the top match now.
  def handle_info({:geex_matches, pid, matches}, %{finder: %{matching: {pid, ref}}} = state) do
    Process.demonitor(ref, [:flush])
    finder = %{state.finder | matches: matches, matching: nil}
    state = %{state | finder: finder}

    if finder.submit,
      do: {:noreply, submit_minibuffer(state)},
      else: {:noreply, schedule_repaint(state)}
  end

  # A buffer in a tab ended (closed elsewhere, or crashed): its tabs go, in every pane, and a
  # pane left with none closes. If it was the current tab, the tab now shown becomes current.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{watched: w} = state)
      when is_map_key(w, pid) do
    was_current? = current_buffer(state) == pid
    state = put_panes(state, Panes.drop_buffer(state.panes, pid))

    state =
      cond do
        not was_current? -> state
        Panes.current(state.panes) -> enter(state)
        true -> fallback(state, pid)
      end

    {:noreply, schedule_repaint(state)}
  end

  # Files under the root came or went (`Geex.Tree.Watcher`): read them again, once the tree has
  # been read at all. A read under way reads once more when it answers.
  def handle_info({:geex_tree_changed, _root}, %{tree: %{index: nil}} = state),
    do: {:noreply, state}

  def handle_info({:geex_tree_changed, _root}, %{tree: %{reading: {_, _}}} = state),
    do: {:noreply, put_in(state.tree.again, true)}

  def handle_info({:geex_tree_changed, _root}, state), do: {:noreply, reload_tree(state)}

  # The tree's reader died before answering. Say so, and keep what is shown: an empty index
  # rather than none, so the next frame doesn't start another read that dies the same way.
  # Showing or focusing the tree tries again.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tree: %{reading: {_, ref}}} = state) do
    Logger.warning("geex tree: reading the files failed: #{inspect(reason)}")
    tree = %{state.tree | reading: nil, again: false, index: state.tree.index || %{}}
    notice = "the file tree couldn't be read (see #{Path.join(System.tmp_dir!(), "geex.log")})"
    {:noreply, schedule_repaint(%{state | tree: tree, notice: notice})}
  end

  # The finder's search died before answering: say so, and stop waiting on it.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{finder: %{matching: {_, ref}}} = state) do
    Logger.warning("geex finder: the search failed: #{inspect(reason)}")
    finder = %{state.finder | matching: nil, submit: false}
    notice = "the file search failed (see #{Path.join(System.tmp_dir!(), "geex.log")})"
    {:noreply, schedule_repaint(%{state | finder: finder, notice: notice})}
  end

  # An install the settings view started died without answering; any other `:DOWN` is nothing.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.installing, fn {_name, i} -> i.ref == ref end) do
      {name, _} ->
        state = %{state | installing: Map.delete(state.installing, name)}

        {:noreply,
         schedule_repaint(say(state, "#{name}: the install stopped (#{inspect(reason)})"))}

      nil ->
        {:noreply, state}
    end
  end

  # Coalesced repaint — one per burst.
  def handle_info(:repaint, state), do: {:noreply, repaint(%{state | repaint?: false})}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  # A key for the editor: resolve it against the current text + cursor (read fresh from
  # Session).
  defp apply_editor_key(event, state) do
    # The scroll the mouse set holds until a key acts on the text (ADR-0039): even one that
    # doesn't move the cursor (Delete, Alt+H) should show where it acts.
    state = %{state | panes: Panes.update_current(state.panes, &%{&1 | hold: nil})}

    case safe_session_snapshot() do
      {:ok, %{text: text, cursor: cursor}} -> apply_key(event, cursor, text, state)
      _ -> state
    end
  end

  # Post exactly one :repaint for a burst of dirtying events.
  defp schedule_repaint(%{repaint?: true} = state), do: state

  defp schedule_repaint(state) do
    send(self(), :repaint)
    %{state | repaint?: true}
  end

  ## Panes and tabs (ADR-0038). Session's active buffer is the current pane's shown tab, so the
  ## keymap, the verbs and the MCP surface act on what you are looking at. The loop owns the
  ## other tabs' cursors and every tab's scroll (`Geex.Loop.Panes`).

  defp current_buffer(state) do
    case Panes.current(state.panes) do
      %{buffer: pid} -> pid
      nil -> nil
    end
  end

  # Session's active buffer changed (a file opened, a buffer picked, an agent's open): show it in
  # the current pane, in its tab there or a new one. The loop's own switches arrive here too,
  # already shown. An event that Session has since moved past is ignored, so two quick switches
  # can't bring back the first.
  defp adopt_active(state, nil), do: state

  defp adopt_active(state, pid) do
    cond do
      current_buffer(state) == pid ->
        state

      safe_active_buffer() != {:ok, pid} ->
        state

      true ->
        cursor =
          case safe_session_snapshot() do
            {:ok, %{cursor: cursor}} -> cursor
            _ -> {0, 0}
          end

        {panes, kind} = Panes.show(state.panes, pid, cursor)
        # A tab this pane already had keeps the cursor it had here.
        if kind == :existing, do: set_cursor(Panes.current(panes).cursor)
        state = put_panes(%{state | selection: nil, goal: 0, drag: nil}, panes)
        if kind == :existing, do: state, else: grammar_notice(state, pid)
    end
  end

  # A newly shown file geex could highlight says how, once per language a session: its grammar
  # is in the catalog but not installed, or the one here is built for a tree-sitter ABI this
  # geex doesn't load (ADR-0040 §4, §5). `Alt+Y` then opens on that language.
  defp grammar_notice(state, pid) do
    with %{path: path} when is_binary(path) <- Enum.find(safe_buffers(), &(&1.pid == pid)),
         {status, display} when status in [:available, :needs_update] <-
           Highlight.grammar_status(path),
         %{"name" => lang} <- Geex.Catalog.for_path(path) || Geex.Installed.for_path(path),
         false <- lang in state.hinted do
      notice =
        if status == :available,
          do: "#{display} highlighting available: Alt+Y",
          else: "#{display} highlighting needs an update: Alt+Y"

      %{state | notice: notice, hinted: [lang | state.hinted]}
    else
      _ -> state
    end
  end

  # Open `path` as the current pane's tab, the loop's way: leave this tab, open, and show the
  # buffer now rather than when Session's event comes back, so a key queued behind this one acts
  # on the tab you see.
  defp open_tab(path, state) do
    state = leave(state)

    case safe_open_file(path) do
      {:ok, pid} -> {:ok, pid, adopt_active(state, pid)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Before the loop makes another tab current: copy Session's cursor (the current tab's while it
  # is current) into the tab.
  defp leave(state) do
    with %{buffer: pid} <- Panes.current(state.panes),
         {:ok, ^pid} <- safe_active_buffer(),
         {:ok, %{cursor: cursor}} <- safe_session_snapshot() do
      %{state | panes: Panes.update_current(state.panes, &%{&1 | cursor: cursor})}
    else
      _ -> state
    end
  end

  # Make the current tab Session's active buffer, at the cursor it had in this pane. A selection
  # and the goal column belong to the tab you left.
  defp enter(state) do
    case Panes.current(state.panes) do
      %{buffer: pid, cursor: cursor} ->
        safe_set_active(pid)
        set_cursor(cursor)

      nil ->
        :ok
    end

    %{state | selection: nil, goal: 0, drag: nil}
  end

  # The only pane lost its only buffer some other way than Alt+K (an agent closed it, it
  # crashed): show another open buffer, or a new scratch one, as `close_active/0` would.
  defp fallback(state, dead) do
    next =
      case Enum.find(safe_buffers(), &(&1.pid != dead)) do
        %{pid: pid} ->
          pid

        nil ->
          case Geex.BufferSupervisor.start_scratch() do
            {:ok, pid} -> pid
            _ -> nil
          end
      end

    if next do
      safe_set_active(next)
      adopt_active(state, next)
    else
      state
    end
  end

  defp safe_buffers do
    Session.buffers()
  catch
    :exit, _ -> []
  end

  # `geex a b c` (`Geex.open_paths/1`): the files as tabs in that order, the first shown. Their
  # opens' own events race this; whatever tabs those added stay, after these.
  @doc false
  def open_tabs(pids) do
    if loop = Process.whereis(__MODULE__), do: send(loop, {:geex_open_tabs, pids})
    :ok
  end

  # The smallest pane a split may make (`Geex.Layout.min_pane/0`): a tab bar, two text rows and the
  # scroll-bar row; a gutter and a few columns of text.
  {min_w, min_h} = Layout.min_pane()
  @min_pane_w min_w
  @min_pane_h min_h

  # Alt+- / Alt+=: split the current pane, unless the halves would be smaller than a pane can be.
  defp split(state, dir) do
    rect =
      layout(state).editor
      |> Layout.split(state.panes.split)
      |> Enum.find_value(fn {id, rect} -> id == state.panes.pane && rect end)

    roomy? =
      case {dir, rect} do
        {:rows, %Geex.Rect{h: h}} -> div(h, 2) >= @min_pane_h
        {:cols, %Geex.Rect{w: w}} -> div(w - 1, 2) >= @min_pane_w
        _ -> false
      end

    if roomy?,
      do: switch(state, &Panes.split(&1, dir)),
      else: %{state | notice: "no room to split this pane"}
  end

  # Switch tabs or panes the loop's way: leave, change, enter.
  defp switch(state, fun), do: state |> leave() |> then(&put_panes(&1, fun.(&1.panes))) |> enter()

  # Set the panes, then watch every buffer in a tab: monitor it, subscribe to its changes and its
  # highlight reactor. Buffers no tab holds any more are let go.
  defp put_panes(state, panes) do
    want = Panes.buffers(panes)

    state =
      Enum.reduce(Map.keys(state.watched), state, fn pid, acc ->
        if MapSet.member?(want, pid), do: acc, else: unwatch(acc, pid)
      end)

    state =
      Enum.reduce(want, state, fn pid, acc ->
        if Map.has_key?(acc.watched, pid), do: acc, else: watch(acc, pid)
      end)

    %{state | panes: panes}
  end

  defp watch(state, pid) do
    ref = Process.monitor(pid)
    _ = safe_subscribe_buffer(pid)

    reactor =
      case Reactor.for_buffer(pid) do
        {:ok, r} ->
          Reactor.subscribe(r)
          r

        :error ->
          nil
      end

    put_in(state.watched[pid], %{ref: ref, reactor: reactor})
  end

  # Drop our subscriptions too, not just our monitor: otherwise the buffer and its reactor keep
  # us in their subscriber sets (and keep sending us changes) until they end.
  defp unwatch(state, pid) do
    {%{ref: ref, reactor: reactor}, watched} = Map.pop(state.watched, pid)
    Process.demonitor(ref, [:flush])
    Buffer.unsubscribe(pid, self())
    if is_pid(reactor), do: Reactor.unsubscribe(reactor, self())
    %{state | watched: watched}
  end

  defp reactor_of(state, pid) do
    case state.watched do
      %{^pid => %{reactor: reactor}} -> reactor
      _ -> nil
    end
  end

  ## The mouse (ADR-0039). A file pane under the pointer takes a press (focus it, place the
  ## cursor; Shift or Alt extends the selection, a double-click selects a word), a drag (select,
  ## with auto-scroll past the edge) and the wheel (scroll it, focused or not); its tab bar a
  ## click on a tab, a tab's `×` or the pane's `×`. The tree and the edits list take a click on a
  ## row and the wheel; the status line's "behind disk" a click. Where a cell lands in the text is
  ## `Geex.Loop.Mouse` (pure); on the tab bar, `Geex.Loop.TabBar`.

  # Lines the wheel scrolls per notch; columns, sideways. How often a drag held past the edge
  # scrolls.
  @wheel_lines 3
  @wheel_cols 6
  @drag_tick_ms 50

  defp apply_mouse(%{action: :wheel, button: button, mods: mods} = m, state) do
    step =
      case {button, :shift in mods} do
        {:up, false} -> {0, -@wheel_lines}
        {:down, false} -> {0, @wheel_lines}
        {b, _} when b in [:up, :wheel_left] -> {-@wheel_cols, 0}
        {b, _} when b in [:down, :wheel_right] -> {@wheel_cols, 0}
      end

    case region(state, m.x, m.y) do
      {:file, id, rect} -> schedule_repaint(wheel(state, id, rect, step))
      {:tree, rect} -> schedule_repaint(scroll_tree(state, rect, elem(step, 1)))
      {:edits, rect} -> schedule_repaint(scroll_edits(state, rect, elem(step, 1)))
      _ -> state
    end
  end

  defp apply_mouse(%{action: :press, button: :left} = m, state) do
    # A press, like a key, dismisses a notice and disarms a refused save.
    state = schedule_repaint(%{stop_drag(state) | notice: nil, save_armed: false})

    case handle_at(state, m.x, m.y) do
      nil -> region_press(state, m)
      target -> start_resize(state, target, m)
    end
  end

  # A handle that moved isn't double-clicked by the next press where it was.
  defp apply_mouse(%{action: :drag, button: :left} = m, %{resizing: %{}} = state),
    do: schedule_repaint(resize_to(%{state | click: nil}, m.x, m.y))

  defp apply_mouse(%{action: :drag, button: :left} = m, %{drag: %{}} = state),
    do: drag_to(put_in(state.drag.at, {m.x, m.y}), :move)

  defp apply_mouse(_m, state), do: state

  defp region_press(state, m) do
    case region(state, m.x, m.y) do
      {:file, id, %{y: y} = rect} when m.y == y -> tab_bar_press(state, id, rect, m.x - rect.x)
      {:file, id, rect} -> press(state, id, rect, m)
      {:tree, rect} -> tree_press(state, rect, m)
      {:edits, rect} -> edits_press(state, rect, m)
      :status -> status_press(state, m.x)
      nil -> state
    end
  end

  # Focus the pane, then place the cursor where the press landed. The tab bar's row only focuses.
  defp press(state, id, rect, m) do
    now = System.monotonic_time(:millisecond)
    double? = m.mods == [] and Mouse.double?(state.click, now, {m.x, m.y}, :text)
    # Alt as well as Shift: Windows Terminal keeps Shift+click for its own selection.
    extend? = :shift in m.mods or :alt in m.mods
    state = %{enter_pane({:file, id}, state) | click: {now, m.x, m.y, :text}}

    case pane_text(state, id) do
      {tab, text} when m.y > rect.y ->
        {{line, col} = pos, _edge} =
          Mouse.text_pos(text, rect, {tab.scroll, tab.hscroll}, {m.x, m.y})

        cond do
          double? ->
            {from, to} = Mouse.word_at(line_at(text, line), col)
            select_to(state, {id, rect}, {line, from}, {line, to}, text)

          extend? ->
            anchor =
              case {state.selection, safe_session_snapshot()} do
                {%Selection{anchor: anchor}, _} -> anchor
                {nil, {:ok, %{cursor: cursor}}} -> cursor
                _ -> pos
              end

            state |> select_to({id, rect}, anchor, pos, text) |> start_drag(id, anchor)

          true ->
            state |> select_to({id, rect}, pos, pos, text) |> start_drag(id, pos)
        end

      _ ->
        state
    end
  end

  # Select from `anchor` to `active` (nothing, when they meet) with the cursor at `active`, and
  # keep the pane's scroll where it is while the cursor stays there (`Panes` `hold`): a cursor
  # placed by the mouse is on screen already, so it shouldn't scroll the text from under it.
  defp select_to(state, {id, rect}, anchor, active, text) do
    set_cursor(active)
    sel = if anchor != active, do: Selection.new(anchor) |> Selection.extend(active)
    panes = Panes.update_shown(state.panes, id, &%{&1 | hold: {active, {rect.w, rect.h}}})

    schedule_repaint(%{
      state
      | panes: panes,
        selection: sel,
        goal: Keymap.goal_column(active, text)
    })
  end

  # The drag remembers its buffer too: if the pane shows another tab when the pointer moves, the
  # anchor means nothing there, and the drag ends.
  defp start_drag(state, id, anchor) do
    buffer = Panes.shown(state.panes, id).buffer
    %{state | drag: %{pane: id, buffer: buffer, anchor: anchor, at: nil, timer: nil}}
  end

  defp stop_drag(state), do: %{state | drag: nil, resizing: nil}

  # The pointer moved with the button held (`:move`), or a drag past the edge is due its next
  # step (`:scroll`): select from the drag's anchor to the pointer. Past the edge of the text,
  # scroll that way every @drag_tick_ms until the pointer comes back, the text ends, or the
  # button is let go. The drag ends if its pane isn't current any more or shows another buffer.
  defp drag_to(%{drag: %{pane: id, buffer: buffer, anchor: anchor, at: at} = drag} = state, why) do
    with true <- id == state.panes.pane and not Minibuffer.active?(state.minibuffer),
         {^id, rect} <- pane_rect(state, id),
         {%{buffer: ^buffer} = tab, text} <- pane_text(state, id) do
      {_pos, edge} = Mouse.text_pos(text, rect, {tab.scroll, tab.hscroll}, at)
      moved = if why == :scroll, do: scrolled(tab, text, rect, edge), else: tab
      stuck? = why == :scroll and {moved.scroll, moved.hscroll} == {tab.scroll, tab.hscroll}
      state = %{state | panes: Panes.update_shown(state.panes, id, fn _ -> moved end)}
      {pos, edge} = Mouse.text_pos(text, rect, {moved.scroll, moved.hscroll}, at)
      state = select_to(state, {id, rect}, anchor, pos, text)

      cond do
        edge == {0, 0} or stuck? ->
          put_in(state.drag.timer, nil)

        drag.timer ->
          state

        true ->
          ref = make_ref()
          Process.send_after(self(), {:geex_drag_scroll, ref}, @drag_tick_ms)
          put_in(state.drag.timer, ref)
      end
    else
      _ -> stop_drag(state)
    end
  end

  # The wheel over pane `id`: scroll it, keeping its cursor where it is.
  defp wheel(state, id, rect, step) do
    case pane_text(state, id) do
      {tab, text} ->
        cursor =
          case {id == state.panes.pane, safe_active_buffer(), safe_session_snapshot()} do
            {true, {:ok, pid}, {:ok, %{cursor: cursor}}} when pid == tab.buffer -> cursor
            _ -> clamp_cursor(tab.cursor, text)
          end

        tab = %{scrolled(tab, text, rect, step) | hold: {cursor, {rect.w, rect.h}}}
        %{state | panes: Panes.update_shown(state.panes, id, fn _ -> tab end)}

      nil ->
        state
    end
  end

  # Scroll a tab by `{columns, lines}`: not above the top or left of the text, and not further
  # down than its last line at the bottom of the pane (nor right than its widest line), unless it
  # was already there.
  defp scrolled(tab, text, rect, {dx, dy}) do
    rows = max(rect.h - 2, 1)
    lines = line_count(text)
    bottom = max(lines - rows, 0)
    # The text columns: after the gutter, before the vertical scroll bar when there is one.
    cols = max(rect.w - gutter_width(text) - if(lines > rows, do: 1, else: 0), 1)
    right = max(max_line_width(text) - cols, 0)

    %{
      tab
      | scroll: step_within(tab.scroll, dy, bottom),
        hscroll: step_within(tab.hscroll, dx, right)
    }
  end

  defp step_within(at, d, _max) when d < 0, do: max(at + d, 0)
  defp step_within(at, d, max) when d > 0, do: max(min(at + d, max), at)
  defp step_within(at, _d, _max), do: at

  ## Resizing (ADR-0039 step 3, ADR-0038's amendment). The handles: each split's boundary (a
  ## side-by-side split's divider column; a stacked split's second half's top row, where the tab
  ## bars have nothing), the tree's right edge and the edits pane's title row. Each shows `⠿`.
  ## Dragging one resizes; a double-click on one puts it back (an even split, the default size).

  @handle TabBar.handle()

  # The handle under `{x, y}`, or `nil`: `:tree`, `:edits`, or `{:split, path}`.
  defp handle_at(state, x, y) do
    l = layout(state)
    in_rows? = fn r -> y >= r.y and y < r.y + r.h end
    in_cols? = fn r -> x >= r.x and x < r.x + r.w end

    cond do
      y == l.status ->
        nil

      l.tree && x == l.tree.x + l.tree.w - 1 && in_rows?.(l.tree) ->
        :tree

      l.edits && y == l.edits.y && in_cols?.(l.edits) ->
        :edits

      true ->
        l.editor
        |> Layout.handles(state.panes.split)
        |> Enum.find_value(fn
          %{dir: :cols, node: n, at: at, path: path} ->
            x == at and in_rows?.(n) and {:split, path}

          %{dir: :rows, node: n, at: at, path: path} ->
            y == at and in_cols?.(n) and tab_bar_blank?(state, x, y) and {:split, path}
        end)
    end
  end

  # Whether `{x, y}` is on a tab bar where it has no tab and no `×`: its handle, or a blank.
  defp tab_bar_blank?(state, x, y) do
    case region(state, x, y) do
      {:file, id, %{y: ^y} = rect} ->
        TabBar.hit(tab_bar(state, state.panes.panes[id], rect), x - rect.x) in [nil, :handle]

      _ ->
        false
    end
  end

  # A press on a handle: a double-click puts it back; else the drag begins. The edits pane's
  # title still focuses it, and a stacked split's handle the pane it is on, as before.
  defp start_resize(state, target, m) do
    now = System.monotonic_time(:millisecond)
    double? = Mouse.double?(state.click, now, {m.x, m.y}, :handle)
    state = %{state | click: {now, m.x, m.y, :handle}}

    state =
      case {target, region(state, m.x, m.y)} do
        {:edits, _} -> %{state | focus: :edits}
        {:tree, _} -> %{state | focus: :tree}
        {{:split, _}, {:file, id, _rect}} -> enter_pane({:file, id}, state)
        _ -> state
      end

    cond do
      # A split's drag remembers the split, in case a pane closes under it (`resize_to/3`).
      not double? -> %{state | resizing: %{target: target, node: node_of(state, target)}}
      target == :tree -> %{state | tree_w: nil}
      target == :edits -> %{state | edits_h: nil}
      true -> %{state | panes: Panes.set_ratio(state.panes, elem(target, 1), 0.5)}
    end
  end

  # The pointer moved with a handle held: put the edge under it. Stored as laid out (clamped), so
  # a later terminal resize starts from what you see.
  # A panel hidden while its edge was held (Alt+T, Alt+L) ends the drag, keeping its size.
  defp resize_to(%{resizing: %{target: :tree}} = state, x, _y) do
    case layout(%{state | tree_w: x + 1}).tree do
      nil -> stop_drag(state)
      tree -> %{state | tree_w: tree.w}
    end
  end

  defp resize_to(%{resizing: %{target: :edits}} = state, _x, y) do
    case layout(%{state | edits_h: state.h - 1 - y}).edits do
      nil -> stop_drag(state)
      edits -> %{state | edits_h: edits.h}
    end
  end

  defp resize_to(%{resizing: %{target: {:split, path} = target, node: was}} = state, x, y) do
    l = layout(state)
    same? = was == node_of(state, target)

    case Enum.find(Layout.handles(l.editor, state.panes.split), &(&1.path == path)) do
      %{dir: dir, node: node} when same? ->
        at = if dir == :cols, do: x, else: y
        ratio = Layout.ratio_at(node, split_at(state.panes.split, path), at)
        %{state | panes: Panes.set_ratio(state.panes, path, ratio)}

      _gone_or_changed ->
        stop_drag(state)
    end
  end

  # A split's direction and panes: the same path names another split after a pane closes.
  defp node_of(state, {:split, path}) do
    case split_at(state.panes.split, path) do
      {dir, _a, _b, _r} = node ->
        {dir, %Geex.Rect{x: 0, y: 0, w: 0, h: 0} |> Layout.split(node) |> ids()}

      _ ->
        nil
    end
  end

  defp node_of(_state, _target), do: nil

  defp ids(laid_out), do: Enum.map(laid_out, &elem(&1, 0))

  defp split_at(split, []), do: split
  defp split_at({_dir, a, _b, _r}, [:a | path]), do: split_at(a, path)
  defp split_at({_dir, _a, b, _r}, [:b | path]), do: split_at(b, path)
  defp split_at(_leaf, _path), do: nil

  # What is under screen cell `{x, y}`: a file pane (`{:file, id, rect}`), the tree or the edits
  # pane (`{:tree | :edits, rect}`), the status line, or nothing (a divider).
  defp region(state, x, y) do
    l = layout(state)
    inside? = fn r -> r != nil and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

    cond do
      y == l.status ->
        :status

      inside?.(l.tree) ->
        {:tree, l.tree}

      inside?.(l.edits) ->
        {:edits, l.edits}

      true ->
        # A pane too small to draw (`repaint/1` fills it) takes no click either.
        l.editor
        |> Layout.split(state.panes.split)
        |> Enum.find_value(fn {id, r} ->
          inside?.(r) && r.w >= 3 && r.h >= 3 && {:file, id, r}
        end)
    end
  end

  # A press on a pane's tab bar: a tab shows it, a tab's `×` closes it (as Alt+K does, refused
  # with unsaved edits), the pane's `×` closes the pane. Each focuses the pane first.
  defp tab_bar_press(state, id, rect, x) do
    pane = state.panes.panes[id]
    state = %{state | click: {System.monotonic_time(:millisecond), rect.x + x, rect.y, :tab}}

    case TabBar.hit(tab_bar(state, pane, rect), x) do
      # The pane you were in stays current, unless it is the one closing.
      :close_pane ->
        close_pane(state, id)

      # The tab already shown, in the current pane: nothing to switch (and the selection stays).
      {:tab, i} when i == pane.at and id == state.panes.pane ->
        %{state | focus: :editor}

      {:tab, i} ->
        state |> enter_pane({:file, id}) |> switch(&Panes.select(&1, i))

      {:close_tab, i} ->
        %{buffer: buf} = Enum.at(pane.tabs, i)

        # Refused without switching to it: the tab holds the only copy of unsaved edits.
        if match?(%{dirty: true}, safe_status(buf)) and
             not Panes.in_other_pane?(state.panes, buf, id) do
          name = status_label(safe_status(buf)[:path])

          %{
            state
            | notice: "not closed: #{name} has unsaved changes (save them, or undo them, first)"
          }
        else
          state |> enter_pane({:file, id}) |> switch(&Panes.select(&1, i)) |> do_close()
        end

      _nothing_or_handle ->
        enter_pane({:file, id}, state)
    end
  end

  # The pane's `×` (ADR-0039): close the pane and its tabs. Refused while one of its tabs holds the
  # only copy of a buffer with unsaved edits; the only pane never closes. A buffer no other pane
  # has closes with it, as Alt+K's does.
  defp close_pane(state, id) do
    tabs = state.panes.panes[id].tabs

    own =
      tabs
      |> Enum.map(& &1.buffer)
      |> Enum.uniq()
      |> Enum.reject(&Panes.in_other_pane?(state.panes, &1, id))

    cond do
      map_size(state.panes.panes) == 1 ->
        %{state | notice: "the only pane doesn't close"}

      dirty = Enum.find(own, &match?(%{dirty: true}, safe_status(&1))) ->
        name = status_label(safe_status(dirty)[:path])

        %{
          state
          | notice:
              "pane not closed: #{name} has unsaved changes (save them, or undo them, first)"
        }

      true ->
        state = switch(state, &Panes.close_pane(&1, id))
        Enum.each(own, &safe_close_buffer/1)
        %{state | notice: "closed the pane"}
    end
  end

  # A press on the tree: its title focuses it; a row is highlighted, and a directory opens or
  # closes, a file opens (as Enter does). Its right edge is the divider.
  defp tree_press(state, rect, m) do
    i = state.tree.top + m.y - rect.y - 1
    now = System.monotonic_time(:millisecond)
    # A double-click on a folder would open it and close it again: the second press does nothing.
    double? = Mouse.double?(state.click, now, {m.x, m.y}, :tree)
    state = %{state | focus: :tree, click: {now, m.x, m.y, :tree}}

    case Enum.at(state.tree.rows, i) do
      _ when m.x >= rect.x + rect.w - 1 ->
        state

      _ when m.y == rect.y ->
        state

      nil ->
        state

      %{dir?: true} when double? ->
        state

      row ->
        apply_tree_key({:key, :enter}, put_in(state.tree.sel, i)) |> then(&keep_tree(&1, row))
    end
  end

  # After a click on a directory, the tree stays where it is.
  defp keep_tree(state, %{dir?: true}), do: put_in(state.tree.hold, state.tree.sel)
  defp keep_tree(state, _file), do: state

  # A press on the edits list: its title focuses it; an entry opens, as Enter does.
  defp edits_press(state, rect, m) do
    i = state.edits_view.top + m.y - rect.y - 1
    state = %{state | focus: :edits}

    case m.y > rect.y && Enum.at(state.edits_view.entries, i) do
      entry when is_map(entry) -> open_entry(entry, %{state | focus: :editor, edits_sel: i})
      _ -> state
    end
  end

  # A press on the status line's "behind disk (Alt+J)": fast-forward.
  defp status_press(state, x) do
    with {:ok, %{behind: behind} = snap} when behind not in [nil, false] <-
           safe_session_snapshot(),
         from =
           1 + Width.string(status_label(snap.path) <> if(snap.dirty, do: " [+]", else: "")) + 2,
         true <- x >= from and x < from + Width.string(@behind) do
      do_fast_forward(state)
    else
      _ -> state
    end
  end

  # The wheel over the tree or the edits list scrolls it, leaving its highlighted row (which may
  # go out of view until a key moves it).
  defp scroll_tree(%{tree: tree} = state, rect, d) do
    view =
      scroll_list(
        tree,
        min(tree.sel, max(length(tree.rows) - 1, 0)),
        rect.h - 1,
        length(tree.rows),
        d
      )

    %{state | tree: Map.merge(tree, view)}
  end

  defp scroll_edits(state, rect, d) do
    n = length(state.edits_view.entries)
    sel = min(state.edits_sel, max(n - 1, 0))
    %{state | edits_view: scroll_list(state.edits_view, sel, rect.h - 1, n, d)}
  end

  defp scroll_list(view, _sel, _rows, _count, 0), do: view

  defp scroll_list(%{top: top} = view, sel, rows, count, d),
    do: %{view | top: (top + d) |> min(max(count - rows, 0)) |> max(0), hold: sel}

  # The mouse while the minibuffer is open (ADR-0039): in a picker (the palette, the buffers, the
  # finder) the wheel moves the highlight and a click on a row picks it; a click off the list
  # closes the picker. The other modes take no mouse.
  defp picker_mouse(%{action: :wheel, button: b}, %{minibuffer: %{mode: mode}} = state)
       when mode in @pickers and b in [:up, :down] do
    count = length(candidates(state))
    sel = (state.minibuffer.sel + if(b == :up, do: -1, else: 1)) |> min(count - 1) |> max(0)
    schedule_repaint(%{state | minibuffer: Minibuffer.select(state.minibuffer, sel)})
  end

  defp picker_mouse(%{action: :press, button: :left, y: y}, %{minibuffer: %{mode: mode}} = state)
       when mode in @pickers do
    {candidates, start, rows, top} = popup_window(state)

    cond do
      y == state.h - 1 -> state
      y >= top and y < top + rows -> pick(Enum.at(candidates, start + y - top), state)
      true -> close_minibuffer(state)
    end
  end

  defp picker_mouse(_m, state), do: state

  defp pane_rect(state, id) do
    layout(state).editor
    |> Layout.split(state.panes.split)
    |> Enum.find(fn {pane, _rect} -> pane == id end)
  end

  # Pane `id`'s shown tab and its buffer's text, or `nil` when it has none.
  defp pane_text(state, id) do
    with %{buffer: pid} = tab <- Panes.shown(state.panes, id),
         {:ok, %{text: text}} <- safe_buffer_snapshot(pid) do
      {tab, text}
    else
      _ -> nil
    end
  end

  # One frame: each file pane (its tab bar, then the text), the dividers between side-by-side
  # panes, the tree and the edits pane, then the status line (the current tab's) or the
  # minibuffer, and the palette's popup on top.
  # The settings view covers the whole screen while it is open (ADR-0040 §7).
  defp repaint(%{settings: %Settings{} = view} = state) do
    screen =
      Settings.draw(view, settings_rows(view, state), state.theme.palette, {state.w, state.h})

    Renderer.flush(screen, :hidden)
    state
  end

  defp repaint(state) do
    state = ensure_tree(state)
    layout = layout(state)
    entries = if layout.edits, do: edits_entries(), else: []
    state = settle_lists(state, layout, entries)
    editing? = focused(state, layout) == :editor
    active = safe_session_snapshot()
    active_pid = safe_active_buffer()

    {screen, panes, cursor} =
      layout.editor
      |> Layout.split(state.panes.split)
      |> Enum.reduce({Screen.new(state.w, state.h), state.panes, :hidden}, fn {id, rect},
                                                                              {screen, panes,
                                                                               cursor} ->
        current? = id == panes.pane

        case pane_view(panes, id, current?, active, active_pid) do
          # A resize can leave a pane too small to draw (`split/2` refuses to make one): fill it,
          # so nothing the terminal showed there before the resize stays.
          _ when rect.w < 3 or rect.h < 3 ->
            {fill_pane(screen, rect, state.theme), panes, cursor}

          nil ->
            {draw_empty_pane(screen, rect, current? and editing?, state), panes, cursor}

          {tab, snap} ->
            {pane, tab, at} = draw_pane(rect, tab, snap, current?, current? and editing?, state)
            panes = Panes.update_shown(panes, id, fn _ -> tab end)
            cursor = if current? and editing?, do: at, else: cursor

            screen =
              screen
              |> Screen.blit(pane, rect.x, rect.y)
              |> draw_tab_bar(rect, panes.panes[id], current? and editing?, state)

            {screen, panes, cursor}
        end
      end)

    screen =
      layout.editor
      |> Layout.dividers(state.panes.split)
      |> Enum.reduce(screen, &draw_divider(&2, &1, state.theme))
      |> draw_tree(layout.tree, state)
      |> draw_edits_pane(layout.edits, state, entries)

    {screen, cursor} =
      case active do
        {:ok, snap} -> draw_bottom(screen, state, snap, cursor)
        _ -> draw_bottom(screen, state, nil, cursor)
      end

    # The palette popup (ADR-0028 §3) overlays the rows just above the minibuffer input —
    # painted last so it sits on top of the text; a no-op outside the picker modes.
    screen = draw_palette(screen, state)

    Renderer.flush(screen, cursor)
    %{state | panes: panes}
  end

  # What pane `id` shows: its tab and a snapshot of the tab's buffer at the tab's cursor. The
  # current tab, while it is Session's active buffer, reads Session's snapshot (its cursor lives
  # there); any other tab reads its buffer and keeps its own cursor, clamped to the text (another
  # pane's edit can have shortened it).
  defp pane_view(panes, id, current?, active, active_pid) do
    case Panes.shown(panes, id) do
      nil ->
        nil

      %{buffer: pid} = tab ->
        case {current?, active, active_pid} do
          {true, {:ok, snap}, {:ok, ^pid}} ->
            {tab, snap}

          _ ->
            case safe_buffer_snapshot(pid) do
              {:ok, snap} -> {tab, Map.put(snap, :cursor, clamp_cursor(tab.cursor, snap.text))}
              :error -> nil
            end
        end
    end
  end

  # One file pane, drawn on a screen of its own size: the tab bar row (drawn after, over the
  # whole frame), the text, and the horizontal scroll-bar row at the bottom. Grid mode's ruler
  # (ADR-0027) takes the top text row of the current pane. Returns the pane's screen, the tab
  # with where it scrolled to, and the hardware cursor's place on the frame (or `:hidden`).
  defp draw_pane(rect, tab, snap, current?, focused?, state) do
    %{text: text, cursor: {line, _} = cursor} = snap
    grid? = current? and grid_mode?(state)
    top = if grid?, do: 1, else: 0
    # `est` is the pane as the single-editor drawing below knew it: its text rows, then the
    # scroll-bar row, then one row past the pane (where the old editor's status line sat).
    est = %{state | w: rect.w, h: rect.h}
    h_text = max(text_height(est.h) - top, 0)
    # Reserve the rightmost column for a vertical scroll bar when the buffer overflows the
    # viewport; the text then renders into a one-column-narrower area.
    total = line_count(text)
    vbar? = h_text > 0 and total > h_text
    tw = est.w - if(vbar?, do: 1, else: 0)

    # The mouse scrolled this tab, or placed its cursor (ADR-0039): keep the scroll it left while
    # the cursor stays there and the pane keeps its size, even with the cursor out of view. A
    # cursor that moved since, or a split or resize, follows the cursor again.
    held? = tab.hold == {cursor, {rect.w, rect.h}}
    scroll = if held?, do: tab.scroll, else: scroll_for(tab.scroll, line, h_text, @scrolloff)

    # `text` (the snapshot) and the overlay (Reactor.render) are read from two processes, so
    # painting assumes they are the same buffer version. A concurrent MCP/reconcile edit landing
    # between the two reads can briefly pair text@vN with spans@v(N+1); the overlay only ever
    # clips (Paint tolerates out-of-range spans) and the change's own repaint corrects it.
    {screen, {cx, cy}, hscroll} =
      frame(
        text,
        overlay_spans(reactor_of(state, tab.buffer)),
        state.theme,
        cursor,
        tw,
        h_text,
        scroll,
        tab.hscroll,
        if(current?, do: state.selection),
        not held?
      )

    gw = gutter_width(text)
    text_w = max(tw - gw, 0)
    content_w = max_line_width(text)

    screen =
      screen
      |> agent_marks(snap.blame, scroll, h_text, state.theme)
      |> Screen.resize(est.w, est.h)
      |> maybe_vscrollbar(vbar?, est.w - 1, h_text, scroll, total, state.theme)
      # Shift the text + scroll bar down past the reserved ruler row, then paint the
      # contextual grid chrome over the now-vacant top row + the text region.
      |> Screen.translate_y(top)
      |> draw_ruler(grid?, gw, text_w, hscroll, state.theme)
      |> draw_grid_lines(grid?, gw, text_w, h_text, top, hscroll, state.theme)
      |> draw_hbar(est, gw, text_w, content_w, hscroll)
      # Down one more, under the tab bar.
      |> Screen.translate_y(1)

    at =
      case {focused?, cursor_target(est.w, h_text, cx, cy)} do
        {true, {x, y}} -> {x + rect.x, y + top + 1 + rect.y}
        _ -> :hidden
      end

    # The current tab's cursor is Session's; keep a copy, for when Session moves on without the
    # loop (an outside open).
    hold = if held?, do: tab.hold
    {screen, %{tab | scroll: scroll, hscroll: hscroll, cursor: cursor, hold: hold}, at}
  end

  defp fill_pane(screen, rect, %Theme{palette: pal}),
    do:
      Screen.fill_rect(screen, rect.x, rect.y, rect.w, rect.h, %Cell{
        char: " ",
        fg: pal.fg,
        bg: pal.bg
      })

  # A pane with no tabs: its tab bar, and a hint.
  defp draw_empty_pane(screen, rect, focused?, %{theme: %Theme{palette: pal}} = state) do
    screen
    |> Screen.fill_rect(rect.x, rect.y, rect.w, rect.h, %Cell{char: " ", fg: pal.fg, bg: pal.bg})
    |> draw_tab_bar(rect, %{tabs: [], at: 0}, focused?, state)
    |> Screen.draw_text(
      rect.x + 1,
      rect.y + 2,
      palette_clip("no file (Alt+O opens one)", rect.w - 1),
      %Cell{
        fg: pal.line_number,
        bg: pal.bg
      }
    )
  end

  # The pane's tab bar (ADR-0038) on its top row (`Geex.Loop.TabBar`): each tab numbered (Alt+1..9)
  # with its file name, ` [+]` for unsaved edits and a `×` that closes it; the shown tab tinted,
  # brighter in the focused pane; the pane's own `×` at the right end when it isn't the only one
  # (ADR-0039).
  defp draw_tab_bar(screen, rect, pane, focused?, %{theme: %Theme{palette: pal}} = state) do
    bar = tab_bar(state, pane, rect)

    screen =
      Screen.fill_rect(screen, rect.x, rect.y, rect.w, 1, %Cell{
        char: " ",
        fg: pal.line_number,
        bg: pal.bg
      })

    screen =
      Enum.reduce(bar.tabs, screen, fn %{i: i, x: x, label: label}, acc ->
        style =
          cond do
            i == pane.at and focused? -> %Cell{fg: pal.fg, bg: pal.bg, attrs: [:reverse]}
            # With no tint (the terminal palette, unanswered), underlined instead.
            i == pane.at and pal.mark != [] -> %Cell{fg: pal.fg, bg: pal.bg, attrs: [:underline]}
            i == pane.at -> %Cell{fg: pal.fg, bg: pal.active_line_bg}
            true -> %Cell{fg: pal.line_number, bg: pal.bg}
          end

        Screen.draw_text(acc, rect.x + x, rect.y, palette_clip(label, bar.w - x), style)
      end)

    screen =
      case bar.handle do
        nil ->
          screen

        x ->
          Screen.draw_text(screen, rect.x + x, rect.y, @handle, %Cell{
            fg: pal.active_line_number,
            bg: pal.bg
          })
      end

    case bar.close do
      nil ->
        screen

      x ->
        Screen.draw_text(screen, rect.x + x, rect.y, TabBar.pane_close(), %Cell{
          fg: pal.line_number,
          bg: pal.bg
        })
    end
  end

  # The tab bar's layout for a pane at `rect`: what is drawn, and what a click hits.
  # A pane below the editor's top row is the lower half of a stacked split: its bar keeps the
  # split's handle (ADR-0038 §6).
  defp tab_bar(state, %{tabs: tabs, at: at}, rect) do
    names = Enum.map(tabs, &tab_label(&1.buffer))
    handle? = rect.y > layout(state).editor.y
    TabBar.layout(names, at, rect.w, map_size(state.panes.panes) > 1, handle?)
  end

  defp tab_label(pid) do
    case safe_status(pid) do
      %{path: path, dirty: dirty} -> status_label(path) <> if(dirty, do: " [+]", else: "")
      nil -> "?"
    end
  end

  # A side-by-side split's divider, its handle in the middle (ADR-0039 step 3).
  defp draw_divider(screen, %Geex.Rect{x: x, y: y, h: h}, %Theme{palette: pal}) do
    Enum.reduce(y..(y + h - 1)//1, screen, fn row, acc ->
      Screen.set_cell(acc, x, row, %Cell{char: "│", fg: pal.line_number, bg: pal.bg})
    end)
    |> Screen.set_cell(x, y + div(h, 2), %Cell{
      char: @handle,
      fg: pal.active_line_number,
      bg: pal.bg
    })
  end

  # Two rows at the bottom are reserved: the status line (h-1) and the horizontal scroll
  # bar (h-2). The horizontal-bar row is *always* reserved — even when no line overflows —
  # so showing/hiding the bar never reflows the text vertically. The buffer gets the rest.
  defp text_height(h), do: max(h - 2, 0)

  # The bottom row is the status line, or the **minibuffer** when it is open — which takes
  # over the status row and owns the hardware cursor while active.
  defp draw_bottom(screen, %{minibuffer: mb} = state, snap, buffer_cursor) do
    cond do
      Minibuffer.active?(mb) -> {draw_minibuffer(screen, state), minibuffer_cursor(state)}
      snap == nil -> {draw_empty_status(screen, state), :hidden}
      true -> {draw_status(screen, state, snap), buffer_cursor}
    end
  end

  # Draw the minibuffer over the bottom row: the mode prompt + the typed input, on the
  # **active-line background** (the same tint the cursor's row gets — see highlight_line/4) so
  # the input field reads as a focused, distinct surface, yet stays clearly different from the
  # reverse-video status bar it replaces.
  defp draw_minibuffer(screen, %{w: w, h: h, theme: %Theme{palette: pal}, minibuffer: mb}) do
    line = Minibuffer.prompt(mb) <> Minibuffer.value(mb)

    screen
    |> Screen.fill_rect(0, h - 1, w, 1, %Cell{
      char: " ",
      fg: pal.fg,
      bg: pal.active_line_bg,
      attrs: pal.mark
    })
    |> Screen.draw_text(0, h - 1, line, %Cell{fg: pal.fg, bg: pal.active_line_bg, attrs: pal.mark})
  end

  # The hardware cursor position within the minibuffer: after the prompt, at the input cursor
  # (counted in display columns so a wide glyph in the input shifts it by two).
  defp minibuffer_cursor(%{h: h, minibuffer: mb}) do
    before = Minibuffer.value(mb) |> String.graphemes() |> Enum.take(mb.cursor) |> Enum.join()
    {Width.string(Minibuffer.prompt(mb)) + Width.string(before), h - 1}
  end

  # The command-palette popup (ADR-0028 §3): the fuzzy candidate list, drawn over the rows
  # directly **above** the minibuffer input row. The list reads top-to-bottom (best match at
  # the top of the block); pressing Alt+S moves the highlight *down on screen* toward the
  # input, Alt+W up — the on-screen direction matches the editor's own up/down. The highlighted
  # row takes the active-line tint (the same the input row wears), so eye + Enter agree.
  defp draw_palette(screen, %{minibuffer: %Minibuffer{mode: mode} = mb} = state)
       when mode in [:palette, :buffers, :files] do
    {candidates, start, rows, top} = popup_window(state)
    name_col = name_col(mode, candidates, state.w)

    cond do
      candidates == [] ->
        draw_palette_empty(screen, state, empty_hint(state))

      # No vertical room for even one candidate row (a degenerate ≤1-row terminal): draw nothing
      # rather than the empty hint, which would mislead.
      rows == 0 ->
        screen

      true ->
        candidates
        |> Enum.slice(start, rows)
        |> Enum.with_index()
        |> Enum.reduce(screen, fn {entry, i}, acc ->
          draw_palette_row(acc, entry, top + i, start + i == mb.sel, state, name_col)
        end)
    end
  end

  defp draw_palette(screen, _state), do: screen

  # The popup's candidates, the first one shown, how many rows, and the screen row of the first.
  # The window scrolls so the highlighted row (`sel`) stays visible: once the selection passes the
  # first page it rides the bottom of the window. Drawing and a click both read it.
  defp popup_window(%{minibuffer: mb} = state) do
    candidates = candidates(state)
    rows = min(length(candidates), min(@palette_rows, max(state.h - 1, 0)))
    start = mb.sel |> Kernel.-(rows - 1) |> max(0) |> min(max(length(candidates) - rows, 0))
    {candidates, start, rows, state.h - 1 - rows}
  end

  # The edits pane (ADR-0034 §6): a title row, then the entries, the highlighted one tinted
  # while the pane has focus. `nil` when it isn't shown.
  defp draw_edits_pane(screen, nil, _state, _entries), do: screen

  defp draw_edits_pane(
         screen,
         %Geex.Rect{x: x, y: y, w: w, h: h},
         %{theme: %Theme{palette: pal}} = state,
         entries
       ) do
    focused? = state.focus == :edits
    hint = if focused?, do: " Enter opens · Esc back ", else: " Alt+P "
    title = "── edits " <> String.duplicate("─", max(w - 9 - String.length(hint), 0)) <> hint

    screen =
      screen
      |> Screen.fill_rect(x, y, w, h, %Cell{char: " ", fg: pal.fg, bg: pal.bg})
      |> Screen.draw_text(x, y, palette_clip(title, w), %Cell{fg: pal.line_number, bg: pal.bg})

    # Its handle (ADR-0038 §6), in the middle of the title's rule, between its name and the hint:
    # drag the title row to resize.
    rule = max(w - 9 - String.length(hint), 0)
    mid = x + 9 + div(rule, 2)

    screen =
      if rule > 0,
        do:
          Screen.draw_text(screen, mid, y, @handle, %Cell{fg: pal.active_line_number, bg: pal.bg}),
        else: screen

    if entries == [] do
      Screen.draw_text(screen, x + 2, y + 1, palette_clip("no edits yet", w - 2), %Cell{
        fg: pal.line_number,
        bg: pal.bg
      })
    else
      sel = min(state.edits_sel, length(entries) - 1)

      entries
      |> EditsPane.lines(safe_start().root, w, h - 1, sel, focused?, state.edits_view.top)
      |> Enum.with_index(y + 1)
      |> Enum.reduce(screen, fn {{text, entry, selected?}, row}, acc ->
        {bg, attrs} =
          if selected? and focused?, do: {pal.active_line_bg, pal.mark}, else: {pal.bg, []}

        fg = if entry.kind == :behind, do: pal.cursor, else: pal.fg

        acc
        |> Screen.fill_rect(x, row, w, 1, %Cell{char: " ", fg: fg, bg: bg, attrs: attrs})
        |> Screen.draw_text(x, row, palette_clip(text, w), %Cell{fg: fg, bg: bg, attrs: attrs})
      end)
    end
  end

  # The file tree (ADR-0034 §5): a title row, then the rows, with a divider on its right edge.
  defp draw_tree(screen, nil, _state), do: screen

  defp draw_tree(screen, %Geex.Rect{w: w, h: h}, %{theme: %Theme{palette: pal}} = state) do
    focused? = state.focus == :tree
    inner = max(w - 1, 0)
    hint = if focused?, do: " Enter ", else: ""
    title = "── files " <> String.duplicate("─", max(inner - 9 - String.length(hint), 0)) <> hint

    screen =
      screen
      |> Screen.fill_rect(0, 0, w, h, %Cell{char: " ", fg: pal.fg, bg: pal.bg})
      |> Screen.draw_text(0, 0, palette_clip(title, inner), %Cell{fg: pal.line_number, bg: pal.bg})

    screen =
      Enum.reduce(0..(h - 1)//1, screen, fn row, acc ->
        Screen.draw_text(acc, inner, row, "│", %Cell{fg: pal.line_number, bg: pal.bg})
      end)
      # Its handle (ADR-0039 step 3): drag the edge to resize.
      |> Screen.draw_text(inner, div(h, 2), @handle, %Cell{fg: pal.active_line_number, bg: pal.bg})

    rows = state.tree.rows
    n = max(h - 1, 0)

    if rows == [] do
      empty = if state.tree.reading, do: "reading…", else: "no files"

      Screen.draw_text(screen, 1, 1, palette_clip(empty, inner - 1), %Cell{
        fg: pal.line_number,
        bg: pal.bg
      })
    else
      sel = min(state.tree.sel, length(rows) - 1)
      start = state.tree.top

      rows
      |> Enum.with_index()
      |> Enum.slice(start, n)
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{row, i}, y}, acc ->
        {bg, attrs} =
          if i == sel and focused?, do: {pal.active_line_bg, pal.mark}, else: {pal.bg, []}

        fg = if row.dir?, do: pal.line_number, else: pal.fg
        mark = if row.dir?, do: if(row.open?, do: "▾ ", else: "▸ "), else: "  "

        text =
          String.duplicate("  ", row.depth) <> mark <> row.name <> if(row.dir?, do: "/", else: "")

        acc
        |> Screen.fill_rect(0, y, inner, 1, %Cell{char: " ", fg: fg, bg: bg, attrs: attrs})
        |> Screen.draw_text(0, y, palette_clip(text, inner), %Cell{fg: fg, bg: bg, attrs: attrs})
      end)
    end
  end

  # The layout for this frame: the tree only once geex knows its root.
  defp layout(state) do
    Layout.resolve(state.w, state.h, %{
      edits: state.edits_shown,
      tree: state.tree_shown and safe_start().root != nil,
      tree_w: state.tree_w,
      edits_h: state.edits_h,
      least: Layout.least(state.panes.split)
    })
  end

  # Where the tree and the edits list start (ADR-0039): the row the wheel scrolled them to, until a
  # key acts on the list; else where they were, scrolled only as far as keeps the highlighted row in
  # view. (Before the mouse, the window was a function of the highlight alone, so Up from the
  # bottom row scrolled at once.)
  defp settle_lists(state, layout, entries) do
    state =
      case layout.tree do
        nil ->
          state

        rect ->
          rows = length(state.tree.rows)
          view = list_view(state.tree, min(state.tree.sel, max(rows - 1, 0)), rect.h - 1, rows)
          %{state | tree: Map.merge(state.tree, view)}
      end

    case layout.edits do
      nil ->
        state

      rect ->
        n = length(entries)
        sel = min(state.edits_sel, max(n - 1, 0))
        view = list_view(state.edits_view, sel, rect.h - 1, n)
        # The entries as drawn: a click picks from what you saw.
        %{state | edits_view: Map.merge(state.edits_view, Map.put(view, :entries, entries))}
    end
  end

  defp list_view(%{top: top, hold: hold}, sel, rows, count) do
    held? = hold != nil and hold == sel
    top = if held?, do: top, else: scroll_for(top, sel, rows, 0)
    %{top: top |> min(max(count - rows, 0)) |> max(0), hold: if(held?, do: hold)}
  end

  # Which pane has focus, of those on screen (a pane a resize hid gives it back to the editor).
  defp focused(state, layout) do
    case state.focus do
      :edits when layout.edits != nil -> :edits
      :tree when layout.tree != nil -> :tree
      _ -> :editor
    end
  end

  ## The settings view (`Alt+Y`, ADR-0040 §7). `Geex.Loop.Settings` is the view; here is what its
  ## actions do to the editor.

  defp open_settings(state) do
    view =
      case state.hinted do
        [lang | _] -> Settings.open(:languages, settings_ctx(state), lang)
        [] -> Settings.open(:languages, settings_ctx(state))
      end

    # Another geex may have installed something since: read the directories again.
    Geex.Installed.refresh()
    %{state | settings: view, settings_theme: state.theme_id}
  end

  defp settings_ctx(state) do
    %{
      theme_id: state.theme_id,
      mouse: state.mouse,
      tree_shown: state.tree_shown,
      edits_shown: state.edits_shown,
      installing: MapSet.new(Map.keys(state.installing))
    }
  end

  defp settings_rows(view, state), do: Settings.rows(view, settings_ctx(state))

  defp say(%{settings: %Settings{} = view} = state, message),
    do: %{state | settings: Settings.say(view, message)}

  defp say(state, message), do: %{state | notice: message}

  defp settings_action(:none, state), do: state
  defp settings_action(:quit, state), do: apply_action(:quit, {0, 0}, "", state)

  # Closing without choosing a theme puts back the one in use when the view opened.
  defp settings_action(:close, state) do
    state = %{state | settings: nil}

    if state.theme_id != state.settings_theme and is_binary(state.settings_theme),
      do: retheme(state, state.settings_theme),
      else: state
  end

  defp settings_action({:install, name}, state), do: start_install(state, name, nil)

  defp settings_action({:preview_theme, name}, state), do: retheme(state, name)

  defp settings_action({:choose_theme, name}, state) do
    if name in Theme.names() do
      state = retheme(state, name)

      if state.theme_id == name do
        keep(%{state | settings_theme: name}, "theme", name, "theme #{name} kept")
      else
        state
      end
    else
      start_install(state, name, {:choose_theme, name})
    end
  end

  defp settings_action({:toggle, :mouse}, state) do
    on? = not state.mouse
    TerminalIO.set_mouse(on?)
    keep(%{state | mouse: on?, drag: nil}, "mouse", on?, "mouse #{if on?, do: "on", else: "off"}")
  end

  defp settings_action({:toggle, :tree}, state) do
    shown = not state.tree_shown
    state = %{state | tree_shown: shown, focus: if(shown, do: state.focus, else: :editor)}
    state = if shown, do: reload_tree(state), else: state
    keep(state, "tree", shown, "the tree #{if shown, do: "shows", else: "stays hidden"} at start")
  end

  defp settings_action({:toggle, :edits}, state) do
    shown = not state.edits_shown
    state = %{state | edits_shown: shown, focus: if(shown, do: state.focus, else: :editor)}

    keep(
      state,
      "edits",
      shown,
      "the edits pane #{if shown, do: "shows", else: "stays hidden"} at start"
    )
  end

  # Keep a setting across starts (`Geex.Settings`), and say so, or that it couldn't be written.
  defp keep(state, key, value, message) do
    case Geex.Settings.put(key, value) do
      :ok ->
        say(state, message)

      {:error, reason} ->
        say(state, "#{message}, for now: #{Geex.Settings.path()}: #{inspect(reason)}")
    end
  end

  # An install runs in a process of its own (ADR-0035: a download is slow work), which answers
  # `{:geex_install_done, …}`. `then` is what to do when it succeeds.
  defp start_install(state, name, then) do
    if Map.has_key?(state.installing, name) do
      state
    else
      loop = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(loop, {:geex_install_done, self(), name, Geex.Install.install(name)})
        end)

      state = %{
        state
        | installing: Map.put(state.installing, name, %{pid: pid, ref: ref, then: then})
      }

      say(state, "installing #{name}…")
    end
  end

  # Show the theme named `id`, built again: the terminal theme from the terminal's background as
  # known now, a bundled one from its file. A file that won't load keeps the theme shown, and
  # its name.
  defp retheme(state, id \\ nil)

  defp retheme(state, nil), do: retheme(state, state.theme_id)

  defp retheme(state, "terminal" = id),
    do: schedule_repaint(%{state | theme_id: id, theme: Theme.Terminal.theme(state.terminal_bg)})

  defp retheme(state, id) do
    case Theme.named(id) do
      {:ok, theme} ->
        schedule_repaint(%{state | theme_id: id, theme: theme})

      {:error, reason} ->
        schedule_repaint(%{state | notice: "theme #{id} didn't load: #{inspect(reason)}"})
    end
  end

  # Read the root's files the first time the tree is drawn.
  defp ensure_tree(%{tree_shown: true, tree: %{index: nil}} = state), do: reload_tree(state)
  defp ensure_tree(state), do: state

  # Read the root's files in a process of their own, so a huge root never holds up the editor:
  # the rows shown stay until its `{:geex_tree, …}` arrives. One read at a time. Monitored,
  # not linked: if it crashes, the loop says so and carries on.
  defp reload_tree(%{tree: %{reading: {_, _}}} = state), do: state

  defp reload_tree(state) do
    case safe_start().root do
      nil ->
        state

      root ->
        loop = self()
        reader = spawn_monitor(fn -> send(loop, {:geex_tree, self(), read_tree(root, loop)}) end)
        put_in(state.tree.reading, reader)
    end
  end

  # The read also hands the watcher the directories it found, so new files there are seen.
  defp read_tree(root, loop) do
    files = Tree.list(root)
    Tree.Watcher.watch(root, Tree.Watcher.dirs_of(files), loop)
    {Finder.pack(files), Tree.index(files)}
  end

  # Search the files for the finder's query (Alt+O), in a process of its own: the list can be
  # huge (ADR-0035). The previous search is dropped first, so only the newest query's answer
  # counts. A blank query lists the files in order, which costs nothing. No list yet: the
  # tree's read is on its way, and its answer calls this again.
  defp refresh_matches(
         %{minibuffer: %Minibuffer{mode: :files} = mb, tree: %{files: files}} = state
       )
       when is_binary(files) do
    state = stop_matching(state)
    query = Minibuffer.value(mb)

    if String.trim(query) == "" do
      put_in(state.finder.matches, Finder.first(files, @finder_limit))
    else
      loop = self()

      matcher =
        spawn_monitor(fn ->
          send(loop, {:geex_matches, self(), Finder.match(files, query, @finder_limit)})
        end)

      put_in(state.finder.matching, matcher)
    end
  end

  defp refresh_matches(state), do: state

  defp stop_matching(%{finder: %{matching: {pid, ref}}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    put_in(state.finder.matching, nil)
  end

  defp stop_matching(state), do: state

  defp edits_entries do
    EditsPane.entries(Session.buffers(), safe_edits_rows(), safe_start().root)
  catch
    :exit, _ -> []
  end

  # Alt+P: the next pane on screen, in the order tree · each file pane (reading order) · edits,
  # wrapping (ADR-0038).
  defp next_pane(state) do
    l = layout(state)
    files = for id <- Panes.ids(state.panes), do: {:file, id}
    panes = if(l.tree, do: [:tree], else: []) ++ files ++ if(l.edits, do: [:edits], else: [])

    case panes do
      [{:file, _}] ->
        %{state | notice: "no other pane: the tree and edits pane are hidden (Alt+T, Alt+L)"}

      _ ->
        here =
          case focused(state, l) do
            :editor -> {:file, state.panes.pane}
            pane -> pane
          end

        i = Enum.find_index(panes, &(&1 == here)) || 0
        enter_pane(Enum.at(panes, rem(i + 1, length(panes))), state)
    end
  end

  # The edits pane starts at its newest entry; the tree re-reads the files; a file pane becomes
  # current, and its tab Session's active buffer.
  defp enter_pane(:edits, state),
    do: %{state | focus: :edits, edits_sel: 0, edits_view: %{state.edits_view | hold: nil}}

  defp enter_pane(:tree, state) do
    state = reload_tree(state)
    %{state | focus: :tree, tree: %{state.tree | hold: nil}}
  end

  defp enter_pane(state, {:file, _id} = pane), do: enter_pane(pane, state)

  defp enter_pane({:file, id}, state) do
    state = if id == state.panes.pane, do: state, else: switch(state, &Panes.focus(&1, id))
    %{state | focus: :editor}
  end

  # Keys while the tree has focus: move, Enter opens a file or opens/closes a directory,
  # Right opens one, Left closes one (or, on a file, goes up to its directory), Esc goes back.
  # Alt+W/A/S/D act as the arrows, as they do in the editor. The panel chords work as in the
  # edits pane (`panel_chord/2`); other keys do nothing.
  defp apply_tree_key({:alt, c}, state) when c in [?a, ?A],
    do: apply_tree_key({:key, :left}, state)

  defp apply_tree_key({:alt, c}, state) when c in [?d, ?D],
    do: apply_tree_key({:key, :right}, state)

  defp apply_tree_key(event, state) do
    # A key shows the highlighted row again, wherever the wheel left the list (ADR-0039).
    tree_key(event, put_in(state.tree.hold, nil))
  end

  defp tree_key(event, %{tree: tree} = state) do
    count = length(tree.rows)
    row = Enum.at(tree.rows, min(tree.sel, count - 1))

    case event do
      e when e in [{:key, :up}, {:alt, ?w}, {:alt, ?W}] ->
        schedule_repaint(put_in(state.tree.sel, max(min(tree.sel, count - 1) - 1, 0)))

      e when e in [{:key, :down}, {:alt, ?s}, {:alt, ?S}] ->
        schedule_repaint(put_in(state.tree.sel, min(tree.sel + 1, max(count - 1, 0))))

      {:key, :enter} when is_map(row) and row.dir? ->
        schedule_repaint(set_open(state, row.path, not row.open?))

      {:key, :enter} when is_map(row) ->
        schedule_repaint(
          do_open(Path.join(safe_start().root, row.path), %{state | focus: :editor})
        )

      {:key, :right} when is_map(row) and row.dir? ->
        schedule_repaint(set_open(state, row.path, true))

      {:key, :left} when is_map(row) and row.dir? and row.open? ->
        schedule_repaint(set_open(state, row.path, false))

      # On a file or a closed directory, Left goes up to the directory it is in.
      {:key, :left} when is_map(row) ->
        parent = Path.dirname(row.path)
        i = Enum.find_index(tree.rows, &(&1.path == parent))
        schedule_repaint(if i, do: put_in(state.tree.sel, i), else: state)

      e when e in [{:key, :esc}] ->
        schedule_repaint(%{state | focus: :editor})

      _ ->
        panel_chord(event, state)
    end
  end

  # The chords that work from either panel (ADR-0037): the minibuffer, the palette, the next
  # pane, open a file, show or hide the tree and the edits pane, and quitting. The openers go
  # through the same branches the editor's keys use (`apply_key/4`); `apply_action/4` has no
  # clause for them.
  @panel_actions [:next_pane, :find_file, :toggle_tree, :toggle_edits, :quit]

  defp panel_chord(event, state) do
    case Keymap.resolve(event, {0, 0}, "") do
      :minibuffer -> open_minibuffer(state)
      :palette -> schedule_repaint(%{state | minibuffer: Minibuffer.open(:palette)})
      action when action in @panel_actions -> apply_action(action, {0, 0}, "", state)
      _ -> state
    end
  end

  defp set_open(%{tree: tree} = state, dir, open?) do
    open = if open?, do: MapSet.put(tree.open, dir), else: MapSet.delete(tree.open, dir)
    %{state | tree: %{tree | open: open, rows: Tree.rows(tree.index || %{}, open)}}
  end

  # Keys while the edits pane has focus: move, Enter, back to the editor. The minibuffer, the
  # palette and quitting work from here too; other keys do nothing (they'd edit a buffer you
  # aren't looking at).
  defp apply_edits_key(event, state) do
    state = put_in(state.edits_view.hold, nil)
    count = length(edits_entries())

    case event do
      e when e in [{:key, :up}, {:alt, ?w}, {:alt, ?W}] ->
        schedule_repaint(%{state | edits_sel: max(min(state.edits_sel, count - 1) - 1, 0)})

      e when e in [{:key, :down}, {:alt, ?s}, {:alt, ?S}] ->
        schedule_repaint(%{state | edits_sel: min(state.edits_sel + 1, max(count - 1, 0))})

      {:key, :enter} ->
        case Enum.at(edits_entries(), min(state.edits_sel, count - 1)) do
          nil -> state
          entry -> schedule_repaint(open_entry(entry, %{state | focus: :editor}))
        end

      {:key, :esc} ->
        schedule_repaint(%{state | focus: :editor})

      _ ->
        panel_chord(event, state)
    end
  end

  # Enter on an entry: a "disk is newer" row opens the file and fast-forwards it; any other row
  # opens the file, at the first line that write changed when its group is in the history.
  defp open_entry(%{kind: :behind, path: path}, state) do
    case open_tab(path, state) do
      {:ok, _pid, state} -> do_fast_forward(state)
      {:error, reason, state} -> %{state | notice: "couldn't open #{path}: #{inspect(reason)}"}
    end
  end

  defp open_entry(%{kind: :edit, path: path, row: row}, state) do
    case open_tab(path, state) do
      {:ok, pid, state} ->
        if line = row.tool_use && first_line_of(pid, row.tool_use), do: set_cursor({line, 0})
        state

      {:error, reason, state} ->
        %{state | notice: "couldn't open #{path}: #{inspect(reason)}"}
    end
  end

  # The first line still credited to the group that tool call's write landed in.
  defp first_line_of(pid, tool_use) do
    snap = Buffer.snapshot(pid)

    group =
      Enum.find_value(snap.history, fn %{meta: meta} ->
        with %{group: group} = stamp <- meta.reconcile,
             true <-
               match?({:agent, %{tool_use: ^tool_use}}, meta.actor) or
                 tool_use in Map.get(stamp, :chain, []) do
          group
        else
          _ -> nil
        end
      end)

    group && Enum.find_index(snap.blame, &match?({_actor, ^group}, &1))
  catch
    :exit, _ -> nil
  end

  defp safe_edits_rows do
    Edits.rows()
  catch
    :exit, _ -> []
  end

  defp safe_subscribe_edits do
    Edits.subscribe(self())
  catch
    :exit, _ -> :ok
  end

  defp safe_start do
    Session.start()
  catch
    :exit, _ -> %{dir: nil, root: nil}
  end

  # What the popup lists: the command catalog, the open buffers (ADR-0034), or the finder's
  # files, filtered by the input. Draw, Enter and the highlight moves all read it, so they agree
  # on what is where.
  defp candidates(%{minibuffer: %Minibuffer{mode: :palette} = mb}),
    do: Catalog.search(Minibuffer.value(mb))

  defp candidates(%{minibuffer: %Minibuffer{mode: :buffers} = mb}),
    do: buffer_candidates(Minibuffer.value(mb))

  # The file's name, then the directory it is in.
  defp candidates(%{minibuffer: %Minibuffer{mode: :files}, finder: finder}) do
    for path <- finder.matches do
      dir = Path.dirname(path)

      %{
        name: Path.basename(path),
        description: if(dir == ".", do: "", else: dir),
        invoke: {:file, path}
      }
    end
  end

  # One row per open buffer, most recent first: the file name (with ` [+]` when it has unsaved
  # edits) and where it is. A filter keeps the rows it fuzzy-matches, best first.
  defp buffer_candidates(query) do
    rows =
      for %{pid: pid, path: path, dirty: dirty} <- Session.buffers() do
        %{
          name: status_label(path) <> if(dirty, do: " [+]", else: ""),
          description: if(path, do: EditsPane.relative(path, safe_start().root), else: ""),
          invoke: {:buffer, pid}
        }
      end

    case String.trim(query) do
      "" ->
        rows

      q ->
        rows
        |> Enum.map(&{&1, Fuzzy.score(&1.name <> " " <> &1.description, q)})
        |> Enum.reject(fn {_row, score} -> is_nil(score) end)
        |> Enum.sort_by(fn {_row, score} -> -score end)
        |> Enum.map(fn {row, _score} -> row end)
    end
  end

  # Commands line up at a fixed column; buffer names at the longest one, up to half the width.
  defp name_col(:palette, _candidates, _w), do: @palette_name_col

  defp name_col(mode, candidates, w) when mode in [:buffers, :files] do
    longest = candidates |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end)
    min(longest + 2, max(div(w, 2), 1))
  end

  # One candidate row: `name` padded to a column, then its description, on the theme bg —
  # or the active-line tint when highlighted (the Enter target).
  defp draw_palette_row(screen, entry, y, selected?, %{w: w, theme: %Theme{palette: pal}}, col) do
    {bg, attrs} = if selected?, do: {pal.active_line_bg, pal.mark}, else: {pal.bg, []}
    name_fg = if selected?, do: pal.fg, else: pal.active_line_number
    label = String.pad_trailing(entry.name, col)

    screen
    |> Screen.fill_rect(0, y, w, 1, %Cell{char: " ", fg: pal.fg, bg: bg, attrs: attrs})
    |> Screen.draw_text(0, y, palette_clip(label <> entry.description, w), %Cell{
      fg: name_fg,
      bg: bg,
      attrs: attrs
    })
    # Re-tint the description (past the name column) in the dimmer fg so the name stands out.
    |> Screen.draw_text(
      col,
      y,
      palette_clip(entry.description, w - col),
      %Cell{
        fg: pal.line_number,
        bg: bg,
        attrs: attrs
      }
    )
  end

  defp empty_hint(%{minibuffer: %Minibuffer{mode: :buffers}}), do: "(no buffers match)"
  defp empty_hint(%{minibuffer: %Minibuffer{mode: :palette}}), do: "(no commands match)"
  defp empty_hint(%{tree: %{files: nil}}), do: "(reading the files…)"
  defp empty_hint(%{finder: %{matching: {_, _}}}), do: "(searching…)"
  defp empty_hint(_state), do: "(no files match)"

  # Nothing to list: a single dim hint row just above the input.
  defp draw_palette_empty(screen, %{w: w, h: h, theme: %Theme{palette: pal}}, hint) do
    y = h - 2

    if y >= 0 do
      screen
      |> Screen.fill_rect(0, y, w, 1, %Cell{char: " ", fg: pal.line_number, bg: pal.bg})
      |> Screen.draw_text(0, y, palette_clip(hint, w), %Cell{
        fg: pal.line_number,
        bg: pal.bg
      })
    else
      screen
    end
  end

  defp palette_clip(text, w),
    do: text |> String.graphemes() |> Enum.take(max(w, 0)) |> Enum.join()

  # Overlay the status line on the bottom row of `screen`: the buffer label + dirty
  # marker on the left, the 1-based `line:col` flush right, on a reverse-video bar
  # (theme fg/bg swapped — always-readable, theme-faithful chrome).
  defp draw_status(screen, %{w: w, h: h, theme: theme} = state, snap) do
    left =
      status_label(snap.path) <>
        if(snap.dirty, do: " [+]", else: "") <>
        if(snap[:behind], do: "  " <> @behind, else: "") <>
        if(state.notice, do: "  " <> state.notice, else: "")

    {line, _col} = snap.cursor

    right =
      case author_label(snap.blame, line) do
        nil -> position(snap.cursor)
        author -> author <> "  " <> position(snap.cursor)
      end

    Screen.draw_text(screen, 0, h - 1, status_text(left, right, w), status_style(theme))
  end

  @doc """
  The status-line author of `line`, from the buffer's blame (`Geex.Blame`): who last wrote
  it, when that was an agent. An attested write reads `✎ <harness>/<session>`, the session
  cut to 8 characters (the tag captAInHook writes into shell history), then the turn cut
  to 4. An MCP edit reads `✎ llm/<model>`. `nil` for your own lines, lines as loaded, and
  unattested out-of-band writes (ADR-0032).
  """
  @spec author_label(Geex.Blame.t(), non_neg_integer()) :: String.t() | nil
  def author_label(blame, line) do
    case Enum.at(blame, line) do
      {{:agent, %{harness: harness, session: session} = who}, _group} ->
        "✎ " <>
          harness <>
          "/" <>
          String.slice(session, 0, 8) <>
          turn_label(who[:turn]) <>
          edited_by_you(who)

      {{:llm, model}, _group} ->
        "✎ llm/" <> to_string(model)

      _ ->
        nil
    end
  end

  defp turn_label(turn) when is_binary(turn), do: " · turn " <> String.slice(turn, 0, 4) <> "…"
  defp turn_label(_turn), do: ""

  # You edited the agent's change in the permission prompt before accepting it (ADR-0034 §8).
  defp edited_by_you(%{user_modified: true}), do: " · edited by you"
  defp edited_by_you(_who), do: ""

  @doc """
  Mark the gutter's left margin column with `▌`, in the theme's accent (`cursor`) colour, on
  each visible row whose line an agent last wrote (an attested write or an MCP edit). The
  cell's background is kept, so the mark sits on the cursor-line tint too. Derived from the
  blame on every frame, so an edit, undo or late attestation moves or clears it.
  """
  @spec agent_marks(Screen.t(), Geex.Blame.t(), non_neg_integer(), non_neg_integer(), Theme.t()) ::
          Screen.t()
  def agent_marks(screen, blame, scroll, h, %Theme{palette: pal}) do
    blame
    |> Enum.slice(scroll, h)
    |> Enum.with_index()
    |> Enum.reduce(screen, fn
      {{{kind, _}, _group}, row}, acc when kind in [:agent, :llm] ->
        Screen.set_cell(acc, 0, row, %{Screen.get_cell(acc, 0, row) | char: "▌", fg: pal.cursor})

      _unmarked, acc ->
        acc
    end)
  end

  defp draw_empty_status(screen, %{w: w, h: h, theme: theme}) do
    Screen.draw_text(screen, 0, h - 1, status_text("[no buffer]", "", w), status_style(theme))
  end

  defp status_label(nil), do: "[scratch]"
  defp status_label(path) when is_binary(path), do: Path.basename(path)

  defp position({line, col}), do: "#{line + 1}:#{col + 1}"

  # Reverse video, not fg and bg swapped: the terminal theme's are both `:default` (ADR-0040).
  defp status_style(%Theme{palette: p}), do: %Cell{fg: p.fg, bg: p.bg, attrs: [:reverse]}

  # Draw the line-number gutter over the left `gw` columns: each visible text row gets
  # its 1-based logical line number, right-aligned, in the theme's line-number colour —
  # the cursor's line brightened (active_line_number). Rows past end-of-file keep the
  # background Paint already filled. (ADR-0027: this number is the command grid's `y`.)
  defp draw_gutter(screen, text, %Theme{palette: pal}, h, scroll, gw, cursor_line) do
    lines = line_count(text)
    digits = gw - 2

    Enum.reduce(0..(h - 1)//1, screen, fn row, acc ->
      line = scroll + row

      if line < lines do
        label = " " <> String.pad_leading(Integer.to_string(line + 1), digits) <> " "
        fg = if line == cursor_line, do: pal.active_line_number, else: pal.line_number
        Screen.draw_text(acc, 0, row, label, %Cell{fg: fg, bg: pal.bg})
      else
        acc
      end
    end)
  end

  # Tint the cursor's whole row (gutter + text) with the theme's active-line background —
  # the "current line" highlight that follows the cursor. Only the cell backgrounds change
  # (chars + fg, incl. the brightened active line number, are untouched). A no-op off-screen.
  defp highlight_line(screen, w, row, bg) when row >= 0 do
    Enum.reduce(0..(w - 1)//1, screen, fn x, acc ->
      Screen.set_cell(acc, x, row, %{Screen.get_cell(acc, x, row) | bg: bg})
    end)
  end

  defp highlight_line(screen, _w, _row, _bg), do: screen

  @doc """
  A scroll bar thumb as `{offset, length}` along one axis: for a `viewport` of cells showing
  `content` cells total, scrolled to `offset`, the thumb length is proportional to the visible
  fraction (at least one cell) and its position is proportional to how far the scroll is. Used
  for both the vertical bar (rows over lines) and the horizontal bar (columns over line width).
  """
  @spec scrollbar_thumb(pos_integer(), pos_integer(), non_neg_integer()) ::
          {non_neg_integer(), pos_integer()}
  def scrollbar_thumb(viewport, content, offset) do
    len = max(div(viewport * viewport, content), 1)
    span = max(viewport - len, 0)
    pos = min(div(offset * span, max(content - viewport, 1)), span)
    {pos, len}
  end

  @doc """
  The widest display width among **all** lines of `text` — the horizontal extent the buffer
  can scroll to. Used (not the visible-only width) so the horizontal bar's presence and thumb
  size stay stable as you scroll *vertically*; only the thumb position tracks `hscroll`.
  """
  @spec max_line_width(String.t()) :: non_neg_integer()
  def max_line_width(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(0, fn line, acc -> max(acc, Width.string(line)) end)
  end

  # Draw the vertical scroll bar in column `x` over rows `0..h-1`: a dim track with a brighter
  # thumb (the accent/cursor colour) marking the visible slice. Shown only when the buffer
  # overflows the viewport (the caller's `vbar?`).
  defp maybe_vscrollbar(screen, false, _x, _h, _scroll, _total, _theme), do: screen

  defp maybe_vscrollbar(screen, true, x, h, scroll, total, %Theme{palette: pal}) do
    {top, len} = scrollbar_thumb(h, total, scroll)
    # A light vertical track with a heavy, accent-coloured thumb — both centred rules (not a
    # full block), so the bar reads as a thin line, matching the horizontal bar's weight.
    track = %Cell{char: "│", fg: pal.line_number, bg: pal.bg}
    thumb = %Cell{char: "┃", fg: pal.cursor, bg: pal.bg}

    Enum.reduce(0..(h - 1)//1, screen, fn row, acc ->
      Screen.set_cell(acc, x, row, if(row >= top and row < top + len, do: thumb, else: track))
    end)
  end

  # Draw the (permanently reserved) horizontal scroll bar row at `h-2`: first fill it with the
  # theme background (so the reserved space is themed even with no bar), then — only when a
  # visible line is wider than the text area — draw a dim track + bright thumb across the text
  # columns `[gw, gw + text_w)`, the thumb sized/placed by `hscroll` over the widest line.
  defp draw_hbar(
         screen,
         %{w: w, h: h, theme: %Theme{palette: pal}},
         gw,
         text_w,
         content_w,
         hscroll
       ) do
    row = h - 2
    screen = Screen.fill_rect(screen, 0, row, w, 1, %Cell{char: " ", fg: pal.fg, bg: pal.bg})

    if row >= 0 and text_w > 0 and content_w > text_w do
      {left, len} = scrollbar_thumb(text_w, content_w, hscroll)
      # Both are vertically-centred horizontal rules (not full blocks), so the bar reads as a
      # thin line rather than a chunky band: a light track with a heavy, accent-coloured thumb.
      track = %Cell{char: "─", fg: pal.line_number, bg: pal.bg}
      thumb = %Cell{char: "━", fg: pal.cursor, bg: pal.bg}

      Enum.reduce(0..(text_w - 1)//1, screen, fn i, acc ->
        Screen.set_cell(
          acc,
          gw + i,
          row,
          if(i >= left and i < left + len, do: thumb, else: track)
        )
      end)
    else
      screen
    end
  end

  defp cursor_target(w, h_text, x, y) when x >= 0 and x < w and y >= 0 and y < h_text, do: {x, y}
  defp cursor_target(_w, _h_text, _x, _y), do: :hidden

  # Grid mode is active iff the minibuffer is open in `:grid` mode — the trigger for the
  # contextual ruler + grid-line overlay (ADR-0027 §"Render": chrome only while composing).
  defp grid_mode?(%{minibuffer: %Minibuffer{mode: :grid}}), do: true
  defp grid_mode?(_state), do: false

  # The x-axis **ruler** (ADR-0027 amendment) on the reserved top row: a spreadsheet-style
  # display-column header over the text columns `[gw, gw + text_w)`, locked to `hscroll`. Most
  # columns show their 1-based **display** column's units digit (`…789…`); every **tens** column
  # (a multiple of 10) shows its *tens* digit instead, brightened — so column 40 reads `4`, 45 is
  # five cells past it, and a two-digit `x` like `45` is legible at a glance rather than counting
  # 0-markers. (Past 99 the tens digit cycles: 100 → `0`, 110 → `1`.)
  defp draw_ruler(screen, false, _gw, _text_w, _hscroll, _theme), do: screen

  defp draw_ruler(screen, true, gw, text_w, hscroll, %Theme{palette: pal}) do
    screen =
      Screen.fill_rect(screen, 0, 0, gw + text_w, 1, %Cell{
        char: " ",
        fg: pal.line_number,
        bg: pal.bg
      })

    Enum.reduce(0..(text_w - 1)//1, screen, fn i, acc ->
      d = i + hscroll + 1
      tens? = rem(d, 10) == 0
      digit = if tens?, do: rem(div(d, 10), 10), else: rem(d, 10)
      fg = if tens?, do: pal.active_line_number, else: pal.line_number

      Screen.set_cell(acc, gw + i, 0, %Cell{
        char: Integer.to_string(digit),
        fg: fg,
        bg: pal.bg
      })
    end)
  end

  # The **grid-line overlay** (the user's marking aid): faint dotted vertical rules every 5th
  # display column across the text rows, the every-10th rules brightened (the accent colour) —
  # two-tone "multicoloured", palette-derived. Drawn only on **blank** cells (indent gaps, short-
  # line tails, empty lines) — indent-guide style, so a glyph is never overwritten; a wide glyph's
  # continuation cell (char "") is skipped too. The rule sits under its ruler tick (same column).
  defp draw_grid_lines(screen, false, _gw, _text_w, _h_text, _top, _hscroll, _theme), do: screen
  defp draw_grid_lines(screen, true, _gw, 0, _h_text, _top, _hscroll, _theme), do: screen

  defp draw_grid_lines(screen, true, gw, text_w, h_text, top, hscroll, %Theme{palette: pal}) do
    rows = top..(top + h_text - 1)//1

    Enum.reduce((hscroll + 1)..(hscroll + text_w)//1, screen, fn d, acc ->
      if rem(d, 5) == 0 do
        sx = gw + (d - 1 - hscroll)
        fg = if rem(d, 10) == 0, do: pal.cursor, else: pal.line_number

        Enum.reduce(rows, acc, fn row, acc2 ->
          if Screen.get_cell(acc2, sx, row).char == " ",
            do:
              Screen.set_cell(acc2, sx, row, %{Screen.get_cell(acc2, sx, row) | char: "┊", fg: fg}),
            else: acc2
        end)
      else
        acc
      end
    end)
  end

  # Resolve a key to an action and apply it. The event-shaped results ({:move, ...},
  # {:edit, ...}, :minibuffer, :ignore) are handled here; every plain action atom goes
  # through apply_action/4 — the **shared action vocabulary** the typed verbs
  # (`Geex.Loop.Verbs`) also apply through, so `copy` and `Alt+C` converge on one code
  # path (the ADR-0028 parity principle, ADR-0003 in miniature).
  defp apply_key(event, cursor, text, state) do
    case Keymap.resolve(event, cursor, text) do
      :ignore ->
        state

      :minibuffer ->
        open_minibuffer(state)

      :grid ->
        # Open the minibuffer in grid mode; the repaint shows the ruler + grid-line overlay
        # (ADR-0027). Handled here (not apply_action) so it is never reached from a typed verb,
        # where submit_minibuffer's trailing close would immediately clobber the mode.
        schedule_repaint(%{state | minibuffer: Minibuffer.open(:grid)})

      :palette ->
        # Open the command palette (ADR-0028 §3): the repaint shows the fuzzy candidate popup
        # over `Geex.Command.Catalog`. Like grid, handled here (not apply_action) so it is a
        # chord-only opener, never re-entered from a typed verb.
        schedule_repaint(%{state | minibuffer: Minibuffer.open(:palette)})

      {:move, new_cursor} ->
        schedule_repaint(apply_move(state, event, new_cursor, text))

      {:edit, cmd, new_cursor} ->
        # An edit is never a vertical move; refresh the goal from the post-edit cursor +
        # text (so typing at a line end leaves the goal at `:eol`, tracking ends below).
        # Editing collapses any selection (you replaced/typed over the region of interest).
        # Edits go through the **one shared path** (Dispatch.run, human provenance); the
        # buffer's change notification also repaints, but schedule one anyway so a failed
        # dispatch still refreshes.
        state =
          case safe_dispatch(cmd) do
            {:ok, %{text: text_after}} ->
              set_cursor(new_cursor)
              %{state | goal: Keymap.goal_column(new_cursor, text_after), selection: nil}

            _ ->
              state
          end

        schedule_repaint(state)

      action when is_atom(action) or is_tuple(action) ->
        apply_action(action, cursor, text, state)
    end
  end

  # Apply one plain action against the current cursor + text — reached from a chord
  # (apply_key) or a typed verb (submit_minibuffer). Quit stops the VM so the app's
  # shutdown restores the terminal.
  defp apply_action(action, cursor, text, state) do
    case action do
      :select_start ->
        # Anchor a selection at the cursor; subsequent motion extends it (ADR-0029).
        schedule_repaint(%{state | selection: Selection.new(cursor)})

      :select_all ->
        last = end_caret(text)
        set_cursor(last)
        sel = Selection.new({0, 0}) |> Selection.extend(last)
        schedule_repaint(%{state | selection: sel, goal: Keymap.goal_column(last, text)})

      :select_clear ->
        schedule_repaint(%{state | selection: nil})

      :copy ->
        schedule_repaint(do_copy(state, text))

      :cut ->
        schedule_repaint(do_cut(state, text))

      :paste ->
        schedule_repaint(do_paste(state, cursor))

      :undo ->
        schedule_repaint(do_undo(state))

      :revert_hunk ->
        schedule_repaint(do_revert(state, cursor, :hunk))

      :revert_call ->
        schedule_repaint(do_revert(state, cursor, :call))

      :redo ->
        schedule_repaint(do_redo(state))

      :save ->
        do_save(state)

      :fast_forward ->
        schedule_repaint(do_fast_forward(state))

      :next_pane ->
        schedule_repaint(next_pane(state))

      # Split panes and tabs (ADR-0038). The new pane shows the same tab and becomes current.
      :split_rows ->
        schedule_repaint(split(state, :rows))

      :split_cols ->
        schedule_repaint(split(state, :cols))

      :tab_next ->
        schedule_repaint(switch(state, &Panes.step(&1, 1)))

      :tab_prev ->
        schedule_repaint(switch(state, &Panes.step(&1, -1)))

      {:tab, i} ->
        schedule_repaint(switch(state, &Panes.select(&1, i)))

      # Alt+O (ADR-0037): the file finder over the root's files, read again in the background
      # so new files show up. With no root (geex started on nothing), the minibuffer, ready for
      # `open PATH`.
      :find_file ->
        if safe_start().root do
          state = %{state | minibuffer: Minibuffer.open(:files)}
          schedule_repaint(state |> reload_tree() |> refresh_matches())
        else
          schedule_repaint(%{state | minibuffer: Minibuffer.open(:command, "open ")})
        end

      :toggle_tree ->
        shown = not state.tree_shown
        state = %{state | tree_shown: shown, focus: if(shown, do: state.focus, else: :editor)}
        schedule_repaint(if shown, do: reload_tree(state), else: state)

      :toggle_edits ->
        shown = not state.edits_shown

        schedule_repaint(%{
          state
          | edits_shown: shown,
            focus: if(shown, do: state.focus, else: :editor)
        })

      :buffers ->
        # The open buffers in the palette's popup, the previous one highlighted (ADR-0034).
        mb = Minibuffer.open(:buffers)
        mb = if length(Session.buffers()) > 1, do: Minibuffer.select(mb, 1), else: mb
        schedule_repaint(%{state | minibuffer: mb})

      :close ->
        schedule_repaint(do_close(state))

      :toggle_mouse ->
        on? = not state.mouse
        TerminalIO.set_mouse(on?)

        notice =
          if on?,
            do: "mouse on",
            else:
              "mouse off: the terminal selects and copies text again (`mouse` turns it back on)"

        schedule_repaint(%{state | mouse: on?, drag: nil, notice: notice})

      # `theme` and `theme NAME` (ADR-0040): this session only, until the settings view keeps one.
      {:theme, nil} ->
        names =
          Enum.map_join(Theme.names(), ", ", &if(&1 == state.theme_id, do: "#{&1} *", else: &1))

        schedule_repaint(%{state | notice: "themes: #{names}"})

      {:theme, name} ->
        if name in Theme.names(),
          do: retheme(state, name),
          else: schedule_repaint(%{state | notice: "no theme #{name} (`theme` lists them)"})

      :quit ->
        Geex.stop()
        state
    end
  end

  # Save the active buffer (Ctrl-O / the `save` verb) — an operation, not an edit
  # (ADR-0019): no command, no history. Visible feedback is the status line's dirty
  # marker clearing; `Buffer.save/1` emits no change event, so repaint explicitly. A buffer
  # that is behind merges first (ADR-0034 §3); a merge with conflicts doesn't write, and the
  # buffer's own notice says so. A failure (`{:error, :no_path}` on a scratch buffer, a posix
  # error) leaves the marker set — a real echo/message area is a deferred minibuffer slice.
  defp do_save(state) do
    state =
      case on_active_buffer(&Reconcile.save(&1, force: state.save_armed)) do
        {:ok, path} ->
          Edits.saved(path)
          %{state | save_armed: false}

        {:markers, line} ->
          %{
            state
            | notice:
                "not saved: a conflict block is left at line #{line + 1} (Ctrl-O again saves anyway)",
              save_armed: true
          }

        _saved_or_reported ->
          %{state | save_armed: false}
      end

    schedule_repaint(state)
  end

  # Show `path`, opening it if needed (`open PATH`, ADR-0034). A relative path is from the
  # current file's directory (the working directory is geex's own checkout, never yours).
  defp do_open(path, state) do
    full = resolve_path(path)

    cond do
      File.dir?(full) ->
        %{state | notice: "#{path} is a directory"}

      true ->
        # The file you opened is what you look at next, from whichever pane you opened it: a
        # tab in the current file pane.
        case open_tab(full, state) do
          {:ok, _pid, state} ->
            %{state | focus: :editor}

          {:error, reason, state} ->
            %{state | notice: "couldn't open #{path}: #{inspect(reason)}"}
        end
    end
  end

  defp resolve_path("~" <> _ = path), do: Path.expand(path)

  defp resolve_path(path) do
    # The current file's directory; for a pathless buffer, where geex was started (never the
    # working directory, which is geex's own checkout).
    base =
      case safe_session_snapshot() do
        {:ok, %{path: current}} when is_binary(current) -> Path.dirname(current)
        _ -> safe_start().dir || File.cwd!()
      end

    Path.expand(path, base)
  end

  # Alt+K / `close` (ADR-0038): close the current tab. A buffer still in another tab or pane stays
  # open; otherwise the buffer closes too, refused while it has unsaved edits. The pane then shows
  # the tab before; a pane left with none closes, unless it is the only one, which shows the
  # buffer before (Session's `close_active/0`, a new scratch buffer when none is left).
  @dirty "not closed: unsaved changes (save them, or undo them, first)"

  defp do_close(state) do
    case Panes.current(state.panes) do
      nil ->
        close_active(state)

      %{buffer: pid} ->
        name = status_label(safe_status(pid)[:path])
        rest = Panes.close_tab(state.panes)

        cond do
          Panes.elsewhere?(state.panes, pid) ->
            state = state |> put_panes(rest) |> enter()
            %{state | notice: "closed the tab; #{name} is still open in another pane"}

          match?(%{dirty: true}, safe_status(pid)) ->
            %{state | notice: @dirty}

          # The only pane's last tab: Session closes it and picks what to show next, which
          # `adopt_active/2` then shows. Only while Session agrees what that tab is.
          Panes.current(rest) == nil ->
            if safe_active_buffer() == {:ok, pid},
              do: close_active(state),
              else: state

          true ->
            state = state |> put_panes(rest) |> enter()

            case safe_close_buffer(pid) do
              {:ok, label} -> %{state | notice: "closed " <> Path.basename(label)}
              {:error, :dirty} -> %{state | notice: @dirty}
              {:error, _} -> state
            end
        end
    end
  end

  defp close_active(state) do
    notice =
      case Session.close_active() do
        {:ok, label} -> "closed " <> Path.basename(label)
        {:error, :dirty} -> @dirty
        {:error, :no_active_buffer} -> nil
      end

    %{state | notice: notice}
  end

  # Take in what the disk holds now (Alt+J / `fast-forward`, ADR-0034 §1). The buffer's change
  # notification repaints; a merge with conflicts sends its own notice.
  defp do_fast_forward(state) do
    notice =
      case on_active_buffer(&Reconcile.fast_forward/1) do
        {:fast_forwarded, snapshot, 0} -> "caught up with the disk" <> credited(snapshot)
        {:fast_forwarded, _snapshot, _conflicts} -> nil
        :up_to_date -> "already up to date with the disk"
        {:error, _reason} -> "couldn't read the file from disk"
      end

    %{state | notice: notice || state.notice, selection: nil}
  end

  defp credited(%{history: [_ | _] = history}) do
    case List.last(history).meta.actor do
      {:agent, _} = actor -> " (" <> who(actor) <> ")"
      _ -> ""
    end
  end

  defp credited(_snapshot), do: ""

  # A vertical move keeps the goal column (re-derive the landing column from it, so the
  # horizontal position is preserved across a run of up/down and sticks to line ends);
  # any other cursor move refreshes the goal from where it landed. A live selection
  # extends to the new cursor (the cursor *is* its active end, ADR-0029).
  defp apply_move(state, event, new_cursor, text) do
    {final, goal} =
      if Keymap.vertical?(event) do
        {Keymap.apply_goal(new_cursor, state.goal, text), state.goal}
      else
        {new_cursor, Keymap.goal_column(new_cursor, text)}
      end

    set_cursor(final)
    state = %{state | goal: goal}

    if state.selection,
      do: %{state | selection: Selection.extend(state.selection, final)},
      else: state
  end

  # The caret at the very end of the buffer — `{last line, its length}` — for select-all.
  defp end_caret(text) do
    lines = String.split(text, "\n")
    {length(lines) - 1, String.length(List.last(lines))}
  end

  ## Clipboard ops (ADR-0015). copy = ring push only (no edit); cut = ring push + a
  ## recorded delete; paste = a recorded insert (or replace, over a selection) baking the
  ## literal text. All consume + clear the selection.

  # A collapsed selection (e.g. Alt+H with no motion yet) selects nothing — copy/cut are
  # no-ops that leave you in highlight mode, never pushing "" or recording a no-op delete.
  defp do_copy(%{selection: nil} = state, _text), do: state

  defp do_copy(%{selection: sel} = state, _text)
       when is_struct(sel, Selection) and sel.anchor == sel.active, do: state

  defp do_copy(%{selection: sel} = state, text) do
    with {:ok, copied} <- Doc.slice(Doc.new(text), Selection.range(sel)),
         do: clip(copied)

    %{state | selection: nil}
  end

  defp do_cut(%{selection: nil} = state, _text), do: state

  defp do_cut(%{selection: sel} = state, _text)
       when is_struct(sel, Selection) and sel.anchor == sel.active, do: state

  defp do_cut(%{selection: sel} = state, text) do
    range = Selection.range(sel)
    {from, _to} = range

    with {:ok, cut_text} <- Doc.slice(Doc.new(text), range) do
      clip(cut_text)
      apply_clipboard_edit(state, replace_cmd(range, ""), from)
    else
      _ -> %{state | selection: nil}
    end
  end

  # geex's own clipboard, and the system's through the terminal (OSC 52, ADR-0039): with the mouse
  # on, the terminal's own selection can't copy.
  defp clip(text) do
    Clipboard.push(text)
    TerminalIO.copy(text)
  end

  defp do_paste(state, cursor) do
    case Clipboard.top() do
      "" ->
        state

      pasted ->
        {cmd, landing} =
          case state.selection do
            %Selection{} = sel ->
              {from, _to} = range = Selection.range(sel)
              {replace_cmd(range, pasted), cursor_after_insert(from, pasted)}

            nil ->
              {insert_cmd(cursor, pasted), cursor_after_insert(cursor, pasted)}
          end

        apply_clipboard_edit(state, cmd, landing)
    end
  end

  # Dispatch a clipboard-produced edit on the one shared path, then place the cursor and
  # refresh the goal from the post-edit text; always clears the selection.
  defp apply_clipboard_edit(state, cmd, landing) do
    case safe_dispatch(cmd) do
      {:ok, %{text: after_text}} ->
        set_cursor(landing)
        %{state | selection: nil, goal: Keymap.goal_column(landing, after_text)}

      _ ->
        %{state | selection: nil}
    end
  end

  defp replace_cmd({{r1, c1}, {r2, c2}}, text) do
    {:ok, cmd} =
      Replace.parse(%{start_line: r1, start_col: c1, end_line: r2, end_col: c2, text: text})

    cmd
  end

  defp insert_cmd({line, col}, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    cmd
  end

  # Where the cursor lands after inserting `text` at a caret — past the inserted bytes,
  # accounting for any newlines (a multi-line paste ends on the last inserted line).
  defp cursor_after_insert({line, col}, text) do
    case String.split(text, "\n") do
      [single] -> {line, col + String.length(single)}
      segments -> {line + length(segments) - 1, String.length(List.last(segments))}
    end
  end

  ## Undo/redo (ADR-0031). History operations on the active buffer — not recorded edits. The
  ## buffer reverts/replays the text and hands back the affected command; the *view* (here)
  ## places the cursor: undo lands where the edit began, redo where it originally left off.

  defp do_undo(state) do
    case safe_undo() do
      {:ok, %{text: text}, command} -> place_after_history_op(state, edit_start(command), text)
      _ -> state
    end
  end

  defp do_redo(state) do
    case safe_redo() do
      {:ok, %{text: text}, command} -> place_after_history_op(state, edit_landing(command), text)
      _ -> state
    end
  end

  # Move the cursor to `target` (clamped to the post-op text), refresh the goal, drop any
  # selection. The buffer's change notification also scheduled a repaint and cleared the
  # selection; positioning the cursor is what undo/redo add on top.
  defp place_after_history_op(state, target, text) do
    cursor = clamp_cursor(target, text)
    set_cursor(cursor)
    %{state | selection: nil, goal: Keymap.goal_column(cursor, text)}
  end

  # Where an undone/redone edit sits, from the command's baked coordinates. Undo lands at the
  # edit's *start* (its effect is gone); redo lands where the edit originally left the cursor.
  defp edit_start(%Insert{line: l, col: c}), do: {l, c}
  defp edit_start(%Delete{line: l, col: c}), do: {l, c}
  defp edit_start(%Replace{start_line: l, start_col: c}), do: {l, c}

  defp edit_landing(%Insert{line: l, col: c, text: t}), do: cursor_after_insert({l, c}, t)
  defp edit_landing(%Delete{line: l, col: c}), do: {l, c}

  defp edit_landing(%Replace{start_line: l, start_col: c, text: t}),
    do: cursor_after_insert({l, c}, t)

  # Clamp a {line, col} to a valid caret in `text` (a restored/removed line may be shorter).
  defp clamp_cursor({line, col}, text) do
    lines = String.split(text, "\n")
    line = line |> max(0) |> min(length(lines) - 1)
    col = col |> max(0) |> min(String.length(Enum.at(lines, line, "")))
    {line, col}
  end

  # Take back the change under the cursor (ADR-0033 §7). The buffer's change notification
  # repaints; what the loop adds is telling you what happened, or why nothing did.
  defp do_revert(state, {line, _col}, scope) do
    notice =
      case on_active_buffer(&Buffer.revert(&1, line, scope)) do
        {:ok, _snapshot, %{actor: actor, hunks: n}} ->
          "reverted #{who(actor)}'s change (#{n} hunk#{if n == 1, do: "", else: "s"})"

        {:error, {:overlap, actor, ranges}} ->
          "can't revert: #{line_list(ranges)} changed after #{who(actor)}'s edit"

        {:error, :not_a_change} ->
          "nothing to revert: no agent or outside change last wrote this line"

        {:error, :already_reverted} ->
          "that change already reads as it did before"

        {:error, _reason} ->
          "couldn't find that change in the history"
      end

    %{state | notice: notice, selection: nil}
  end

  defp who({:agent, %{harness: harness, session: session}}),
    do: harness <> "/" <> String.slice(session, 0, 8)

  defp who({:llm, model}), do: "llm/" <> to_string(model)
  defp who(_external), do: "an outside writer"

  defp line_list(ranges) do
    ranges
    |> Enum.map(fn
      {n, n} -> "line #{n}"
      {a, b} -> "lines #{a}–#{b}"
    end)
    |> Enum.join(", ")
  end

  defp safe_undo, do: on_active_buffer(&Buffer.undo/1)
  defp safe_redo, do: on_active_buffer(&Buffer.redo/1)

  defp on_active_buffer(fun) do
    case Session.active_buffer() do
      {:ok, pid} -> fun.(pid)
      :error -> {:error, :no_active_buffer}
    end
  catch
    :exit, _ -> {:error, :down}
  end

  defp safe_dispatch(cmd) do
    Dispatch.run(Command.put_meta(cmd, Meta.human()))
  catch
    :exit, _ -> {:error, :down}
  end

  ## Minibuffer (the command surface, ADR-0028)

  defp open_minibuffer(state),
    do: schedule_repaint(%{state | minibuffer: Minibuffer.open(:command)})

  defp close_minibuffer(state) do
    state = stop_matching(state)
    finder = %{state.finder | matches: [], submit: false}
    schedule_repaint(%{state | minibuffer: Minibuffer.new(), finder: finder})
  end

  # Keys while the minibuffer is open go to its input; Enter submits, Alt+N / Esc cancels,
  # and Ctrl-X still quits (so you are never trapped). Everything else is ignored.
  #
  # In `:palette` mode two extra chords navigate the candidate list — **Alt+W/Alt+S** (the
  # editor's own up/down, ADR-0028 §3) and the arrow Up/Down alias — handled *before* the
  # text-input cases so they move the highlight instead of typing. A plain `w`/`s` still types
  # into the fuzzy filter; the Alt modifier is what separates "move" from "type".
  defp apply_minibuffer_key(event, %{minibuffer: mb} = state) do
    case event do
      _ when mb.mode in @pickers and event in [{:alt, ?w}, {:alt, ?W}, {:key, :up}] ->
        move_palette(state, -1)

      _ when mb.mode in @pickers and event in [{:alt, ?s}, {:alt, ?S}, {:key, :down}] ->
        move_palette(state, +1)

      {:char, g} ->
        schedule_repaint(refresh_matches(%{state | minibuffer: Minibuffer.insert(mb, g)}))

      {:key, :backspace} ->
        schedule_repaint(refresh_matches(%{state | minibuffer: Minibuffer.backspace(mb)}))

      {:key, :left} ->
        schedule_repaint(%{state | minibuffer: Minibuffer.left(mb)})

      {:key, :right} ->
        schedule_repaint(%{state | minibuffer: Minibuffer.right(mb)})

      {:key, :enter} ->
        submit_minibuffer(state)

      {:key, :esc} ->
        close_minibuffer(state)

      {:alt, c} when c in [?n, ?N] ->
        close_minibuffer(state)

      # The keymap's quit keys (`Keymap.resolve/3`).
      {:ctrl, c} when c in [?x, ?q, ?c] ->
        Geex.stop()
        state

      _ ->
        state
    end
  end

  # Run the typed command, then close. The grammar is `Geex.Loop.Verbs` (the keymap's
  # typed twin, ADR-0028 parity): `line N` / a bare number resolve through the same
  # `Geex.MCP.ViewActions.line/1` an agent's `tools/call line` hits (ADR-0030 — the
  # old in-loop go-to-line hack is retired), and plain verbs (`copy`, `undo`, `save`,
  # …) apply through the same apply_action/4 the chords use. Unknown input is a no-op.
  # Grid commands (ADR-0027) and the palette (ADR-0028 §3); search and the finder are next.
  defp submit_minibuffer(%{minibuffer: %Minibuffer{mode: :grid}} = state) do
    close_minibuffer(do_grid(Verbs.parse_grid(Minibuffer.value(state.minibuffer)), state))
  end

  # The palette: Enter runs the **highlighted** candidate. Re-derive the candidate list from
  # the current input (the same pure `Catalog.search` the popup renders, so what Enter runs is
  # exactly what is highlighted), pick the `sel`-th, and dispatch it (`dispatch_palette/2`).
  # No match under the cursor (empty list) just closes.
  defp submit_minibuffer(%{minibuffer: %Minibuffer{mode: :palette} = mb} = state) do
    pick(Enum.at(Catalog.search(Minibuffer.value(mb)), mb.sel), state)
  end

  # The buffer picker: Enter shows the highlighted buffer.
  defp submit_minibuffer(%{minibuffer: %Minibuffer{mode: :buffers} = mb} = state) do
    pick(Enum.at(candidates(state), mb.sel), state)
  end

  # The finder: Enter opens the highlighted file. While the files are still being read, or the
  # search for what was typed is still running, wait for it: its answer opens the top match
  # (`submit`).
  defp submit_minibuffer(%{minibuffer: %Minibuffer{mode: :files}} = state)
       when state.tree.files == nil or state.finder.matching != nil,
       do: put_in(state.finder.submit, true)

  defp submit_minibuffer(%{minibuffer: %Minibuffer{mode: :files} = mb} = state) do
    query = String.trim(Minibuffer.value(mb))

    case Enum.at(candidates(state), if(state.finder.submit, do: 0, else: mb.sel)) do
      %{invoke: {:file, _path}} = entry ->
        pick(entry, state)

      nil when query != "" and is_binary(state.tree.files) ->
        %{close_minibuffer(state) | notice: "no file matches “#{query}”"}

      nil ->
        close_minibuffer(state)
    end
  end

  # Close first, then act: an action may open the minibuffer again (`buffers` opens its picker).
  defp submit_minibuffer(state) do
    input = Minibuffer.value(state.minibuffer)
    state = close_minibuffer(state)

    case Verbs.parse(input) do
      {:line, n} -> jump_to_line(n, state)
      {:open, path} -> do_open(path, state)
      {:action, action} -> apply_verb(action, state)
      :cancel -> state
      :unknown -> state
    end
  end

  # Run a picker's candidate, by Enter or a click (ADR-0039): a file opens, a buffer shows, a
  # command runs. Nothing (an empty list) just closes.
  defp pick(%{invoke: {:file, path}}, state),
    do: do_open(Path.join(safe_start().root, path), close_minibuffer(state))

  defp pick(%{invoke: {:buffer, pid}}, state) do
    state = leave(state)
    safe_set_active(pid)
    close_minibuffer(adopt_active(state, pid))
  end

  defp pick(%{invoke: invoke}, state), do: dispatch_palette(invoke, state)
  defp pick(nil, state), do: close_minibuffer(state)

  # Move the palette highlight by `delta` (Alt+W/S, arrows), **wrapping** at the ends so a long
  # list cycles. Clamp against the *current* candidate count (the filter may have narrowed it);
  # an empty list leaves `sel` untouched.
  defp move_palette(%{minibuffer: mb} = state, delta) do
    case length(candidates(state)) do
      0 ->
        state

      count ->
        schedule_repaint(%{
          state
          | minibuffer: Minibuffer.select(mb, Integer.mod(mb.sel + delta, count))
        })
    end
  end

  # Run a picked palette command. A zero-arg `{:action, atom}` dispatches through the shared
  # `apply_verb`/`apply_action` vocabulary (the same path `Alt+C` / a typed `copy` take) then
  # closes. A `{:typed, prefix}` command still needs an argument, so instead of running it we
  # **hand off** to `:command` mode pre-filled with the verb (e.g. `line `) for the user to
  # complete — the palette is a launcher, the typed parser finishes the job.
  defp dispatch_palette({:action, action}, state), do: apply_verb(action, close_minibuffer(state))

  defp dispatch_palette({:typed, prefix}, state),
    do: schedule_repaint(%{state | minibuffer: Minibuffer.open(:command, prefix <> " ")})

  ## Grid commands (ADR-0027). The coordinates typed in `:grid` mode are **display columns**
  ## (the ruler is up); cast `x` to a grapheme against the target line, resolve to a caret /
  ## span (pure `Geex.Coord`), then apply — `goto` moves the cursor, `copy`/`cut` run over the
  ## resolved range through the existing clipboard ops (which also shows it as a selection).

  defp do_grid(:cancel, state), do: state
  defp do_grid(:unknown, state), do: state
  defp do_grid({:goto, coord}, state), do: grid_goto(coord, state)
  defp do_grid({:copy, range}, state), do: grid_clip(range, state, :copy)
  defp do_grid({:cut, range}, state), do: grid_clip(range, state, :cut)

  defp grid_goto(coord, state) do
    with {:ok, %{text: text}} <- safe_session_snapshot(),
         {:ok, cursor} <- Coord.to_caret(cast_coord(coord, text), Doc.new(text)) do
      set_cursor(cursor)
      %{state | goal: Keymap.goal_column(cursor, text), selection: nil}
    else
      _ -> state
    end
  end

  defp grid_clip(range, state, op) do
    with {:ok, %{text: text}} <- safe_session_snapshot(),
         {:ok, {from, to}} <- Coord.to_span(cast_range(range, text), Doc.new(text)) do
      if from == to do
        # Both endpoints clamped to the same caret (each overshot a short line, the "to end of
        # line" idiom on both ends) → a genuine no-op. Clear the selection so the next motion has
        # nothing stale to extend: do_copy/do_cut's collapsed guard would *return state unchanged*,
        # leaving a truthy-but-collapsed %Selection{} that apply_move would turn into a phantom
        # highlight. (The non-grid path never synthesizes a selection, so it can't hit this.)
        %{state | selection: nil}
      else
        # Set the resolved span as the selection (so the region is visible), then reuse the
        # clipboard op — copy = slice+push, cut = push + a recorded delete; both clear it.
        state = %{state | selection: Selection.new(from) |> Selection.extend(to)}
        if op == :copy, do: do_copy(state, text), else: do_cut(state, text)
      end
    else
      _ -> state
    end
  end

  # Cast a display-column coordinate to a grapheme one against its target line (ADR-0027 §"display
  # ruler"). `y` past EOF leaves `x` cast against "" — harmless, since `to_caret`/`to_span` reject
  # the out-of-range `y` anyway.
  defp cast_coord(%Coord{x: x, y: y}, text),
    do: %Coord{x: Width.col_at_display(line_at(text, y - 1), x), y: y}

  defp cast_range(%Coord.Range{from: from, to: to} = range, text),
    do: %{range | from: cast_coord(from, text), to: cast_coord(to, text)}

  # Go-to-line through the one shared resolution (ViewActions sets the cursor); on
  # success refresh the view-local goal from the landing. A jump clears the selection
  # (it is a jump, not motion — only motion extends a selection, ADR-0029).
  defp jump_to_line(n, state) do
    with {:ok, cursor} <- safe_view_line(n),
         {:ok, %{text: text}} <- safe_session_snapshot() do
      %{state | goal: Keymap.goal_column(cursor, text), selection: nil}
    else
      _ -> state
    end
  end

  # ViewActions.line/1 makes bare Session calls (the MCP door has the protocol's -32603
  # containment); on the loop's door, contain an exit like every other Session/Buffer
  # touch here — a typed `line N` must never crash the loop.
  defp safe_view_line(n) do
    ViewActions.line(n)
  catch
    :exit, _ -> {:error, :down}
  end

  # A typed verb needs the same cursor + text context a keystroke has — fetch it fresh.
  # :quit must work with no buffer open (you can always type `quit`); the rest no-op.
  defp apply_verb(:quit, state), do: apply_action(:quit, {0, 0}, "", state)
  # Switching and closing buffers need no text either (and work with none active).
  defp apply_verb(action, state)
       when action in [:buffers, :close, :toggle_edits, :toggle_tree, :next_pane, :find_file] or
              action == :toggle_mouse or
              action in [:split_rows, :split_cols, :tab_next, :tab_prev] or
              (is_tuple(action) and elem(action, 0) in [:tab, :theme]),
       do: apply_action(action, {0, 0}, "", state)

  defp apply_verb(action, state) do
    case safe_session_snapshot() do
      {:ok, %{text: text, cursor: cursor}} -> apply_action(action, cursor, text, state)
      _ -> state
    end
  end

  defp set_cursor(cursor) do
    Session.set_cursor(cursor)
  catch
    :exit, _ -> :ok
  end

  defp overlay_spans(nil), do: []

  defp overlay_spans(reactor) do
    case safe_highlights(reactor) do
      %{spans: spans} -> spans
      _ -> []
    end
  end

  # A transient/absent TerminalIO must not crash the loop on startup; fall back to
  # a sane default size (the next :resize corrects it). window_size/0 returns
  # {cols, rows}, which is geex's {w, h} directly.
  defp safe_window_size do
    case TerminalIO.window_size() do
      {:ok, {cols, rows}} -> {cols, rows}
      _ -> {80, 24}
    end
  catch
    :exit, _ -> {80, 24}
  end

  defp safe_subscribe_buffer(pid) do
    Buffer.subscribe(pid, self())
  catch
    :exit, _ -> :error
  end

  defp safe_session_snapshot do
    Session.snapshot()
  catch
    :exit, _ -> {:error, :down}
  end

  defp safe_active_buffer do
    Session.active_buffer()
  catch
    :exit, _ -> :error
  end

  defp safe_set_active(pid) do
    Session.set_active_buffer(pid)
  catch
    :exit, _ -> :ok
  end

  defp safe_open_file(path) do
    Session.open_file(path)
  catch
    :exit, _ -> {:error, :down}
  end

  defp safe_close_buffer(pid) do
    Session.close_buffer(pid)
  catch
    :exit, _ -> {:error, :down}
  end

  defp safe_buffer_snapshot(pid) do
    {:ok, Buffer.snapshot(pid)}
  catch
    :exit, _ -> :error
  end

  defp safe_status(pid) do
    Buffer.status(pid)
  catch
    :exit, _ -> nil
  end

  # The overlay to paint: the optimistically-shifted overlay when a recent edit's
  # exact re-highlight is still in flight, else the exact result — so the edited
  # line's colours stay aligned across a keystroke (ADR-0022; no tail flicker).
  defp safe_highlights(reactor) do
    Reactor.render(reactor)
  catch
    :exit, _ -> nil
  end
end
