defmodule Geex.CLI.Signals do
  @moduledoc """
  The installed binary's handler for OS signals (ADR-0036), in place of OTP's
  `erl_signal_handler`.

  The one difference is SIGTERM. OTP's handler calls `init:stop/0`. Under the binary, the
  application never finishes starting, so that stop skips `Geex.TerminalIO`'s `terminate/2`,
  which leaves the terminal on the alternate screen. Here SIGTERM goes through `Geex.stop/0`,
  the same orderly quit as `Ctrl-X`. SIGUSR1 and SIGQUIT halt, as OTP's handler does.
  """

  @behaviour :gen_event

  @doc "Replace OTP's signal handler with this one."
  @spec install() :: :ok | {:error, term()}
  def install do
    :gen_event.swap_handler(:erl_signal_server, {:erl_signal_handler, []}, {__MODULE__, []})
  end

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(:sigterm, state) do
    Geex.stop()
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

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_info, state), do: {:ok, state}
end
