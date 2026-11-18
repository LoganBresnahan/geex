defmodule Geex.StopWatchdog do
  @moduledoc """
  Bounds geex's stop (BUG-21): `Geex.stop/0` arms it, and if the VM is still up `limit_ms/0`
  after the stop was asked, the terminal is put back and the VM halts.

  The stop can wait forever on a disk that hangs. Elixir's `File` calls that aren't `:raw` all go
  through OTP's one file server, `file_server_2`, which makes each call itself: one read that never
  returns (a stalled network disk, a FIFO in place of the file) holds it, and every other such call
  in the VM queues behind it with no time limit. On the way out geex makes several (the last
  session's keep, each ledger's lock removed, the discovery file's removal; a ledger's close entry
  is a `:raw` write), so each child that makes one is killed at its shutdown timeout; under `mix
  run`, Mix's own stop callback lists files the same way and `init:stop/0` never finishes. A normal
  stop takes 0.1–1.5 s.

  The watchdog runs outside geex's application: its group leader is the VM's `user` process (or
  `init`), not geex's application master, which kills every process it leads when the
  application stops. It does no `File` call: it asks `Geex.TerminalIO` to restore the terminal
  (a stop that got that far already has), logs a warning and syncs the log (a `:raw` file),
  giving those 1 s, and halts. Off under
  `mix test` (the `stop_watchdog` app gate); a test arms it with its own `restore` and `halt`.
  """

  require Logger

  @name __MODULE__
  # Past every normal stop measured (0.1–1.5 s, a 70 MB buffer's ledger closed among them).
  @limit_ms 10_000

  @doc "How long a stop may take before the watchdog ends it."
  @spec limit_ms() :: pos_integer()
  def limit_ms, do: @limit_ms

  @doc """
  Arm the watchdog, once: a later arm leaves the first deadline as it is. Does nothing when the
  `stop_watchdog` app gate is off, unless `enabled: true` is passed (a test's). `:after` replaces
  `limit_ms/0`, `:restore` and `:halt` (0-arity) the terminal's restore and the halt.
  """
  @spec arm(keyword()) :: :ok
  def arm(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, fn ->
         Application.get_env(:geex, :stop_watchdog, false)
       end) and
         Process.whereis(@name) == nil do
      start(
        Keyword.get(opts, :after, @limit_ms),
        Keyword.get(opts, :restore, &restore_terminal/0),
        Keyword.get(opts, :halt, &halt/0)
      )
    end

    :ok
  end

  defp start(limit, restore, halt) do
    pid = spawn(fn -> receive(do: (:go -> watch(limit, restore, halt))) end)
    Process.group_leader(pid, Process.whereis(:user) || Process.whereis(:init))

    # Two stops at once (the loop's and a signal's backstop): the first to register keeps its
    # deadline.
    try do
      Process.register(pid, @name)
      send(pid, :go)
    rescue
      ArgumentError -> Process.exit(pid, :kill)
    end
  end

  defp watch(limit, restore, halt) do
    Process.sleep(limit)
    restore.()
    say(limit)
    halt.()
  end

  # The warning and the log's sync, given at most `@say_ms`: a log rotating while the file
  # server is stuck makes the sync wait 5 s and lose the line, and a warning in logger's sync mode
  # can wait as long (mod-verify's probe).
  @say_ms 1_000

  defp say(limit) do
    {pid, ref} =
      spawn_monitor(fn ->
        Logger.warning(
          "geex: the stop didn't finish in #{div(limit, 1000)} s (a file call that never " <>
            "returns, BUG-21): the terminal restored, halting"
        )

        sync_log()
      end)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @say_ms -> Process.exit(pid, :kill)
    end
  end

  # Under a stop that got as far as `Geex.TerminalIO`'s `terminate/2`, the terminal is restored
  # and the process gone.
  defp restore_terminal do
    Geex.TerminalIO.restore(2_000)
  catch
    :exit, _ -> :ok
  end

  defp sync_log do
    _ = :logger_std_h.filesync(:geex_file)
    :ok
  catch
    _, _ -> :ok
  end

  # The status a normal stop gives (`System.stop/0`, the binary's `System.halt(0)`, OTP's own
  # SIGTERM handler): a nonzero one would make git abort a commit whose message was saved, with
  # geex as $EDITOR. `flush: false`: a port stuck writing to a terminal that's gone doesn't hold
  # the halt.
  defp halt, do: :erlang.halt(0, flush: false)
end
