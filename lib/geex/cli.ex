defmodule Geex.CLI do
  @moduledoc """
  The installed binary's entry point ([ADR-0036](../../doc/adr/0036-installed-binary.md)).

  The binary is a release wrapped by Burrito. Its launcher boots the release and then runs
  Elixir's own CLI on the arguments, and that CLI treats a plain argument as a script to
  evaluate: `geex notes.txt` would run `notes.txt` as Elixir code. So the binary does its work
  inside `Geex.Application.start/2`, before the boot finishes, and never returns from it. That
  is the pattern Burrito documents.

  Because the application never finishes starting, `System.stop/0` can't stop it in order: the
  terminal would be left on the alternate screen. So quitting (`Geex.stop/0`, and SIGTERM through
  `Geex.CLI.Signals`) sends this process `:geex_quit`. It stops the supervision tree, which runs
  each child's `terminate/2`, and then halts. `--version`, `--help` and bad options halt directly.

      geex                 the current directory: its tree and a scratch buffer
      geex a.txt sub/b.ex  open both, show the first
      geex DIR             DIR's tree and a scratch buffer
      geex -- -odd-name    paths after `--` are never options
      geex --version       print the version
      geex --help          print usage

  Under `mix run` (`Geex.run/1`) none of this applies: `standalone?/0` is false there.
  """

  @usage """
  usage: geex [PATH ...]

  Opens each PATH (a file, or a directory for its file tree) and shows the first.
  With no PATH, opens the current directory. Paths after `--` are never options.

    -v, --version   print the version
    -h, --help      print this help
  """

  @type parsed :: {:open, [String.t()]} | :version | :help | {:error, String.t()}

  @doc "True inside the Burrito-built binary: its launcher sets `__BURRITO=1`."
  @spec standalone?() :: boolean()
  def standalone?, do: System.get_env("__BURRITO") == "1"

  @doc """
  Parse the binary's arguments. Pure.

      iex> Geex.CLI.parse([])
      {:open, ["."]}

      iex> Geex.CLI.parse(["a.txt", "sub/b.ex"])
      {:open, ["a.txt", "sub/b.ex"]}

      iex> Geex.CLI.parse(["--", "--version"])
      {:open, ["--version"]}

      iex> Geex.CLI.parse(["-v"])
      :version

      iex> Geex.CLI.parse(["--frob"])
      {:error, "geex: unknown option --frob (use -- before a path that starts with -)"}
  """
  @spec parse([String.t()]) :: parsed()
  def parse([]), do: {:open, ["."]}
  def parse([flag]) when flag in ["-v", "--version"], do: :version
  def parse([flag]) when flag in ["-h", "--help"], do: :help
  def parse(["--" | paths]), do: open(paths)

  def parse(args) do
    case Enum.find(args, &String.starts_with?(&1, "-")) do
      nil -> {:open, args}
      "--" -> paths_around_dashes(args)
      flag -> {:error, "geex: unknown option #{flag} (use -- before a path that starts with -)"}
    end
  end

  # `a.txt -- -b`: everything before `--` must be a plain path, everything after is one.
  defp paths_around_dashes(args) do
    {before, ["--" | rest]} = Enum.split_while(args, &(&1 != "--"))

    case parse(before) do
      {:open, paths} -> open(paths ++ rest)
      other -> other
    end
  end

  defp open([]), do: {:open, ["."]}
  defp open(paths), do: {:open, paths}

  @doc """
  Run the binary on `argv`. `start_tree` starts geex's supervision tree and returns
  `{:ok, pid}`. Never returns.
  """
  @spec main([String.t()], (-> {:ok, pid()})) :: no_return()
  def main(argv, start_tree) do
    case parse(argv) do
      :version ->
        IO.puts("geex #{Application.spec(:geex, :vsn)}")
        System.halt(0)

      :help ->
        IO.write(@usage)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        IO.write(:stderr, @usage)
        System.halt(2)

      {:open, paths} ->
        Geex.redirect_logs_to_file()
        # Registered first, so a quit (`Geex.stop/0`) finds this process from the first key.
        Process.register(self(), __MODULE__)
        _ = Geex.CLI.Signals.install()
        {:ok, sup} = start_tree.()
        paths |> Enum.map(&Path.expand/1) |> Geex.open_paths()

        receive do
          :geex_quit -> :ok
        end

        # The orderly stop `System.stop/0` would skip here: each child's `terminate/2` runs, so
        # the terminal is restored, the buffers' ledgers are closed and the attestation
        # discovery file is removed.
        Supervisor.stop(sup)
        flush_log()
        System.halt(0)
    end
  end

  # Best-effort: the halt mustn't wait on, or fail over, the log file.
  defp flush_log do
    _ = :logger_std_h.filesync(:geex_file)
    :ok
  catch
    _, _ -> :ok
  end
end
