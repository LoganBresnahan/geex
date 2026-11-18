defmodule Geex.StopWatchdogTest do
  # BUG-21: a disk that hangs held geex's stop (22 s from the binary, forever under `mix run`),
  # so `Geex.stop/0` arms a watchdog that puts the terminal back and halts. Off under `mix test`
  # (a halt would end the run): each test arms it with its own restore and halt. Its name is
  # global, so not async.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Geex.StopWatchdog

  setup do
    on_exit(fn ->
      if pid = Process.whereis(StopWatchdog), do: Process.exit(pid, :kill)
    end)
  end

  defp arm(ms, tag) do
    me = self()

    StopWatchdog.arm(
      enabled: true,
      after: ms,
      restore: fn -> send(me, {tag, :restored}) end,
      halt: fn -> send(me, {tag, :halted}) end
    )
  end

  # `Geex.stop/0` would call `System.stop/0` with nothing registered: a stand-in for the binary's
  # entry process.
  defp stand_in_cli do
    Process.register(self(), Geex.CLI)
    on_exit(fn -> if Process.whereis(Geex.CLI), do: Process.unregister(Geex.CLI) end)
  end

  test "off under test: Geex.stop/0 arms nothing" do
    stand_in_cli()
    assert Geex.stop() == :ok
    assert_received :geex_quit
    assert StopWatchdog.arm() == :ok
    refute Process.whereis(StopWatchdog)
  end

  # mod-verify's mutant: a `Geex.stop/0` that armed nothing passed the suite.
  test "with the gate on, Geex.stop/0 arms it" do
    stand_in_cli()
    Application.put_env(:geex, :stop_watchdog, true)
    on_exit(fn -> Application.put_env(:geex, :stop_watchdog, false) end)

    assert Geex.stop() == :ok
    Application.put_env(:geex, :stop_watchdog, false)
    pid = Process.whereis(StopWatchdog)
    # It carries the real halt: gone before its 10 s are.
    if pid, do: Process.exit(pid, :kill)
    assert is_pid(pid)
    assert_received :geex_quit
  end

  test "once the limit is past: the terminal put back, then the halt, said in the log" do
    log =
      capture_log(fn ->
        assert arm(50, :a) == :ok
        refute_receive {:a, _}, 20
        # The terminal first (mod-verify's mutant: `assert_receive` alone doesn't see the order).
        assert_receive {:a, first}, 500
        assert first == :restored
        assert_receive {:a, :halted}, 500
        # The log is written before the halt.
        Process.sleep(20)
      end)

    assert log =~ "the stop didn't finish in 0 s"
    assert log =~ "BUG-21"
  end

  test "a second arm leaves the first deadline" do
    arm(100, :first)
    arm(10, :second)
    refute_receive {:second, _}, 60
    assert_receive {:first, :halted}, 500
    refute_received {:second, _}
  end

  # An application's master kills every process it leads when the application stops: the
  # watchdog must outlive geex's.
  test "it runs outside the caller's application: its group leader is the VM's user process" do
    me = self()
    # A caller led by something else, as geex's processes are led by its application master.
    master = spawn_link(fn -> Process.sleep(:infinity) end)

    caller =
      spawn_link(fn ->
        receive(do: (:go -> arm(5_000, :gl)))
        send(me, :armed)
      end)

    Process.group_leader(caller, master)
    send(caller, :go)
    assert_receive :armed
    assert {:group_leader, gl} = Process.info(Process.whereis(StopWatchdog), :group_leader)
    assert gl == Process.whereis(:user)
    refute gl == master
  end

  test "with the terminal process already gone, it still halts" do
    me = self()
    refute Process.whereis(Geex.TerminalIO)

    capture_log(fn ->
      StopWatchdog.arm(enabled: true, after: 10, halt: fn -> send(me, :halted) end)
      assert_receive :halted, 500
    end)
  end

  test "its limit is past every normal stop, and ends well before the binary's 22 s" do
    assert StopWatchdog.limit_ms() in 5_000..15_000
  end
end
