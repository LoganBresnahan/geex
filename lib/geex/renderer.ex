defmodule Geex.Renderer do
  @moduledoc """
  Holds the truth-about-the-terminal as a `Geex.Screen` and emits the
  minimum byte stream to update it.

  ## The diff

  Components build a `next` screen each frame; the renderer compares
  it cell-by-cell against `current` (what the terminal already shows)
  and emits one cursor-move + run-of-characters per horizontal stretch
  of changed cells. Unchanged cells produce no bytes.

  After `Geex.TerminalIO.write/1` has been called, `current` becomes
  `next` — that's the new truth.

  ## Scope

    * Styled emission. A run of changed, x-adjacent cells with the **same**
      style is emitted as one cursor-move + the run's SGR escape (`Geex.Sgr`) +
      its characters + a reset. A plain run (default colours, no attrs) emits
      no SGR — byte-identical to plain character emission — so unstyled content
      costs nothing. A style change breaks the run (its own SGR), like a gap.

    * Dimension changes (initial flush, terminal resize) emit `\\e[2J`
      and diff `next` against a blank screen of the new size.

    * **Atomic frames.** Each written frame is wrapped in synchronized-output
      (`\\e[?2026h` … `\\e[?2026l`, DEC mode 2026) so a multi-run frame is
      presented all-at-once, never half-drawn (terminals that don't support it
      ignore the unknown private mode). The hardware cursor is **re-shown only on
      a hidden→shown transition** and **repositioned only when the frame moved it
      or the cursor itself moved** — re-emitting `\\e[?25h` every frame resets the
      cursor blink and reads as flicker. See `frame/3`.

  ## Pure vs impure

  `diff/2` and `frame/3` are pure functions — given screens / a prior cursor,
  they return iodata. Test them in isolation. The GenServer wrapper just owns
  `current` + the last-emitted cursor and pipes the result to `Geex.TerminalIO`.
  """

  use GenServer

  alias Geex.{Cell, Screen, Sgr, TerminalIO}

  # Begin/End Synchronized Update (DEC private mode 2026): present a frame atomically.
  @bsu "\e[?2026h"
  @esu "\e[?2026l"

  @typedoc "The cursor as last emitted to the terminal: a position, hidden, or unknown."
  @type cursor_state :: {non_neg_integer(), non_neg_integer()} | :hidden | nil

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push `next` to the terminal and adopt it as the new truth."
  @spec flush(Screen.t()) :: :ok
  def flush(%Screen{} = next), do: GenServer.cast(__MODULE__, {:flush, next})

  @doc """
  Push `next` **and** place the hardware cursor in the same write — `cursor` is
  `{x, y}` (0-indexed) to show-and-move it, or `:hidden`. Emitting the cursor with
  the cell diff keeps it correctly ordered *after* the cells, so the diff's own
  intermediate cursor moves don't leave it in the wrong place.
  """
  @spec flush(Screen.t(), {non_neg_integer(), non_neg_integer()} | :hidden) :: :ok
  def flush(%Screen{} = next, cursor), do: GenServer.cast(__MODULE__, {:flush, next, cursor})

  @doc """
  Reset the renderer's model of the terminal to a blank screen of the
  given size. Use on terminal resize — the *next* flush will then
  draw everything against a known-blank baseline.
  """
  @spec resize(non_neg_integer(), non_neg_integer()) :: :ok
  def resize(w, h) when w >= 0 and h >= 0,
    do: GenServer.cast(__MODULE__, {:resize, w, h})

  @doc "Inspect the renderer's current snapshot (test/debug)."
  @spec current() :: Screen.t()
  def current, do: GenServer.call(__MODULE__, :current)

  ## Diff (pure)

  @doc """
  Iodata that, when written to the terminal, transforms `current`
  into `next`. Returns `[]` if nothing changed.
  """
  @spec diff(Screen.t(), Screen.t()) :: iodata()
  def diff(%Screen{} = current, %Screen{} = next) do
    if current.w == next.w and current.h == next.h do
      rows_diff(current, next)
    else
      # Dimensions changed — clear and re-emit everything in `next`.
      # Diffing against a blank of the new size gets every non-blank
      # cell of `next` into the output.
      ["\e[2J" | rows_diff(Screen.new(next.w, next.h), next)]
    end
  end

  @doc """
  The escape sequence that positions the hardware cursor: show + move to `{x, y}`
  (0-indexed → 1-indexed), `:hidden` to hide it, `nil`/anything else for no-op.
  The unconditional form — `frame/3` is the stateful one that avoids re-showing.
  """
  @spec cursor_seq({non_neg_integer(), non_neg_integer()} | :hidden | nil) :: iodata()
  def cursor_seq({x, y}) when x >= 0 and y >= 0, do: ["\e[?25h", cup(x, y)]
  def cursor_seq(:hidden), do: "\e[?25l"
  def cursor_seq(_), do: []

  @doc """
  The byte stream for one frame: the cell `diff` plus the cursor delta, wrapped in
  synchronized-output so the terminal presents it atomically. `last` is the cursor
  emitted on the previous frame (`{x, y} | :hidden | nil`); `cursor` is this frame's.

  Returns `[]` when nothing changed (the caller skips the write). The cursor is
  **shown** (`\\e[?25h`) only on a `hidden`/`nil` → shown transition, and
  **repositioned** only when the diff moved the hardware cursor or the cursor moved —
  so a settled cursor on an unchanged frame emits nothing and never resets its blink.
  """
  @spec frame(iodata(), cursor_state(), cursor_state()) :: iodata()
  def frame(diff, last, cursor) do
    moved? = IO.iodata_length(diff) > 0
    body = [diff, cursor_delta(last, cursor, moved?)]
    if IO.iodata_length(body) == 0, do: [], else: [@bsu, body, @esu]
  end

  # The cursor bytes given the previously-emitted cursor and whether the diff moved it.
  defp cursor_delta(last, :hidden, _moved), do: if(last == :hidden, do: [], else: "\e[?25l")

  defp cursor_delta(last, {x, y}, moved) do
    show = if last in [:hidden, nil], do: "\e[?25h", else: []
    pos = if moved or last != {x, y}, do: cup(x, y), else: []
    [show, pos]
  end

  defp cursor_delta(_last, nil, _moved), do: []

  # Cursor-position escape (0-indexed → 1-indexed).
  defp cup(x, y), do: ["\e[", Integer.to_string(y + 1), ";", Integer.to_string(x + 1), "H"]

  defp rows_diff(_current, %Screen{h: 0}), do: []
  defp rows_diff(_current, %Screen{w: 0}), do: []

  defp rows_diff(current, %Screen{h: h} = next) do
    for y <- 0..(h - 1) do
      diff_row(current, next, y)
    end
  end

  defp diff_row(current, %Screen{w: w} = next, y) do
    changed =
      for x <- 0..(w - 1),
          curr = Screen.get_cell(current, x, y),
          nxt = Screen.get_cell(next, x, y),
          not Cell.equal?(curr, nxt) do
        {x, nxt}
      end

    changed
    |> group_runs()
    |> Enum.map(fn {x, cells} -> emit_run(x, y, cells) end)
  end

  # [{x, cell}] in ascending x order → [{start_x, [cells]}], starting a new run
  # whenever x is non-adjacent OR the style changes — so each run paints under a
  # single SGR escape.
  defp group_runs([]), do: []
  defp group_runs([{x, cell} | rest]), do: do_group(rest, x, [cell], x, cell, [])

  defp do_group([], start_x, cells, _last, _style, acc),
    do: Enum.reverse([{start_x, Enum.reverse(cells)} | acc])

  defp do_group([{x, cell} | rest], start_x, cells, last, style, acc) do
    if x == last + 1 and same_style?(cell, style) do
      do_group(rest, start_x, [cell | cells], x, style, acc)
    else
      do_group(rest, x, [cell], x, cell, [{start_x, Enum.reverse(cells)} | acc])
    end
  end

  # Style-only equality (char ignored): two cells paint under the same SGR iff
  # their fg/bg match and their attr sets are equal.
  defp same_style?(a, b),
    do: a.fg == b.fg and a.bg == b.bg and MapSet.new(a.attrs) == MapSet.new(b.attrs)

  # Cursor move (1-indexed) + the run's characters. A styled run wraps them in its
  # SGR escape + a reset; a plain run (no SGR) emits just the move + chars, leaving
  # unstyled output byte-identical to plain character emission.
  defp emit_run(x, y, [first | _] = cells) do
    move = ["\e[", Integer.to_string(y + 1), ";", Integer.to_string(x + 1), "H"]
    chars = Enum.map(cells, & &1.char)

    case Sgr.escape(first.fg, first.bg, first.attrs) do
      "" -> [move, chars]
      sgr -> [move, sgr, chars, Sgr.reset()]
    end
  end

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, %{current: Screen.new(0, 0), cursor: nil}}

  @impl true
  def handle_cast({:flush, %Screen{} = next, cursor}, %{current: current, cursor: last} = state) do
    case frame(diff(current, next), last, cursor) do
      [] -> :ok
      io -> TerminalIO.write(io)
    end

    {:noreply, %{state | current: next, cursor: cursor}}
  end

  # Cells only, no cursor management. The diff moves the hardware cursor, so the
  # remembered cursor is now unknown (`nil`) — the next flush/2 will reposition it.
  def handle_cast({:flush, %Screen{} = next}, %{current: current} = state) do
    case diff(current, next) do
      [] -> {:noreply, %{state | current: next}}
      d -> TerminalIO.write([@bsu, d, @esu]); {:noreply, %{state | current: next, cursor: nil}}
    end
  end

  def handle_cast({:resize, w, h}, state) do
    {:noreply, %{state | current: Screen.new(w, h)}}
  end

  @impl true
  def handle_call(:current, _from, %{current: current} = state) do
    {:reply, current, state}
  end
end
