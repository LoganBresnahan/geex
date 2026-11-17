defmodule Geex.CLI.Signals do
  @moduledoc """
  geex's handler for OS signals (ADR-0036), in place of OTP's `erl_signal_handler`: the
  installed binary's (`Geex.CLI`) and `Geex.run/1`'s.

  SIGTERM and SIGHUP leave as the terminal closing does (`Geex.Loop.shutdown/0`): a save under way
  is let finish, for up to 30 s, and then the same orderly stop as `Ctrl-X` (`Geex.stop/0`), the
  last session kept. OTP's handler calls `init:stop/0` for SIGTERM, which under the binary skips
  `Geex.TerminalIO`'s `terminate/2` and leaves the terminal on the alternate screen (the application
  never finishes starting); and SIGHUP, the terminal closing, ended the VM at once, cutting short
  any write under way (2026-11-16). Should the loop not get as far as stopping, geex stops anyway
  after 35 s (the binary's entry process is told to; under `mix run`, `System.stop/0`). SIGUSR1 and
  SIGQUIT halt, as OTP's handler does.
  """

  @behaviour :gen_event

  # Longer than the loop's wait for a save under way (`Geex.Loop.shutdown/0`, 30 s), so it never
  # cuts one the loop would let finish.
  @stop_anyway_ms 35_000

  @doc false
  # For the test that it comes after the loop's wait.
  def stop_anyway_ms, do: @stop_anyway_ms

  @doc "Replace OTP's signal handler with this one."
  @spec install() :: :ok | {:error, term()}
  def install do
    otp = {:erl_signal_handler, []}

    with :ok <- :gen_event.swap_handler(:erl_signal_server, otp, {__MODULE__, []}) do
      # The OS default for SIGHUP ends the VM; handled, it comes here. Only once this handler is
      # in: OTP's would ignore it.
      :os.set_signal(:sighup, :handle)
    end
  end

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(signal, state) when signal in [:sigterm, :sighup] do
    Geex.Loop.shutdown()
    stop_anyway()
    {:ok, state}
  end

  def handle_event(:sigusr1, state) do
    :erlang.halt(~c"Received SIGUSR1")
    {:ok, state}
  end

  def handle_event(:sigquit, state) do
    :erlang.halt()
    {:ok, state}
  end

  def handle_event(_signal, state), do: {:ok, state}

  # Should the loop not get as far as stopping: the binary's entry process told to stop, or under
  # `mix run` the orderly stop OTP's handler made (mod-verify's review: before, a wedged loop was
  # still stopped by SIGTERM there, and SIGHUP ended the VM). With neither an entry process nor a
  # loop, `Geex.Loop.shutdown/0` has already stopped it.
  defp stop_anyway do
    case {Process.whereis(Geex.CLI), Process.whereis(Geex.Loop)} do
      {cli, _} when is_pid(cli) -> Process.send_after(cli, :geex_quit, @stop_anyway_ms)
      {nil, loop} when is_pid(loop) -> :timer.apply_after(@stop_anyway_ms, System, :stop, [])
      {nil, nil} -> :ok
    end
  end

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_info, state), do: {:ok, state}
end
