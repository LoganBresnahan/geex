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

  alias Geex.{Buffer, Cell, Command, Dispatch, Minibuffer, Renderer, Screen, Session, TerminalIO, Theme, Width}
  alias Geex.Command.Meta
  alias Geex.Highlight.{Paint, Reactor}
  alias Geex.Loop.Keymap

  # Rows of context kept between the cursor and the top/bottom of the viewport
  # (vim's `scrolloff`). A fixed default for now; a future per-user config knob
  # (ADR-0025). Clamped to half the window so the bands never cross.
  @scrolloff 3

  # Columns of context kept between the cursor and the left/right of the text area
  # (vim's `sidescrolloff`) — the horizontal analogue, applied via the same
  # `scroll_for/4` along the column axis.
  @hscrolloff 8

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
  @spec frame(String.t(), [map()], Theme.t(), {non_neg_integer(), non_neg_integer()},
          non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {Screen.t(), {non_neg_integer(), integer()}, non_neg_integer()}
  def frame(text, spans, %Theme{} = theme, {cursor_line, _} = cursor, w, h, scroll, hscroll \\ 0) do
    gw = gutter_width(text)
    text_w = max(w - gw, 0)
    {dcol, cy} = cursor_xy(text, cursor, scroll)
    hscroll = scroll_for(hscroll, dcol, text_w, @hscrolloff)

    screen =
      text
      |> Paint.to_screen(spans, theme, w, h, scroll, gw, hscroll)
      |> draw_gutter(text, theme, h, scroll, gw, cursor_line)
      |> highlight_line(w, cy, theme.palette.active_line_bg)

    {screen, {gw + dcol - hscroll, cy}, hscroll}
  end

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
    pad = max(w - Width.string(l) - Width.string(r), 0)
    l <> String.duplicate(" ", pad) <> r
  end

  ## GenServer

  @impl true
  def init(_opts) do
    TerminalIO.subscribe()
    active = Session.subscribe()
    {w, h} = safe_window_size()

    state =
      %{w: w, h: h, scroll: 0, hscroll: 0, theme: Theme.default(), buffer: nil, buffer_ref: nil, reactor: nil, repaint?: false, minibuffer: Minibuffer.new()}
      |> attach(active)

    {:ok, schedule_repaint(state)}
  end

  # --- events that dirty the frame ---

  @impl true
  def handle_info({:geex_active_buffer, pid}, state),
    do: {:noreply, schedule_repaint(attach(state, pid))}

  def handle_info({:geex_buffer_change, buffer, _v}, %{buffer: buffer} = state),
    do: {:noreply, schedule_repaint(state)}

  def handle_info({:geex_highlights, buffer, _v}, %{buffer: buffer} = state),
    do: {:noreply, schedule_repaint(state)}

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
        {:ok, r} -> Reactor.subscribe(r); r
        :error -> nil
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
    %{state | buffer: nil, buffer_ref: nil, reactor: nil}
  end

  defp detach(state), do: state

  defp repaint(state) do
    case safe_session_snapshot() do
      {:ok, %{text: text, cursor: {line, _} = cursor} = snap} ->
        # The bottom row is the status line; the buffer renders into the rows above
        # it, the cursor stays within that text area, and a scrolloff margin keeps it
        # off the top/bottom edges. Paint the text rect, grow to the full height, then
        # overlay the status row.
        h_text = text_height(state.h)
        # Reserve the rightmost column for a vertical scroll bar when the buffer overflows
        # the viewport; the text then renders into a one-column-narrower area.
        total = line_count(text)
        vbar? = h_text > 0 and total > h_text
        tw = state.w - if(vbar?, do: 1, else: 0)

        scroll = scroll_for(state.scroll, line, h_text, @scrolloff)

        {screen, {cx, cy}, hscroll} =
          frame(text, overlay_spans(state.reactor), state.theme, cursor, tw, h_text, scroll, state.hscroll)

        gw = gutter_width(text)
        text_w = max(tw - gw, 0)
        content_w = max_line_width(text)

        screen =
          screen
          |> Screen.resize(state.w, state.h)
          |> maybe_vscrollbar(vbar?, state.w - 1, h_text, scroll, total, state.theme)
          |> draw_hbar(state, gw, text_w, content_w, hscroll)

        {screen, cursor} = draw_bottom(screen, state, snap, cursor_target(state.w, h_text, cx, cy))
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

  # Draw the minibuffer over the bottom row: the mode prompt + the typed input, plain on the
  # theme background (distinct from the reverse-video status bar, so command mode is obvious).
  defp draw_minibuffer(screen, %{w: w, h: h, theme: %Theme{palette: pal}, minibuffer: mb}) do
    line = Minibuffer.prompt(mb) <> Minibuffer.value(mb)

    screen
    |> Screen.fill_rect(0, h - 1, w, 1, %Cell{char: " ", fg: pal.fg, bg: pal.bg})
    |> Screen.draw_text(0, h - 1, line, %Cell{fg: pal.fg, bg: pal.bg})
  end

  # The hardware cursor position within the minibuffer: after the prompt, at the input cursor
  # (counted in display columns so a wide glyph in the input shifts it by two).
  defp minibuffer_cursor(%{h: h, minibuffer: mb}) do
    before = Minibuffer.value(mb) |> String.graphemes() |> Enum.take(mb.cursor) |> Enum.join()
    {Width.string(Minibuffer.prompt(mb)) + Width.string(before), h - 1}
  end

  # Overlay the status line on the bottom row of `screen`: the buffer label + dirty
  # marker on the left, the 1-based `line:col` flush right, on a reverse-video bar
  # (theme fg/bg swapped — always-readable, theme-faithful chrome).
  defp draw_status(screen, %{w: w, h: h, theme: theme}, snap) do
    left = status_label(snap.path) <> if(snap.dirty, do: " [+]", else: "")
    Screen.draw_text(screen, 0, h - 1, status_text(left, position(snap.cursor), w), status_style(theme))
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
  defp draw_hbar(screen, %{w: w, h: h, theme: %Theme{palette: pal}}, gw, text_w, content_w, hscroll) do
    row = h - 2
    screen = Screen.fill_rect(screen, 0, row, w, 1, %Cell{char: " ", fg: pal.fg, bg: pal.bg})

    if row >= 0 and text_w > 0 and content_w > text_w do
      {left, len} = scrollbar_thumb(text_w, content_w, hscroll)
      # Both are vertically-centred horizontal rules (not full blocks), so the bar reads as a
      # thin line rather than a chunky band: a light track with a heavy, accent-coloured thumb.
      track = %Cell{char: "─", fg: pal.line_number, bg: pal.bg}
      thumb = %Cell{char: "━", fg: pal.cursor, bg: pal.bg}

      Enum.reduce(0..(text_w - 1)//1, screen, fn i, acc ->
        Screen.set_cell(acc, gw + i, row, if(i >= left and i < left + len, do: thumb, else: track))
      end)
    else
      screen
    end
  end

  defp cursor_target(w, h_text, x, y) when x >= 0 and x < w and y >= 0 and y < h_text, do: {x, y}
  defp cursor_target(_w, _h_text, _x, _y), do: :hidden

  # Resolve a key to an action and apply it. Edits go through the **one shared path**
  # (Dispatch.run with human provenance) then move the cursor; a move just sets the
  # cursor; quit stops the VM so the app's shutdown restores the terminal. The buffer's
  # post-dispatch change notification will also schedule a repaint, but we schedule one
  # here too so a pure cursor move (no edit) repaints as well.
  defp apply_key(event, cursor, text, state) do
    case Keymap.resolve(event, cursor, text) do
      :ignore ->
        state

      :minibuffer ->
        open_minibuffer(state)

      :quit ->
        System.stop()
        state

      {:move, new_cursor} ->
        set_cursor(new_cursor)
        schedule_repaint(state)

      {:edit, cmd, new_cursor} ->
        with {:ok, _snap} <- safe_dispatch(cmd), do: set_cursor(new_cursor)
        schedule_repaint(state)
    end
  end

  defp safe_dispatch(cmd) do
    Dispatch.run(Command.put_meta(cmd, Meta.human()))
  catch
    :exit, _ -> {:error, :down}
  end

  ## Minibuffer (the command surface, ADR-0028)

  defp open_minibuffer(state), do: schedule_repaint(%{state | minibuffer: Minibuffer.open(:command)})
  defp close_minibuffer(state), do: schedule_repaint(%{state | minibuffer: Minibuffer.new()})

  # Keys while the minibuffer is open go to its input; Enter submits, Alt+N / Esc cancels,
  # and Ctrl-X still quits (so you are never trapped). Everything else is ignored.
  defp apply_minibuffer_key(event, %{minibuffer: mb} = state) do
    case event do
      {:char, g} -> schedule_repaint(%{state | minibuffer: Minibuffer.insert(mb, g)})
      {:key, :backspace} -> schedule_repaint(%{state | minibuffer: Minibuffer.backspace(mb)})
      {:key, :left} -> schedule_repaint(%{state | minibuffer: Minibuffer.left(mb)})
      {:key, :right} -> schedule_repaint(%{state | minibuffer: Minibuffer.right(mb)})
      {:key, :enter} -> submit_minibuffer(state)
      {:key, :esc} -> close_minibuffer(state)
      {:alt, c} when c in [?n, ?N] -> close_minibuffer(state)
      {:ctrl, ?x} -> System.stop(); state
      _ -> state
    end
  end

  # Run the typed command, then close. v1: a bare line number jumps to that line (clamped to
  # the buffer); **`0` jumps to the last line**. Anything else is a no-op. Grid commands
  # (ADR-0027), search, the palette, and the finder are the next modes — each parsing
  # `value/1` into a `%Command{}` or an action.
  defp submit_minibuffer(state) do
    run_command(String.trim(Minibuffer.value(state.minibuffer)))
    close_minibuffer(state)
  end

  defp run_command(input) do
    with {n, ""} when n >= 0 <- Integer.parse(input),
         {:ok, %{text: text}} <- safe_session_snapshot() do
      last = max(line_count(text) - 1, 0)
      set_cursor({if(n == 0, do: last, else: min(n - 1, last)), 0})
    else
      _ -> :ok
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

  defp safe_highlights(reactor) do
    Reactor.highlights(reactor)
  catch
    :exit, _ -> nil
  end
end
