defmodule Geex.CLI do
  @moduledoc """
  The installed program's entry point ([ADR-0036](../../doc/adr/0036-installed-binary.md),
  [ADR-0041](../../doc/adr/0041-release-without-burrito.md)).

  The program is a release, started by its launcher (`rel/launcher.sh.eex`), which passes geex's
  arguments after `-extra` and `-geex standalone true` before them. geex does its work inside
  `Geex.Application.start/2`, before the boot finishes, and never returns from it: nothing after
  the boot (Elixir's own CLI, which would run a file argument as a script, ADR-0036 §2) gets the
  arguments.

  Because the application never finishes starting, `System.stop/0` can't stop it in order: the
  terminal would be left on the alternate screen. So quitting (`Geex.stop/0`, and SIGTERM through
  `Geex.CLI.Signals`) sends this process `:geex_quit`. It stops the supervision tree, which runs
  each child's `terminate/2`, and then halts. `--version`, `--help`, `install`, `highlight`,
  `self` and bad options halt directly.

      geex                 the current directory: its tree and a scratch buffer
      geex a.txt sub/b.ex  open both, show the first
      geex DIR             DIR's tree and a scratch buffer
      geex -- -odd-name    paths after `--` are never options
      geex --version       print the version
      geex --help          print usage
      geex install rust    install a grammar or theme from the catalog (ADR-0040)
      geex install --list  the catalog, and what's installed or has an update
      geex install --force rust  install it again though it's up to date
      geex install ./pkg   install a local package (a directory or a .zip)
      geex highlight FILE  print FILE highlighted (ANSI), with no editor
      geex self update     install the latest release (or `--version X`) with its install.sh
      geex self rollback   switch back to the previous version
      geex self prune      remove old versions no running geex uses
      geex self uninstall  remove geex's program files and its link

  `geex -- install` opens a file named `install`, `geex -- highlight` one named `highlight`, and
  `geex -- self` one named `self`.

  `self` is the launcher's (`rel/launcher.sh.eex`): it runs `install.sh` from its shell, with no
  VM, on the install the launcher is in. Only what it doesn't take reaches `parse/1`: a bad
  `self` command, or a release that install.sh didn't install, which has nothing to manage.

  Under `mix run` (`Geex.run/1`) none of this applies: `standalone?/0` is false there.
  """

  @usage """
  usage: geex [PATH ...]
         geex install [--force] NAME ... | --list | ./PACKAGE
         geex highlight FILE
         geex self update [--version VERSION] | rollback | prune | uninstall

  Opens each PATH (a file, or a directory for its file tree) and shows the first.
  With no PATH, opens the current directory. Paths after `--` are never options.

  `install` adds a grammar or a theme from the catalog this geex was built with, or a
  local package; `install --list` shows the catalog. Nothing else uses the network.

  `highlight` prints FILE with the installed grammar for it and the theme in use, as
  terminal colours, and exits.

  `self` manages this geex's install with the install.sh it came with: `update` to the
  latest release (or VERSION), `rollback` to the previous version, `prune` old versions,
  or `uninstall` (grammars, themes, settings and the edit history are kept).

    -v, --version   print the version
    -h, --help      print this help
  """

  @type parsed ::
          {:open, [String.t()]}
          | {:install, [String.t()]}
          | {:highlight, [String.t()]}
          | {:self, [String.t()]}
          | :version
          | :help
          | {:error, String.t()}

  @doc """
  True in the installed program: its launcher starts the VM with `-geex standalone true`, which
  sets that application environment key. A command-line flag, not an environment variable, so
  nothing geex starts inherits it.
  """
  @spec standalone?() :: boolean()
  def standalone?, do: Application.get_env(:geex, :standalone) == true

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

      iex> Geex.CLI.parse(["highlight", "a.json"])
      {:highlight, ["a.json"]}

      iex> Geex.CLI.parse(["self", "prune"])
      {:self, ["prune"]}
  """
  @spec parse([String.t()]) :: parsed()
  def parse([]), do: {:open, ["."]}
  def parse([flag]) when flag in ["-v", "--version"], do: :version
  def parse([flag]) when flag in ["-h", "--help"], do: :help
  def parse(["install" | args]), do: {:install, args}
  def parse(["highlight" | args]), do: {:highlight, args}
  def parse(["self" | args]), do: {:self, args}
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
        # Always halt, and don't wait long on stdout: after `geex install --list | head -1` the
        # pipe is closed, a write to it can raise, and a halt's flush would wait forever.
        code =
          try do
            install(args)
          catch
            kind, reason ->
              # Best-effort: stderr may be closed too.
              try do
                IO.puts(:stderr, "geex install: " <> Exception.format_banner(kind, reason))
              catch
                _, _ -> :ok
              end

              1
          end

        :erlang.halt(code, flush_timeout: 2_000)

      {:highlight, args} ->
        Geex.redirect_logs_to_file()
        :erlang.halt(highlight(args), flush_timeout: 2_000)

      {:self, args} ->
        {message, code} = self_command(args)
        IO.write(:stderr, message)
        :erlang.halt(code, flush_timeout: 2_000)

      {:open, paths} ->
        Geex.redirect_logs_to_file()
        # Embedded mode loads every module at boot, so a running geex needs none of its release's
        # files but the VM's helper programs (the launcher's `-mode embedded`, ADR-0041 §2).
        require Logger

        Logger.info(
          "geex: #{Application.spec(:geex, :vsn)}, loading code in #{:code.get_mode()} mode"
        )

        # Registered first, so a quit (`Geex.stop/0`) finds this process from the first key.
        Process.register(self(), __MODULE__)
        _ = Geex.CLI.Signals.install()

        sup =
          case start_tree.() do
            {:ok, sup} ->
              sup

            {:error, reason} ->
              Logger.error("geex: couldn't start: #{inspect(reason)}")
              tty? = :prim_tty.isatty(:stdin) == true and :prim_tty.isatty(:stdout) == true
              IO.puts(:stderr, start_failure(reason, System.get_env("TERM"), tty?))
              flush_log()
              :erlang.halt(1, flush_timeout: 2_000)
          end

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
  `geex self …` as far as the VM sees it: the launcher runs every `self` command it takes, so
  one that reaches here is either not a `self` command (exit 2), or from a release install.sh
  didn't install (exit 1), which is told how to install geex. Pure: returns what to print on
  stderr, and the exit status.

      iex> {_, 2} = Geex.CLI.self_command(["frob"])

      iex> {message, 1} = Geex.CLI.self_command(["update", "--version", "0.3.2"])
      iex> message =~ "releases/latest/download/install.sh | sh"
      true
  """
  @spec self_command([String.t()]) :: {String.t(), 1 | 2}
  def self_command(args) do
    if self_command?(args) do
      {"""
       geex self: this geex wasn't installed by install.sh, so it has no install to manage.
       Install or update geex with:

           curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh
       """, 1}
    else
      {"usage: geex self update [--version VERSION] | rollback | prune | uninstall\n", 2}
    end
  end

  defp self_command?([cmd]) when cmd in ~w(update rollback prune uninstall), do: true
  defp self_command?(["update", "--version", _]), do: true
  defp self_command?(_), do: false

  @doc """
  `geex install …` (ADR-0040 §6): install each catalog name or local package (a path: it has a
  `/`, or ends in `.zip`), or with `--list` (or nothing) print the catalog with what's
  installed. Prints as it goes, in the terminal, before any editor starts. Returns the exit
  status: 0, or 1 if anything failed. Also callable under `mix run`.
  """
  @spec install([String.t()]) :: 0 | 1
  def install(args) when args in [[], ["--list"]] do
    Geex.Installed.refresh()

    installed =
      Map.new(
        Enum.map(Geex.Installed.grammars(), &{{"grammar", &1["name"]}, &1}) ++
          Enum.map(Geex.Installed.themes(), &{{"theme", &1["name"]}, &1})
      )

    rows =
      for {kind, entries} <- [
            {"grammar", Geex.Catalog.grammars()},
            {"theme", Geex.Catalog.themes()}
          ],
          e <- entries do
        status =
          case installed[{kind, e["name"]}] do
            nil -> "available"
            pkg -> if Geex.Installed.update?(pkg), do: "update", else: "installed"
          end

        [e["name"], kind, e["display"], "#{div(e["size"] + 1023, 1024)} KB", status]
      end

    widths = for i <- 0..3, do: rows |> Enum.map(&String.length(Enum.at(&1, i))) |> Enum.max()

    # One write: a reader that stops early (`| head`) then closes the pipe after it.
    IO.write(
      Enum.map(rows, fn row ->
        line = Enum.zip_with(row, widths ++ [0], &String.pad_trailing/2) |> Enum.join("  ")
        String.trim_trailing(line) <> "\n"
      end)
    )

    0
  end

  def install(args) do
    case Enum.split_with(args, &(&1 == "--force")) do
      # `--force` alone, or with `--list`, is the listing: there's nothing to force.
      {_force, rest} when rest in [[], ["--list"]] -> install(rest)
      {force, names} -> install_each(names, force != [])
    end
  end

  defp install_each(args, force?) do
    results =
      for arg <- args do
        local? = String.contains?(arg, "/") or String.ends_with?(arg, ".zip")

        result =
          if local?,
            do: Geex.Install.install_path(arg),
            else: Geex.Install.install(arg, force: force?)

        case result do
          {:ok, %{unchanged: true, name: name}} ->
            IO.puts("#{name} is already installed (up to date; --force installs it again)")
            :ok

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

  @doc """
  What to tell the user when the editor couldn't start, from the supervision tree's `reason`,
  `TERM`, and whether stdin and stdout are a terminal. `:prim_tty` refuses (`:enotsup`) both no
  terminal and a terminal type it can't look up.

      iex> enotsup = {:shutdown, {:failed_to_start_child, Geex.TerminalIO, {:enotsup, []}}}
      iex> Geex.CLI.start_failure(enotsup, "rxvt-unicode", true)
      "geex: can't drive this terminal: TERM=rxvt-unicode has no terminfo entry on this system"
      iex> Geex.CLI.start_failure(enotsup, "xterm", false)
      "geex: needs a terminal, and its input or output isn't one (to print a file in colour: geex highlight FILE)"

      iex> Geex.CLI.start_failure(:boom, nil, true)
      "geex: couldn't start (the log has the details: " <> Geex.log_file() <> ")"
  """
  @spec start_failure(term(), String.t() | nil, boolean()) :: String.t()
  def start_failure(
        {:shutdown, {:failed_to_start_child, Geex.TerminalIO, {:enotsup, _}}},
        term,
        tty?
      ) do
    if tty? do
      "geex: can't drive this terminal: TERM=#{term || "(unset)"} has no terminfo entry " <>
        "on this system"
    else
      "geex: needs a terminal, and its input or output isn't one " <>
        "(to print a file in colour: geex highlight FILE)"
    end
  end

  def start_failure(_reason, _term, _tty?),
    do: "geex: couldn't start (the log has the details: " <> Geex.log_file() <> ")"

  @doc """
  `geex highlight FILE` (ADR-0041 §6): print FILE highlighted as ANSI, with the installed grammar
  its name picks and the theme the settings keep (else the built-in terminal theme). No editor,
  no terminal: a check that the VM, the tree_sitter_wasm NIF, an installed grammar and a theme
  all work where geex is installed, which a smoke test can run. Returns the exit status: 0, 1
  when FILE can't be highlighted, 2 for bad arguments. Also callable under `mix run`.
  """
  @spec highlight([String.t()]) :: 0 | 1 | 2
  def highlight([path]) do
    with {:ok, text} <- read(path),
         {:ok, ansi} <- ansi(text, path) do
      IO.write(ansi)
      0
    else
      {:error, message} ->
        IO.puts(:stderr, "geex highlight #{path}: #{message}")
        1
    end
  end

  def highlight(_args) do
    IO.puts(:stderr, "usage: geex highlight FILE")
    2
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, posix} -> {:error, :file.format_error(posix) |> to_string()}
    end
  end

  @doc false
  # `text` highlighted as ANSI, by the installed grammar for `path`'s name.
  @spec ansi(String.t(), String.t()) :: {:ok, iodata()} | {:error, String.t()}
  def ansi(text, path) do
    with {:ok, lang} <- language(path),
         {:ok, spans} <- spans(text, lang) do
      {:ok, Geex.Ansi.highlight(theme(), text, spans)}
    end
  end

  defp language(path) do
    case Geex.Highlight.language_for_path(path) do
      {:ok, lang} ->
        {:ok, lang}

      :error ->
        have = Geex.Highlight.Grammars.available()

        {:error,
         "no installed grammar for it (installed: " <>
           if(have == [], do: "none", else: Enum.join(have, ", ")) <> "; see geex install --list)"}
    end
  end

  defp spans(text, lang) do
    case Geex.Highlight.spans(text, lang) do
      {:ok, spans} -> {:ok, spans}
      {:error, reason} -> {:error, "highlighting failed: #{inspect(reason)}"}
    end
  end

  defp theme do
    with name when is_binary(name) <- Geex.Settings.load()["theme"],
         {:ok, theme} <- Geex.Theme.named(name) do
      theme
    else
      _ -> Geex.Theme.default()
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
