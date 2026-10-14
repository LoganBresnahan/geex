defmodule Geex.Loop do
  @moduledoc """
  The interactive editor loop ([ADR-0024](../../doc/adr/0024-tui-core-extractable.md))
  — the **event-driven** frame owner.

  It sits *above* `Geex.Session` and **drives** the generic TUI core from editor
  state. It owns no editor state (Session owns the active buffer + cursor + scroll;
  `Geex.Buffer` owns the text + history); it owns only the event→repaint cycle:

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
    Minibuffer,
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
  alias Geex.Loop.{Keymap, Verbs}
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
  scroll to match. Returns the resolved `hscroll` so the caller can persist it.
  """
  @spec frame(
          String.t(),
          [map()],
          Theme.t(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
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
        selection \\ nil
      ) do
    gw = gutter_width(text)
    text_w = max(w - gw, 0)
    {dcol, cy} = cursor_xy(text, cursor, scroll)
    hscroll = scroll_for(hscroll, dcol, text_w, @hscrolloff)

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
    {w, h} = safe_window_size()

    state =
      %{
        w: w,
        h: h,
        scroll: 0,
        hscroll: 0,
        goal: 0,
        selection: nil,
        theme: Theme.default(),
        buffer: nil,
        buffer_ref: nil,
        reactor: nil,
        repaint?: false,
        minibuffer: Minibuffer.new(),
        # A one-line message from the buffer (`{:geex_buffer_notice, …}`, e.g. a reconcile
        # conflict, ADR-0032), shown on the status line until the next key.
        notice: nil
      }
      |> attach(active)

    {:ok, schedule_repaint(state)}
  end

  # --- events that dirty the frame ---

  @impl true
  def handle_info({:geex_active_buffer, pid}, state),
    do: {:noreply, schedule_repaint(attach(state, pid))}

  # Any buffer change drops the live selection: our own edits already cleared it, and an
  # out-of-band edit (agent/reconcile) would otherwise leave a stale selection whose carets
  # no longer match the text — a later copy/cut would grab the wrong region.
  def handle_info({:geex_buffer_change, buffer, _v, _footprint}, %{buffer: buffer} = state),
    do: {:noreply, schedule_repaint(%{state | selection: nil})}

  def handle_info({:geex_buffer_notice, buffer, text}, %{buffer: buffer} = state),
    do: {:noreply, schedule_repaint(%{state | notice: text})}

  def handle_info({:geex_highlights, buffer, _v}, %{buffer: buffer} = state),
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
    System.stop()
    {:noreply, state}
  end

  # A key. When the minibuffer is open it captures input; otherwise resolve the key against
  # the current text + cursor (read fresh from Session) and apply via the one shared path
  # (edits) or a view-local cursor move.
  def handle_info({:geex_io, event}, state) do
    # Any key dismisses a notice (it has been seen).
    state = if state.notice, do: schedule_repaint(%{state | notice: nil}), else: state

    if Minibuffer.active?(state.minibuffer) do
      {:noreply, apply_minibuffer_key(event, state)}
    else
      case safe_session_snapshot() do
        {:ok, %{text: text, cursor: cursor}} -> {:noreply, apply_key(event, cursor, text, state)}
        _ -> {:noreply, state}
      end
    end
  end

  # The active buffer died — detach; a fresh open re-attaches via Session.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{buffer_ref: ref} = state),
    do: {:noreply, schedule_repaint(%{state | buffer: nil, buffer_ref: nil, reactor: nil})}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # Coalesced repaint — one per burst.
  def handle_info(:repaint, state), do: {:noreply, repaint(%{state | repaint?: false})}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  # Post exactly one :repaint for a burst of dirtying events.
  defp schedule_repaint(%{repaint?: true} = state), do: state

  defp schedule_repaint(state) do
    send(self(), :repaint)
    %{state | repaint?: true}
  end

  # (Re)attach to `pid` as the active buffer: monitor it, subscribe to its change
  # stream and its highlight reactor (if one is running). Old subscriptions are
  # dropped first.
  defp attach(state, nil), do: detach(state)

  defp attach(state, pid) when is_pid(pid) do
    state = detach(state)
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

    %{state | buffer: pid, buffer_ref: ref, reactor: reactor}
  end

  defp detach(%{buffer_ref: ref, buffer: buf, reactor: reactor} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    # Drop our subscriptions too, not just our monitor: otherwise the old buffer and
    # its reactor keep us in their subscriber sets (and keep sending us now-dropped
    # change/overlay messages) until they die — a leak across buffer switches.
    if is_pid(buf), do: Buffer.unsubscribe(buf, self())
    if is_pid(reactor), do: Reactor.unsubscribe(reactor, self())
    # A selection is buffer-specific; drop it (and reset the goal) on a buffer switch.
    %{state | buffer: nil, buffer_ref: nil, reactor: nil, selection: nil, goal: 0}
  end

  defp detach(state), do: state

  defp repaint(state) do
    case safe_session_snapshot() do
      {:ok, %{text: text, cursor: {line, _} = cursor} = snap} ->
        # The bottom row is the status line; the buffer renders into the rows above
        # it, the cursor stays within that text area, and a scrolloff margin keeps it
        # off the top/bottom edges. Paint the text rect, grow to the full height, then
        # overlay the status row.
        #
        # Grid mode (ADR-0027) reserves one more row at the **top** for the display-column
        # ruler; the text frame is painted at the reduced height and shifted down by `top`.
        grid? = grid_mode?(state)
        top = if grid?, do: 1, else: 0
        h_text = max(text_height(state.h) - top, 0)
        # Reserve the rightmost column for a vertical scroll bar when the buffer overflows
        # the viewport; the text then renders into a one-column-narrower area.
        total = line_count(text)
        vbar? = h_text > 0 and total > h_text
        tw = state.w - if(vbar?, do: 1, else: 0)

        scroll = scroll_for(state.scroll, line, h_text, @scrolloff)

        # `text` (Session.snapshot) and the overlay (Reactor.render) are read from two
        # processes, so painting assumes they are the same buffer version. That holds in
        # the single-frontend flow — the buffer emits its change to the reactor *before*
        # this repaint's render call can reach it, so the optimistic overlay is already at
        # `text`'s version. A *concurrent* MCP/reconcile edit landing between these two
        # reads can briefly pair text@vN with spans@v(N+1); the overlay only ever clips
        # (Paint tolerates out-of-range spans, never crashes) and the change's own repaint
        # corrects it next frame. Enforce-the-versions-match is a deferred refinement.
        {screen, {cx, cy}, hscroll} =
          frame(
            text,
            overlay_spans(state.reactor),
            state.theme,
            cursor,
            tw,
            h_text,
            scroll,
            state.hscroll,
            state.selection
          )

        gw = gutter_width(text)
        text_w = max(tw - gw, 0)
        content_w = max_line_width(text)

        screen =
          screen
          |> Screen.resize(state.w, state.h)
          |> maybe_vscrollbar(vbar?, state.w - 1, h_text, scroll, total, state.theme)
          # Shift the text + scroll bar down past the reserved ruler row, then paint the
          # contextual grid chrome over the now-vacant top row + the text region.
          |> Screen.translate_y(top)
          |> draw_ruler(grid?, gw, text_w, hscroll, state.theme)
          |> draw_grid_lines(grid?, gw, text_w, h_text, top, hscroll, state.theme)
          |> draw_hbar(state, gw, text_w, content_w, hscroll)

        target =
          case cursor_target(state.w, h_text, cx, cy) do
            {x, y} -> {x, y + top}
            :hidden -> :hidden
          end

        {screen, cursor} = draw_bottom(screen, state, snap, target)

        # The palette popup (ADR-0028 §3) overlays the rows just above the minibuffer input —
        # painted last so it sits on top of the text; a no-op outside `:palette` mode.
        screen = draw_palette(screen, state)

        Renderer.flush(screen, cursor)
        %{state | scroll: scroll, hscroll: hscroll}

      _ ->
        screen = draw_empty_status(Screen.new(state.w, state.h), state)
        Renderer.flush(screen, :hidden)
        %{state | scroll: 0, hscroll: 0}
    end
  end

  # Two rows at the bottom are reserved: the status line (h-1) and the horizontal scroll
  # bar (h-2). The horizontal-bar row is *always* reserved — even when no line overflows —
  # so showing/hiding the bar never reflows the text vertically. The buffer gets the rest.
  defp text_height(h), do: max(h - 2, 0)

  # The bottom row is the status line, or the **minibuffer** when it is open — which takes
  # over the status row and owns the hardware cursor while active.
  defp draw_bottom(screen, %{minibuffer: mb} = state, snap, buffer_cursor) do
    if Minibuffer.active?(mb) do
      {draw_minibuffer(screen, state), minibuffer_cursor(state)}
    else
      {draw_status(screen, state, snap), buffer_cursor}
    end
  end

  # Draw the minibuffer over the bottom row: the mode prompt + the typed input, on the
  # **active-line background** (the same tint the cursor's row gets — see highlight_line/4) so
  # the input field reads as a focused, distinct surface, yet stays clearly different from the
  # reverse-video status bar it replaces.
  defp draw_minibuffer(screen, %{w: w, h: h, theme: %Theme{palette: pal}, minibuffer: mb}) do
    line = Minibuffer.prompt(mb) <> Minibuffer.value(mb)

    screen
    |> Screen.fill_rect(0, h - 1, w, 1, %Cell{char: " ", fg: pal.fg, bg: pal.active_line_bg})
    |> Screen.draw_text(0, h - 1, line, %Cell{fg: pal.fg, bg: pal.active_line_bg})
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
  defp draw_palette(screen, %{minibuffer: %Minibuffer{mode: :palette} = mb} = state) do
    candidates = Catalog.search(Minibuffer.value(mb))
    rows = min(length(candidates), min(@palette_rows, max(state.h - 1, 0)))

    cond do
      candidates == [] ->
        draw_palette_empty(screen, state)

      # No vertical room for even one candidate row (a degenerate ≤1-row terminal): draw nothing
      # rather than the empty hint, which would mislead.
      rows == 0 ->
        screen

      true ->
        # Scroll the window so the highlighted row (`mb.sel`) stays visible: once the selection
        # passes the first page it rides the bottom of the window.
        start = mb.sel |> Kernel.-(rows - 1) |> max(0) |> min(max(length(candidates) - rows, 0))
        top = state.h - 1 - rows

        candidates
        |> Enum.slice(start, rows)
        |> Enum.with_index()
        |> Enum.reduce(screen, fn {entry, i}, acc ->
          draw_palette_row(acc, entry, top + i, start + i == mb.sel, state)
        end)
    end
  end

  defp draw_palette(screen, _state), do: screen

  # One candidate row: `name` padded to a column, then its description, on the theme bg —
  # or the active-line tint when highlighted (the Enter target).
  defp draw_palette_row(screen, entry, y, selected?, %{w: w, theme: %Theme{palette: pal}}) do
    bg = if selected?, do: pal.active_line_bg, else: pal.bg
    name_fg = if selected?, do: pal.fg, else: pal.active_line_number
    label = String.pad_trailing(entry.name, @palette_name_col)

    screen
    |> Screen.fill_rect(0, y, w, 1, %Cell{char: " ", fg: pal.fg, bg: bg})
    |> Screen.draw_text(0, y, palette_clip(label <> entry.description, w), %Cell{
      fg: name_fg,
      bg: bg
    })
    # Re-tint the description (past the name column) in the dimmer fg so the name stands out.
    |> Screen.draw_text(
      @palette_name_col,
      y,
      palette_clip(entry.description, w - @palette_name_col),
      %Cell{
        fg: pal.line_number,
        bg: bg
      }
    )
  end

  # No command matches the filter: a single dim hint row just above the input.
  defp draw_palette_empty(screen, %{w: w, h: h, theme: %Theme{palette: pal}}) do
    y = h - 2

    if y >= 0 do
      screen
      |> Screen.fill_rect(0, y, w, 1, %Cell{char: " ", fg: pal.line_number, bg: pal.bg})
      |> Screen.draw_text(0, y, palette_clip("(no commands match)", w), %Cell{
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
        if(state.notice, do: "  " <> state.notice, else: "")

    Screen.draw_text(
      screen,
      0,
      h - 1,
      status_text(left, position(snap.cursor), w),
      status_style(theme)
    )
  end

  defp draw_empty_status(screen, %{w: w, h: h, theme: theme}) do
    Screen.draw_text(screen, 0, h - 1, status_text("[no buffer]", "", w), status_style(theme))
  end

  defp status_label(nil), do: "[scratch]"
  defp status_label(path) when is_binary(path), do: Path.basename(path)

  defp position({line, col}), do: "#{line + 1}:#{col + 1}"

  defp status_style(%Theme{palette: p}), do: %Cell{fg: p.bg, bg: p.fg}

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

      action when is_atom(action) ->
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

      :redo ->
        schedule_repaint(do_redo(state))

      :save ->
        do_save(state)

      :quit ->
        System.stop()
        state
    end
  end

  # Save the active buffer (Ctrl-O / the `save` verb) — an operation, not an edit
  # (ADR-0019): no command, no history. Visible feedback is the status line's dirty
  # marker clearing; `Buffer.save/1` emits no change event, so repaint explicitly. A
  # failure (`{:error, :no_path}` on a scratch buffer, a posix error) leaves the marker
  # set — a real echo/message area is a deferred minibuffer slice.
  defp do_save(state) do
    _ = on_active_buffer(&Buffer.save/1)
    schedule_repaint(state)
  end

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
         do: Clipboard.push(copied)

    %{state | selection: nil}
  end

  defp do_cut(%{selection: nil} = state, _text), do: state

  defp do_cut(%{selection: sel} = state, _text)
       when is_struct(sel, Selection) and sel.anchor == sel.active, do: state

  defp do_cut(%{selection: sel} = state, text) do
    range = Selection.range(sel)
    {from, _to} = range

    with {:ok, cut_text} <- Doc.slice(Doc.new(text), range) do
      Clipboard.push(cut_text)
      apply_clipboard_edit(state, replace_cmd(range, ""), from)
    else
      _ -> %{state | selection: nil}
    end
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

  defp close_minibuffer(state), do: schedule_repaint(%{state | minibuffer: Minibuffer.new()})

  # Keys while the minibuffer is open go to its input; Enter submits, Alt+N / Esc cancels,
  # and Ctrl-X still quits (so you are never trapped). Everything else is ignored.
  #
  # In `:palette` mode two extra chords navigate the candidate list — **Alt+W/Alt+S** (the
  # editor's own up/down, ADR-0028 §3) and the arrow Up/Down alias — handled *before* the
  # text-input cases so they move the highlight instead of typing. A plain `w`/`s` still types
  # into the fuzzy filter; the Alt modifier is what separates "move" from "type".
  defp apply_minibuffer_key(event, %{minibuffer: mb} = state) do
    case event do
      _ when mb.mode == :palette and event in [{:alt, ?w}, {:alt, ?W}, {:key, :up}] ->
        move_palette(state, -1)

      _ when mb.mode == :palette and event in [{:alt, ?s}, {:alt, ?S}, {:key, :down}] ->
        move_palette(state, +1)

      {:char, g} ->
        schedule_repaint(%{state | minibuffer: Minibuffer.insert(mb, g)})

      {:key, :backspace} ->
        schedule_repaint(%{state | minibuffer: Minibuffer.backspace(mb)})

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

      {:ctrl, ?x} ->
        System.stop()
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
    case Enum.at(Catalog.search(Minibuffer.value(mb)), mb.sel) do
      %Catalog.Entry{invoke: invoke} -> dispatch_palette(invoke, state)
      nil -> close_minibuffer(state)
    end
  end

  defp submit_minibuffer(state) do
    state =
      case Verbs.parse(Minibuffer.value(state.minibuffer)) do
        {:line, n} -> jump_to_line(n, state)
        {:action, action} -> apply_verb(action, state)
        :cancel -> state
        :unknown -> state
      end

    close_minibuffer(state)
  end

  # Move the palette highlight by `delta` (Alt+W/S, arrows), **wrapping** at the ends so a long
  # list cycles. Clamp against the *current* candidate count (the filter may have narrowed it);
  # an empty list leaves `sel` untouched.
  defp move_palette(%{minibuffer: mb} = state, delta) do
    case length(Catalog.search(Minibuffer.value(mb))) do
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
  defp dispatch_palette({:action, action}, state), do: close_minibuffer(apply_verb(action, state))

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

  # The overlay to paint: the optimistically-shifted overlay when a recent edit's
  # exact re-highlight is still in flight, else the exact result — so the edited
  # line's colours stay aligned across a keystroke (ADR-0022; no tail flicker).
  defp safe_highlights(reactor) do
    Reactor.render(reactor)
  catch
    :exit, _ -> nil
  end
end
