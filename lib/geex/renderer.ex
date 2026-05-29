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

  ## v0.1 scope

    * Plain character emission only. Cells carry `fg`/`bg`/`attrs` but
      the renderer currently ignores them — SGR support lands next.
      A style-only change still triggers a redraw (cells compare unequal),
      so behaviour is correct, just slightly wasteful.

    * Dimension changes (initial flush, terminal resize) emit `\\e[2J`
      and diff `next` against a blank screen of the new size.

  ## Pure vs impure

  `diff/2` is a pure function — given two screens, returns iodata.
  Test it in isolation. The GenServer wrapper just owns `current` and
  pipes the result to `Geex.TerminalIO`.
  """

  use GenServer

  alias Geex.{Cell, Screen, TerminalIO}

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push `next` to the terminal and adopt it as the new truth."
  @spec flush(Screen.t()) :: :ok
  def flush(%Screen{} = next), do: GenServer.cast(__MODULE__, {:flush, next})

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
        {x, nxt.char}
      end

    changed
    |> group_runs()
    |> Enum.map(fn {x, chars} -> emit_run(x, y, chars) end)
  end

  # [{x, char}] in ascending x order → [{start_x, [chars]}], grouping
  # x-adjacent cells into a single run.
  defp group_runs([]), do: []
  defp group_runs([{x, char} | rest]), do: do_group(rest, x, [char], x, [])

  defp do_group([], start_x, chars, _last, acc),
    do: Enum.reverse([{start_x, Enum.reverse(chars)} | acc])

  defp do_group([{x, char} | rest], start_x, chars, last, acc) when x == last + 1,
    do: do_group(rest, start_x, [char | chars], x, acc)

  defp do_group([{x, char} | rest], start_x, chars, _last, acc),
    do: do_group(rest, x, [char], x, [{start_x, Enum.reverse(chars)} | acc])

  # Cursor move (1-indexed) + run of characters. The terminal advances
  # the cursor itself after each character; one move per run is enough.
  defp emit_run(x, y, chars) do
    ["\e[", Integer.to_string(y + 1), ";", Integer.to_string(x + 1), "H" | chars]
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

  def handle_cast({:resize, w, h}, state) do
    {:noreply, %{state | current: Screen.new(w, h)}}
  end

  @impl true
  def handle_call(:current, _from, %{current: current} = state) do
    {:reply, current, state}
  end
end
