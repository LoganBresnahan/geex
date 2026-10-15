defmodule Geex.TerminalIO do
  @moduledoc """
  Owns the `:prim_tty` handle.

  Wraps `:prim_tty` (OTP 26+ internal terminal primitive) to provide:

    * raw-mode terminal setup on init, restore on teardown
    * input bytes parsed into key/resize events via `Geex.Input.Parser`
    * event publication to subscribed processes
    * write API for downstream renderers

  Subscribers receive messages tagged `{:geex_io, event}`:

      {:geex_io, {:char, "a"}}
      {:geex_io, {:key, :up}}
      {:geex_io, {:ctrl, ?c}}
      {:geex_io, {:resize, rows, cols}}
      {:geex_io, :eof}

  ## Running

  `:prim_tty` needs exclusive ownership of the terminal — running this
  alongside iex's shell will conflict. Launch with:

      elixir --erl "-noshell -noinput" -S mix run -e 'Geex.run("path/to/file")'

  Or use the `Geex.run/1` entry function from a release/escript later.
  """

  use GenServer

  alias Geex.Input.Parser

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe the given pid (default: caller) to input/resize events."
  def subscribe(pid \\ self()) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end

  @doc "Stop receiving events for the given pid."
  def unsubscribe(pid \\ self()) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  @doc "Write iodata to the terminal (fire-and-forget)."
  def write(iodata) do
    GenServer.cast(__MODULE__, {:write, iodata})
  end

  @doc """
  Get the current `{cols, rows}` of the terminal — width first, then height, the
  order `:prim_tty.window_size/1` itself returns (`{State#state.cols, rows}`).
  """
  def window_size do
    GenServer.call(__MODULE__, :window_size)
  end

  ## gen_server callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # Belt-and-suspenders: also restore on raw VM halt (brutal_kill timeout,
    # `:erlang.halt/0`) where `terminate/2` doesn't get to run.
    System.at_exit(fn _ -> IO.write(:stdio, ["\e[?25h", "\e[?1049l"]) end)

    tty = :prim_tty.init(%{input: :raw, output: :raw})
    %{read: reader_ref} = :prim_tty.handles(tty)

    :prim_tty.write(tty, [
      "\e[?1049h",
      "\e[?25l",
      "\e[2J",
      "\e[H"
    ])

    # Arm the first read. `:prim_tty` sends `{ReaderRef, {data, bytes}}`
    # back to us when data arrives; we re-arm after each chunk.
    :prim_tty.read(tty, 1024)

    state = %{
      tty: tty,
      reader_ref: reader_ref,
      esc_buf: <<>>,
      # The pending flush of `esc_buf` (a ref), stale once more bytes arrive.
      esc_flush: nil,
      subscribers: MapSet.new(),
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    if MapSet.member?(state.subscribers, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)

      state = %{
        state
        | subscribers: MapSet.put(state.subscribers, pid),
          monitors: Map.put(state.monitors, ref, pid)
      }

      {:noreply, state}
    end
  end

  def handle_cast({:unsubscribe, pid}, state) do
    case Enum.find(state.monitors, fn {_ref, p} -> p == pid end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])

        state = %{
          state
          | subscribers: MapSet.delete(state.subscribers, pid),
            monitors: Map.delete(state.monitors, ref)
        }

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_cast({:write, iodata}, state) do
    :prim_tty.write(state.tty, iodata)
    {:noreply, state}
  end

  @impl true
  def handle_call(:window_size, _from, state) do
    {:reply, :prim_tty.window_size(state.tty), state}
  end

  @impl true
  def handle_info({ref, {:data, bytes}}, %{reader_ref: ref} = state) do
    {events, leftover} = Parser.parse(state.esc_buf <> bytes)
    Enum.each(events, fn ev -> publish({:geex_io, ev}, state) end)
    :prim_tty.read(state.tty, 1024)
    {:noreply, %{state | esc_buf: leftover, esc_flush: schedule_flush(leftover)}}
  end

  # Nothing followed the leftover within @esc_timeout_ms: it was typed, not sent as one
  # sequence (a bare Esc, or Esc then `[`). Deliver it (`Parser.flush/1`).
  def handle_info({:flush_esc, ref}, %{esc_flush: ref, esc_buf: buf} = state) do
    Enum.each(Parser.flush(buf), fn ev -> publish({:geex_io, ev}, state) end)
    {:noreply, %{state | esc_buf: <<>>, esc_flush: nil}}
  end

  def handle_info({:flush_esc, _stale}, state), do: {:noreply, state}

  def handle_info({ref, :eof}, %{reader_ref: ref} = state) do
    publish({:geex_io, :eof}, state)
    {:stop, :normal, state}
  end

  # `:prim_tty`'s reader process forwards terminal signals to us as
  # `{ReaderRef, {signal, sigwinch}}`. We hand it back to `prim_tty` to
  # update its internal geometry, then publish a resize event.
  def handle_info({ref, {:signal, signal}}, %{reader_ref: ref} = state) do
    new_tty = :prim_tty.handle_signal(state.tty, signal)

    # `:prim_tty.window_size/1` returns {cols, rows}; the resize event carries
    # {rows, cols} (its documented order), so swap on the way out.
    case :prim_tty.window_size(new_tty) do
      {:ok, {cols, rows}} -> publish({:geex_io, {:resize, rows, cols}}, state)
      _ -> :ok
    end

    {:noreply, %{state | tty: new_tty}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = %{
      state
      | subscribers: MapSet.delete(state.subscribers, pid),
        monitors: Map.delete(state.monitors, ref)
    }

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :prim_tty.write(state.tty, ["\e[?25h", "\e[?1049l"])
    _ = :prim_tty.reader_stop(state.tty)
    :ok
  end

  ## Internals

  defp publish(message, state) do
    Enum.each(state.subscribers, fn pid -> send(pid, message) end)
  end

  # A terminal writes a whole control sequence at once, so a leftover that sits this long was
  # typed by a person. 25–50 ms is the usual range in terminal editors.
  @esc_timeout_ms 40

  defp schedule_flush(<<>>), do: nil

  defp schedule_flush(_leftover) do
    ref = make_ref()
    Process.send_after(self(), {:flush_esc, ref}, @esc_timeout_ms)
    ref
  end
end
