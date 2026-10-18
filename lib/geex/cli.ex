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
      geex install rust    install a grammar or theme from the catalog (ADR-0040)
      geex install --list  the catalog, and what's installed or has an update
      geex install ./pkg   install a local package (a directory or a .zip)

  `geex -- install` opens a file named `install`.

  Under `mix run` (`Geex.run/1`) none of this applies: `standalone?/0` is false there.
  """

  @usage """
  usage: geex [PATH ...]
         geex install NAME ... | --list | ./PACKAGE

  Opens each PATH (a file, or a directory for its file tree) and shows the first.
  With no PATH, opens the current directory. Paths after `--` are never options.

  `install` adds a grammar or a theme from the catalog this geex was built with, or a
  local package; `install --list` shows the catalog. Nothing else uses the network.

    -v, --version   print the version
    -h, --help      print this help
  """

  @type parsed ::
          {:open, [String.t()]}
          | {:install, [String.t()]}
          | :version
          | :help
          | {:error, String.t()}

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

      iex> Geex.CLI.parse(["install", "rust", "go"])
      {:install, ["rust", "go"]}

      iex> Geex.CLI.parse(["--", "install"])
      {:open, ["install"]}
  """
  @spec parse([String.t()]) :: parsed()
  def parse([]), do: {:open, ["."]}
  def parse([flag]) when flag in ["-v", "--version"], do: :version
  def parse([flag]) when flag in ["-h", "--help"], do: :help
  def parse(["install" | args]), do: {:install, args}
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

      {:install, args} ->
        Geex.redirect_logs_to_file()
        # Always halt: a write to a closed stdout (`geex install --list | head`) raises here,
        # inside the application's start, and the VM would otherwise hang.
        code =
          try do
            install(args)
          catch
            _kind, _reason -> 1
          end

        System.halt(code)

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

  @doc """
  `geex install …` (ADR-0040 §6): install each catalog name or local package (a path: it has a
  `/`, or ends in `.zip`), or with `--list` (or nothing) print the catalog with what's
  installed. Prints as it goes, in the terminal, before any editor starts. Returns the exit
  status: 0, or 1 if anything failed. Also callable under `mix run`.
  """
  @spec install([String.t()]) :: 0 | 1
  def install(args) when args in [[], ["--list"]] do
    Geex.Installed.refresh()
    installed = Map.new(Geex.Installed.grammars() ++ Geex.Installed.themes(), &{&1["name"], &1})

    rows =
      for {kind, entries} <- [
            {"grammar", Geex.Catalog.grammars()},
            {"theme", Geex.Catalog.themes()}
          ],
          e <- entries do
        status =
          case installed[e["name"]] do
            nil ->
              "available"

            %{"installed" => _} = pkg ->
              if Geex.Installed.update?(pkg), do: "update", else: "installed"

            _bundled ->
              "bundled"
          end

        [e["name"], kind, e["display"], "#{div(e["size"] + 1023, 1024)} KB", status]
      end

    widths = for i <- 0..3, do: rows |> Enum.map(&String.length(Enum.at(&1, i))) |> Enum.max()

    for row <- rows do
      IO.puts(
        Enum.zip_with(row, widths ++ [0], &String.pad_trailing/2)
        |> Enum.join("  ")
        |> String.trim_trailing()
      )
    end

    0
  end

  def install(args) do
    results =
      for arg <- args do
        local? = String.contains?(arg, "/") or String.ends_with?(arg, ".zip")
        result = if local?, do: Geex.Install.install_path(arg), else: Geex.Install.install(arg)

        case result do
          {:ok, %{kind: kind, name: name, display: display}} ->
            IO.puts("installed #{kind} #{name} (#{display})")
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "geex install #{arg}: #{Geex.Install.describe(reason)}")
            :error
        end
      end

    if :error in results, do: 1, else: 0
  end

  # Best-effort: the halt mustn't wait on, or fail over, the log file.
  defp flush_log do
    _ = :logger_std_h.filesync(:geex_file)
    :ok
  catch
    _, _ -> :ok
  end
end
