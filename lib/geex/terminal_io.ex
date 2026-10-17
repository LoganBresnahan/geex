defmodule Geex.TerminalIO do
  @moduledoc """
  Owns the `:prim_tty` handle.

  Wraps `:prim_tty` (OTP 26+ internal terminal primitive) to provide:

    * raw-mode terminal setup on init, restore on teardown; Ctrl-C, Ctrl-Z, Ctrl-\\, Ctrl-S
      and Ctrl-Q arrive as keys, not as the tty's signals and flow control
    * mouse reports ([ADR-0039](../../doc/adr/0039-mouse.md)): on at start, off on the way out
      and while `set_mouse(false)`, on again after SIGCONT; and the system clipboard through
      OSC 52 (`copy/1`)
    * input bytes parsed into key/resize events via `Geex.Input.Parser`
    * event publication to subscribed processes
    * write API for downstream renderers

  Subscribers receive messages tagged `{:geex_io, event}`:

      {:geex_io, {:char, "a"}}
      {:geex_io, {:key, :up}}
      {:geex_io, {:ctrl, ?c}}
      {:geex_io, {:mouse, %{action: :press, button: :left, x: 4, y: 2, mods: []}}}
      {:geex_io, {:resize, rows, cols}}
      {:geex_io, :eof}

  ## Running

  `:prim_tty` needs exclusive ownership of the terminal — running this
  alongside iex's shell will conflict. Launch with:

      elixir --erl "-noshell -noinput" -S mix run -e 'Geex.run("path/to/file")'

  Or use the `Geex.run/1` entry function from a release/escript later.
  """

  use GenServer

  require Logger

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
  Turn the terminal's mouse reports on or off. Off, the terminal selects and copies text itself
  again (the `mouse` verb). Fire-and-forget.
  """
  @spec set_mouse(boolean()) :: :ok
  def set_mouse(on?) when is_boolean(on?), do: GenServer.cast(__MODULE__, {:mouse, on?})

  @doc """
  Put `text` on the system clipboard through the terminal (OSC 52, `osc52/1`). The terminal may
  not support it or may refuse it; nothing comes back either way. Fire-and-forget.
  """
  @spec copy(String.t()) :: :ok
  def copy(text) when is_binary(text), do: write(osc52(text))

  # Mouse reports: 1000 presses and releases, 1002 drags with a button held, 1006 the SGR form
  # (decimal coordinates, any size; `Geex.Input.Parser`). Turned off in the reverse order.
  # 1005 and 1015 (other encodings) are turned off, in case something left them on.
  @mouse_on ["\e[?1005l", "\e[?1015l", "\e[?1000h", "\e[?1002h", "\e[?1006h"]
  @mouse_off ["\e[?1006l", "\e[?1002l", "\e[?1000l"]

  # The most text sent to the system clipboard at once. A terminal caps what it takes (xterm a
  # few hundred kilobytes by default) and can stall on more; past this, only geex's own clipboard
  # has the text.
  @osc52_max 100_000

  @doc """
  The OSC 52 sequence that puts `text` on the system clipboard: `ESC ] 52 ; c ; <base64> BEL`.
  Empty for text over #{@osc52_max} bytes.

      iex> Geex.TerminalIO.osc52("hi")
      "\\e]52;c;aGk=\\a"
  """
  @spec osc52(String.t()) :: String.t()
  def osc52(text) when byte_size(text) > @osc52_max, do: ""
  def osc52(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"

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

    # Belt-and-suspenders: also restore when the VM's main script ends on its own. A halt
    # (`:erlang.halt/0`, `System.halt/1`, the `+Bd` SIGINT halt) runs no `at_exit` hook, so after
    # one the terminal stays as geex left it, as after a `kill -9`.
    System.at_exit(fn _ -> IO.write(:stdio, [@mouse_off, "\e[?25h", "\e[?1049l"]) end)

    tty = :prim_tty.init(%{input: :raw, output: :raw})
    %{read: reader_ref} = :prim_tty.handles(tty)
    {tty_dev, tty_modes} = take_keys()

    :prim_tty.write(tty, [
      "\e[?1049h",
      "\e[?25l",
      "\e[2J",
      "\e[H",
      @mouse_on
    ])

    # Arm the first read. `:prim_tty` sends `{ReaderRef, {data, bytes}}`
    # back to us when data arrives; we re-arm after each chunk.
    :prim_tty.read(tty, 1024)

    state = %{
      tty: tty,
      reader_ref: reader_ref,
      # The tty's device and its `stty -g` settings from before `take_keys/0`, put back on exit.
      tty_dev: tty_dev,
      tty_modes: tty_modes,
      # Whether mouse reports are on (`set_mouse/1`), so SIGCONT turns them on only if they were.
      mouse: true,
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

  def handle_cast({:mouse, on?}, state) do
    :prim_tty.write(state.tty, if(on?, do: @mouse_on, else: @mouse_off))
    {:noreply, %{state | mouse: on?}}
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
    # On SIGCONT (after an outside `kill -STOP`), `prim_tty` sets its raw mode again, which turns
    # the signal and flow-control keys back on.
    if signal == :sigcont and state.tty_dev, do: stty(state.tty_dev, ["-isig", "-ixon"])
    # A shell that took the terminal back while geex was stopped may have reset its modes.
    if signal == :sigcont and state.mouse, do: :prim_tty.write(new_tty, @mouse_on)

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
    restore_screen(state.tty)
    _ = :prim_tty.reader_stop(state.tty)
    if state.tty_modes, do: stty(state.tty_dev, [state.tty_modes])
    :ok
  end

  # `:prim_tty`'s raw mode leaves the tty's signal keys on (ISIG: Ctrl-C, Ctrl-Z, Ctrl-\) and its
  # flow control (IXON: Ctrl-S, Ctrl-Q), so those keys never reach geex: Ctrl-C killed the VM
  # with no cleanup, Ctrl-Z suspended it, Ctrl-S froze the screen (BUG-3). Turn both off so they
  # arrive as keys. Returns the tty's device and its settings from before, or `{nil, nil}` when
  # that fails; geex runs on with the keys as they were.
  defp take_keys do
    with {:ok, dev} <- File.read_link("/proc/#{System.pid()}/fd/0"),
         {modes, 0} <- stty(dev, ["-g"]),
         {_, 0} <- stty(dev, ["-isig", "-ixon"]) do
      {dev, String.trim(modes)}
    else
      failed ->
        Logger.warning(
          "geex terminal: couldn't turn off the tty's signal keys (#{inspect(failed)}); " <>
            "Ctrl-C, Ctrl-Z and Ctrl-S act on the terminal, not geex"
        )

        {nil, nil}
    end
  end

  # `stty` on the VM's own stdin device: a port's child has no controlling terminal, so it can't
  # use `/dev/tty`. Its errors come back as a nonzero status, never raised.
  defp stty(dev, args) do
    System.cmd("sh", ["-c", ~s|exec stty "$@" < "$0"|, dev | args], stderr_to_stdout: true)
  rescue
    e in ErlangError -> {Exception.message(e), :no_sh}
  end

  # `:prim_tty.write/2` only hands the bytes to its writer process. The installed binary halts
  # right after the tree stops (ADR-0036), which can kill the writer before it writes, and the
  # terminal stays on the alternate screen. So wait, briefly, for the writer to say it wrote.
  @restore_timeout_ms 500

  defp restore_screen(tty) do
    %{write: writer_ref} = :prim_tty.handles(tty)
    {:ok, monitor} = :prim_tty.write(tty, [@mouse_off, "\e[?25h", "\e[?1049l"], self())

    receive do
      {^writer_ref, :ok} -> :ok
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      @restore_timeout_ms -> :ok
    end

    Process.demonitor(monitor, [:flush])
  end

  ## Internals

  defp publish(message, state) do
    Enum.each(state.subscribers, fn pid -> send(pid, message) end)
  end

  # A terminal writes a whole control sequence at once, so a leftover that sits this long was
  # typed by a person. 25–50 ms is the usual range in terminal editors.
  @esc_timeout_ms 40

  defp schedule_flush(<<>>), do: nil

  defp schedule_flush(leftover) do
    if Parser.mouse_report?(leftover), do: nil, else: flush_later()
  end

  defp flush_later do
    ref = make_ref()
    Process.send_after(self(), {:flush_esc, ref}, @esc_timeout_ms)
    ref
  end
end
