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

  **Render half only** for now — it paints the active buffer + the reactor's
  overlay live, the ADR-0024 milestone that unlocks the live-highlighting dogfood.
  The **input half** (keys → `%Command{}` on the one shared path, ADR-0003) is the
  next slice; keys are accepted but ignored here.

  Needs a real terminal (`Geex.TerminalIO` over `:prim_tty`), so it starts only
  when the terminal is enabled — off under `mix test`, like `Geex.TerminalIO`. Its
  pure render core (`cursor_xy/3`, `frame/7`) is testable without a terminal.
  """

  use GenServer
  require Logger

  alias Geex.{Buffer, Renderer, Screen, Session, TerminalIO, Theme, Width}
  alias Geex.Highlight.{Paint, Reactor}

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

  @doc "The next `Geex.Screen` plus the cursor's on-screen position, for the given inputs."
  @spec frame(String.t(), [map()], Theme.t(), {non_neg_integer(), non_neg_integer()},
          non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {Screen.t(), {non_neg_integer(), integer()}}
  def frame(text, spans, %Theme{} = theme, cursor, w, h, scroll) do
    {Paint.to_screen(text, spans, theme, w, h, scroll), cursor_xy(text, cursor, scroll)}
  end

  defp line_at(text, line), do: text |> String.split("\n") |> Enum.at(line, "")

  ## GenServer

  @impl true
  def init(_opts) do
    TerminalIO.subscribe()
    active = Session.subscribe()
    {w, h} = safe_window_size()

    state =
      %{w: w, h: h, theme: Theme.default(), buffer: nil, buffer_ref: nil, reactor: nil, repaint?: false}
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

  # Input half lands next — keys are accepted but not yet mapped to commands.
  def handle_info({:geex_io, _event}, state), do: {:noreply, state}

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

  defp detach(%{buffer_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | buffer: nil, buffer_ref: nil, reactor: nil}
  end

  defp detach(state), do: state

  defp repaint(state) do
    case safe_session_snapshot() do
      {:ok, %{text: text, cursor: cursor}} ->
        # Viewport scroll is deferred (renders from the top); cursor + paint share it.
        scroll = 0
        {screen, {cx, cy}} = frame(text, overlay_spans(state.reactor), state.theme, cursor, state.w, state.h, scroll)
        Renderer.flush(screen, cursor_target(state, cx, cy))
        state

      _ ->
        Renderer.flush(Screen.new(state.w, state.h), :hidden)
        state
    end
  end

  defp cursor_target(%{w: w, h: h}, x, y) when x >= 0 and x < w and y >= 0 and y < h, do: {x, y}
  defp cursor_target(_state, _x, _y), do: :hidden

  defp overlay_spans(nil), do: []

  defp overlay_spans(reactor) do
    case safe_highlights(reactor) do
      %{spans: spans} -> spans
      _ -> []
    end
  end

  # A transient/absent TerminalIO must not crash the loop on startup; fall back to
  # a sane default size (the next :resize corrects it).
  defp safe_window_size do
    case TerminalIO.window_size() do
      {:ok, {rows, cols}} -> {cols, rows}
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
