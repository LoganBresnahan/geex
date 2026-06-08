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

  alias Geex.{Buffer, Cell, Command, Dispatch, Renderer, Screen, Session, TerminalIO, Theme, Width}
  alias Geex.Command.Meta
  alias Geex.Highlight.{Paint, Reactor}
  alias Geex.Loop.Keymap

  # Rows of context kept between the cursor and the top/bottom of the viewport
  # (vim's `scrolloff`). A fixed default for now; a future per-user config knob
  # (ADR-0025). Clamped to half the window so the bands never cross.
  @scrolloff 3

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
  The next `Geex.Screen` plus the cursor's on-screen position, for the given inputs.

  Reserves a **line-number gutter** of `gutter_width/1` columns on the left: the text
  is painted inset by that width, the gutter is drawn over the left columns (1-based
  logical line numbers, [ADR-0027](../../doc/adr/0027-grid-command-addressing.md) — the
  number you read *is* the command grid's `y`), and the cursor's `x` is shifted right by
  the gutter width to match.
  """
  @spec frame(String.t(), [map()], Theme.t(), {non_neg_integer(), non_neg_integer()},
          non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {Screen.t(), {non_neg_integer(), integer()}}
  def frame(text, spans, %Theme{} = theme, {cursor_line, _} = cursor, w, h, scroll) do
    gw = gutter_width(text)
    {cx, cy} = cursor_xy(text, cursor, scroll)

    screen =
      text
      |> Paint.to_screen(spans, theme, w, h, scroll, gw)
      |> draw_gutter(text, theme, h, scroll, gw, cursor_line)

    {screen, {cx + gw, cy}}
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
      %{w: w, h: h, scroll: 0, theme: Theme.default(), buffer: nil, buffer_ref: nil, reactor: nil, repaint?: false}
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

  # A key: resolve it against the current text + cursor (read fresh from Session) and
  # apply via the one shared path (edits) or a view-local cursor move.
  def handle_info({:geex_io, event}, state) do
    case safe_session_snapshot() do
      {:ok, %{text: text, cursor: cursor}} -> {:noreply, apply_key(event, cursor, text, state)}
      _ -> {:noreply, state}
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
        scroll = scroll_for(state.scroll, line, h_text, @scrolloff)
        {screen, {cx, cy}} = frame(text, overlay_spans(state.reactor), state.theme, cursor, state.w, h_text, scroll)

        screen =
          screen
          |> Screen.resize(state.w, state.h)
          |> draw_status(state, snap)

        Renderer.flush(screen, cursor_target(state.w, h_text, cx, cy))
        %{state | scroll: scroll}

      _ ->
        screen = draw_empty_status(Screen.new(state.w, state.h), state)
        Renderer.flush(screen, :hidden)
        %{state | scroll: 0}
    end
  end

  # One row at the bottom is reserved for the status line; the buffer gets the rest.
  defp text_height(h), do: max(h - 1, 0)

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
