defmodule Geex.CLITest do
  # The installed program's entry point (ADR-0036, ADR-0041): its arguments, `geex highlight`, and
  # how quitting reaches it. The program itself (the launcher, the terminal, the halt) is checked
  # live by /deploy and by CI's smoke tests.
  use ExUnit.Case, async: false
  doctest Geex.CLI

  alias Geex.CLI

  describe "parse/1" do
    test "paths open in order; none means the current directory" do
      assert CLI.parse([]) == {:open, ["."]}

      assert CLI.parse(["sub/n1.txt", "../b.txt", "dir"]) ==
               {:open, ["sub/n1.txt", "../b.txt", "dir"]}
    end

    test "-- ends the options, wherever it is" do
      assert CLI.parse(["--"]) == {:open, ["."]}
      assert CLI.parse(["--", "-v", "--help"]) == {:open, ["-v", "--help"]}
      assert CLI.parse(["a.txt", "--", "-b"]) == {:open, ["a.txt", "-b"]}
      assert CLI.parse(["a.txt", "--"]) == {:open, ["a.txt"]}
    end

    test "version and help, long and short" do
      assert CLI.parse(["--version"]) == :version
      assert CLI.parse(["-v"]) == :version
      assert CLI.parse(["--help"]) == :help
      assert CLI.parse(["-h"]) == :help
    end

    test "an option anywhere else is an error naming it, never a path" do
      assert {:error, message} = CLI.parse(["a.txt", "--frob"])
      assert message =~ "--frob"
      assert {:error, _} = CLI.parse(["-v", "a.txt"])
      assert {:error, _} = CLI.parse(["-x", "--", "a.txt"])
    end
  end

  test "standalone? is false outside the binary" do
    refute CLI.standalone?()
  end

  describe "highlight/1 (ADR-0041 §6)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "geex_cli_hl_#{Geex.Fixtures.uniq()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "prints the file in colour, by the installed grammar its name picks", %{dir: dir} do
      path = Path.join(dir, "a.json")
      File.write!(path, ~s|{"key": [1, true, "s"]}\n|)

      out = ExUnit.CaptureIO.capture_io(fn -> assert CLI.highlight([path]) == 0 end)
      assert out =~ "\e["
      assert out |> String.replace(~r/\e\[[0-9;]*m/, "") == ~s|{"key": [1, true, "s"]}\n|
    end

    test "a file no installed grammar covers, or none at all, fails and says why", %{dir: dir} do
      path = Path.join(dir, "a.unknown-ext")
      File.write!(path, "x")

      err =
        ExUnit.CaptureIO.capture_io(:stderr, fn -> assert CLI.highlight([path]) == 1 end)

      assert err =~ "no installed grammar"
      # It lists the languages installed: Markdown's companion highlights no file, so it isn't
      # one (ADR-0043 §7).
      [_, listed] = Regex.run(~r/installed: ([^;]*);/, err)
      assert "markdown" in String.split(listed, ", ")
      refute "markdown_inline" in String.split(listed, ", ")

      err =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.highlight([Path.join(dir, "gone.json")]) == 1
        end)

      assert err =~ "no such file"
      err = ExUnit.CaptureIO.capture_io(:stderr, fn -> assert CLI.highlight([]) == 2 end)
      assert err =~ "usage"
    end
  end

  describe "quitting under the binary" do
    # Stand in for the binary's entry process. With nothing registered, `Geex.stop/0` would
    # call `System.stop/0` and end this test run, so these tests always register first.
    setup do
      Process.register(self(), Geex.CLI)
      on_exit(fn -> if Process.whereis(Geex.CLI), do: Process.unregister(Geex.CLI) end)
      :ok
    end

    test "Geex.stop/0 tells the entry process instead of stopping the VM" do
      assert Geex.stop() == :ok
      assert_receive :geex_quit
    end

    test "SIGTERM and SIGHUP take the same quit, with no editor loop running" do
      refute Process.whereis(Geex.Loop)

      for signal <- [:sigterm, :sighup] do
        assert {:ok, nil} = CLI.Signals.handle_event(signal, nil)
        assert_receive :geex_quit
      end
    end

    # 2026-11-16: so a write under way finishes (`Geex.Loop.shutdown/0`); SIGHUP, the terminal
    # closing, ended the VM at once.
    test "with the editor loop running, SIGTERM and SIGHUP go through it" do
      # This process stands in for Geex.CLI; one beside it for the loop.
      me = self()
      loop = spawn_link(fn -> forward(me) end)
      Process.register(loop, Geex.Loop)
      on_exit(fn -> Process.exit(loop, :kill) end)

      for signal <- [:sigterm, :sighup] do
        assert {:ok, nil} = CLI.Signals.handle_event(signal, nil)
        assert_receive {:loop, :geex_shutdown}
        refute_received :geex_quit
      end
    end

    test "other signals OTP's handler ignores are ignored" do
      assert {:ok, nil} = CLI.Signals.handle_event(:sigusr2, nil)
      refute_receive :geex_quit, 50
    end

    # mod-verify's mutant: a backstop sooner than the loop's wait cuts a write it would let finish.
    test "the backstop comes after the loop's wait for a write and the last session's keep" do
      assert CLI.Signals.stop_anyway_ms() > Geex.Loop.shutdown_wait_ms() + 2_000
    end
  end

  defp forward(to) do
    receive do
      msg -> send(to, {:loop, msg})
    end

    forward(to)
  end
end
