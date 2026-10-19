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

    test "SIGTERM takes the same quit" do
      assert {:ok, nil} = CLI.Signals.handle_event(:sigterm, nil)
      assert_receive :geex_quit
    end

    test "other signals OTP's handler ignores are ignored" do
      assert {:ok, nil} = CLI.Signals.handle_event(:sighup, nil)
      refute_receive :geex_quit, 50
    end
  end
end
