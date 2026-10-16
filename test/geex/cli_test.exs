defmodule Geex.CLITest do
  # The installed binary's entry point (ADR-0036): its arguments, and how quitting reaches it.
  # The binary itself (Burrito, the terminal, the halt) is checked live by /deploy.
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
