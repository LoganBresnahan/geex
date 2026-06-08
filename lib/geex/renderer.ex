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

  ## Pure vs impure

  `diff/2` is a pure function — given two screens, returns iodata.
  Test it in isolation. The GenServer wrapper just owns `current` and
  pipes the result to `Geex.TerminalIO`.
  """

  use GenServer

  alias Geex.{Cell, Screen, Sgr, TerminalIO}

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
  Appended after the cell diff by `flush/2`.
  """
  @spec cursor_seq({non_neg_integer(), non_neg_integer()} | :hidden | nil) :: iodata()
  def cursor_seq({x, y}) when x >= 0 and y >= 0,
    do: ["\e[?25h", "\e[", Integer.to_string(y + 1), ";", Integer.to_string(x + 1), "H"]

  def cursor_seq(:hidden), do: "\e[?25l"
  def cursor_seq(_), do: []

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
  def init(_opts), do: {:ok, %{current: Screen.new(0, 0)}}

  @impl true
  def handle_cast({:flush, %Screen{} = next}, %{current: current} = state) do
    case diff(current, next) do
      [] -> {:noreply, %{state | current: next}}
      iodata -> TerminalIO.write(iodata); {:noreply, %{state | current: next}}
    end
  end

  # Cell diff + cursor placement in one write. The cursor is (re)emitted every
  # frame (it may move without any cell changing — e.g. an arrow key), so unlike
  # flush/1 this always writes.
  def handle_cast({:flush, %Screen{} = next, cursor}, %{current: current} = state) do
    TerminalIO.write([diff(current, next), cursor_seq(cursor)])
    {:noreply, %{state | current: next}}
  end

  def handle_cast({:resize, w, h}, state) do
    {:noreply, %{state | current: Screen.new(w, h)}}
  end

  @impl true
  def handle_call(:current, _from, %{current: current} = state) do
    {:reply, current, state}
  end
end
