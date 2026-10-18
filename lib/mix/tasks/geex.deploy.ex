defmodule Mix.Tasks.Geex.Deploy do
  @shortdoc "Build the geex binary with Burrito and install it as ~/.local/bin/geex (ADR-0036)"
  @moduledoc """
  Build geex into one executable and install it on this machine
  ([ADR-0036](../../../doc/adr/0036-installed-binary.md)).

      mix geex.deploy             build, check, install
      mix geex.deploy --no-build  install the last build (burrito_out/geex_linux) as it is
      mix geex.deploy --rollback  put the previously installed binary back

  1. **Build:** `MIX_ENV=prod mix release --overwrite`. That assembles the release, and
     Burrito wraps it into `burrito_out/geex_linux`. The first prod build compiles the
     tree_sitter_wasm NIF in release mode, which takes a few minutes. The old `geex.app` is
     removed first, so the version is this commit's even when no module changed, and so is
     the old release directory, so the binary carries this release only (BUG-6). Before the
     wrap, `trim_release/1` drops the VM programs geex never runs and strips the rest, and
     stops the build if a module geex calls is missing. Burrito's working copy in the temp
     directory is removed after.
  2. **Fresh unpack:** Burrito runs the binary from a directory named after the version, and it
     skips unpacking when that directory already exists. A dirty build's version (`….dirty`)
     repeats across builds, so the new build's directory is removed first, and the first run
     unpacks this build. Not while a running geex uses it: a committed build's is the same code
     and stays; a dirty one stops the deploy.
  3. **Check:** the new binary must print `geex <version>` for `--version`.
  4. **Install:** the binary goes to `$XDG_DATA_HOME/geex/bin/geex` (default
     `~/.local/share/geex/bin`), and the one it replaces is kept as `geex.prev`. The swap is a
     rename, so a running geex keeps its file. `~/.local/bin/geex` links to it. An existing
     `~/.local/bin/geex` that is anything else is left alone, and the task stops.
  5. **Prune:** Burrito never removes an older geex unpack (semver ignores `+<sha>`), so the
     task removes the other `geex_erts-*`. It keeps `geex.prev`'s, and any a running process
     uses (its executable or an argument under it, from `/proc`): a VM loads modules from its
     unpack as it needs them, so removing it crashes the geex running there (BUG-4). A later
     deploy removes it once that geex has quit.

  `--rollback` swaps `geex` and `geex.prev`.
  """
  use Mix.Task

  @built "burrito_out/geex_linux"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [build: :boolean, rollback: :boolean])

    bin_dir = bin_dir()
    link = Path.expand("~/.local/bin/geex")

    if opts[:rollback] do
      rollback(bin_dir, link)
    else
      if Keyword.get(opts, :build, true), do: build()
      install(Path.expand(@built), bin_dir, link)
    end
  end

  defp build do
    Mix.shell().info("geex deploy: building (MIX_ENV=prod mix release --overwrite)")
    # The version names the commit, but Mix rewrites geex.app only when a module changed, so a
    # docs-only commit would keep the previous commit's version. Removing it makes it fresh.
    File.rm("_build/prod/lib/geex/ebin/geex.app")
    # `mix release` keeps every earlier release beside the new one (each build's version
    # differs), and Burrito packs the whole directory: the binary carried every geex since the
    # first deploy, grammars and themes included after geex went bare (BUG-6). Start empty.
    File.rm_rf!("_build/prod/rel/geex")
    staged = burrito_work_dirs()

    {_, status} =
      System.cmd("mix", ["release", "--overwrite"],
        env: [{"MIX_ENV", "prod"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    # Burrito leaves its working copy of the release (~120 MB) in the temp directory. Remove the
    # ones this build made, not another project's that may be building now.
    for dir <- burrito_work_dirs() -- staged, do: File.rm_rf(dir)

    if status != 0, do: Mix.raise("geex deploy: the build failed (exit #{status})")
  end

  defp burrito_work_dirs, do: Path.wildcard(Path.join(System.tmp_dir!(), "burrito_build_*"))

  # The VM's own programs the binary runs (ADR-0036's 2026-10-18 amendment): Burrito's launcher
  # execs `erlexec`, which starts `beam.smp`; `erl_child_setup` starts every port (git,
  # inotifywait); `inet_gethost` looks up a host name for a download (ADR-0040 §3). The rest of
  # `erts-*/bin` is tooling (erlc, dialyzer, ct_run, escript…), embedded-system helpers (heart,
  # run_erl, to_erl) and `epmd`, which only distribution starts.
  @erts_keep ~w(beam.smp erlexec erl_child_setup inet_gethost)

  # Modules geex's code names that no release has carried, each unreachable from a running
  # geex. Anything else missing stops the build: a trim cut something geex calls.
  @expected_unresolved %{
    Mix => "the mix tasks under lib/mix, compiled into geex but run only under mix",
    Mix.Task => "the same",
    Mix.Project => "the same (mix geex.catalog reads catalog_release from it)",
    # A bare `:Dict`, not `Elixir.Dict`: Elixir's own Enum and URI name it, and no OTP or
    # Elixir release defines it.
    :Dict => "named in Elixir's Enum and URI; defined nowhere",
    :dbg => "inets' tracing (runtime_tools), for debugging httpc",
    :erl_syntax => "shell_docs_test (syntax_tools), stdlib's doc tests",
    :erl_syntax_lib => "the same"
  }

  @doc """
  A release step, between Mix's `:assemble` and Burrito's wrap: drop the VM programs geex never
  runs, strip the debug information from the ones it does (`beam.smp` carries ~43 MB of it), and
  check that every module geex's code reaches is still in the release (`unresolved/1`).
  """
  @spec trim_release(Mix.Release.t()) :: Mix.Release.t()
  def trim_release(%Mix.Release{path: path} = release) do
    [bin] = Path.wildcard(Path.join(path, "erts-*/bin"))
    trim_erts(bin, System.find_executable("strip"))

    case Map.drop(unresolved(path), Map.keys(@expected_unresolved)) do
      none when none == %{} ->
        release

      missing ->
        Mix.raise(
          "geex deploy: the release lacks modules geex's code calls: " <>
            Enum.map_join(missing, "; ", fn {m, from} ->
              "#{inspect(m)} (from #{inspect(from)})"
            end)
        )
    end
  end

  @doc false
  @spec expected_unresolved() :: %{module() => String.t()}
  def expected_unresolved, do: @expected_unresolved

  @doc false
  # Remove everything in an `erts-*/bin` directory but `@erts_keep`, and strip what's kept with
  # `strip` (an executable's path), when there is one.
  @spec trim_erts(Path.t(), Path.t() | nil) :: [String.t()]
  def trim_erts(bin, strip) do
    removed = for f <- File.ls!(bin), f not in @erts_keep, do: File.rm_rf!(Path.join(bin, f)) && f

    if strip do
      kept = for f <- @erts_keep, File.exists?(Path.join(bin, f)), do: Path.join(bin, f)
      {_, 0} = System.cmd(strip, ["--strip-debug" | kept], stderr_to_stdout: true)
    else
      Mix.shell().info("geex deploy: no `strip` on the PATH; the VM keeps its debug information")
    end

    Enum.sort(removed)
  end

  @doc """
  The modules called from code geex reaches that no `.beam` in the release at `rel` defines
  (nor the VM preloads), each with the modules that call it. Reached means: geex's own modules,
  and every module their calls lead to, transitively, by each `.beam`'s import table. A call
  through a variable (`apply/3`, `mod.fun()`) isn't in the table, so this is a floor: a module
  it misses can still be missing.
  """
  @spec unresolved(Path.t()) :: %{module() => [module()]}
  def unresolved(rel) do
    beams =
      Map.new(Path.wildcard(Path.join(rel, "lib/*/ebin/*.beam")), fn path ->
        {path |> Path.basename(".beam") |> String.to_atom(), path}
      end)

    roots = for {mod, path} <- beams, path =~ ~r|/lib/geex-[^/]+/ebin/|, do: mod
    reach(roots, MapSet.new(roots), beams, MapSet.new(:erlang.pre_loaded()), %{})
  end

  defp reach([], _seen, _beams, _preloaded, missing),
    do: Map.new(missing, fn {m, from} -> {m, from |> Enum.uniq() |> Enum.sort()} end)

  defp reach([mod | rest], seen, beams, preloaded, missing) do
    {:ok, {_, [imports: imports]}} =
      :beam_lib.chunks(String.to_charlist(beams[mod]), [:imports])

    called = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    new = Enum.reject(called, &(MapSet.member?(seen, &1) or MapSet.member?(preloaded, &1)))
    {found, lost} = Enum.split_with(new, &Map.has_key?(beams, &1))
    missing = Enum.reduce(lost, missing, &Map.update(&2, &1, [mod], fn from -> [mod | from] end))
    reach(found ++ rest, Enum.into(found, seen), beams, preloaded, missing)
  end

  defp install(built, bin_dir, link) do
    unless File.regular?(built), do: Mix.raise("geex deploy: no build at #{built}")

    dir = unpack_dir(built)
    fresh_unpack(dir)
    version = check(built)

    File.mkdir_p!(bin_dir)
    target = Path.join(bin_dir, "geex")
    staged = target <> ".new"
    File.cp!(built, staged)
    File.chmod!(staged, 0o755)
    if File.exists?(target), do: File.rename!(target, target <> ".prev")
    File.rename!(staged, target)

    link!(target, link)
    prev = target <> ".prev"
    prune_unpacks([dir | if(File.regular?(prev), do: [unpack_dir(prev)], else: [])])
    Mix.shell().info("geex deploy: installed #{version} at #{target}, linked from #{link}")
  end

  # The new build must run from its own files, so its unpack is removed first. A committed
  # build's unpack is that commit's, so one a running geex is using is kept as it is; a dirty
  # build's version repeats with other code under it, so deploying over a running one stops.
  defp fresh_unpack(dir) do
    case users(dir, in_use()) do
      [] ->
        File.rm_rf!(dir)

      pids ->
        if String.ends_with?(dir, ".dirty") do
          Mix.raise(
            "geex deploy: a running geex (pid #{Enum.join(pids, ", ")}) uses #{dir}, " <>
              "which this dirty build would replace; quit it first"
          )
        end
    end
  end

  # Where Burrito unpacks this binary: `~/.local/share/.burrito/geex_erts-<erts>_<version>`.
  defp unpack_dir(built) do
    case System.cmd(built, ["maintenance", "directory"], stderr_to_stdout: true) do
      {out, 0} ->
        dir = out |> String.split("\n", trim: true) |> List.last("") |> String.trim()

        if String.contains?(dir, "/.burrito/geex_erts-"),
          do: dir,
          else: Mix.raise("geex deploy: unexpected unpack directory #{inspect(dir)}")

      {out, status} ->
        Mix.raise("geex deploy: `maintenance directory` failed (exit #{status}): #{out}")
    end
  end

  # Burrito removes only versions that sort older, and semver ignores the `+<sha>` part, so it
  # never removes a geex build's unpack: each would stay (~40 MB). Keep the new one, geex.prev's
  # (so `--rollback` starts at once), and any a running geex is using: a VM loads modules from
  # it as it needs them, so removing it under one crashes it.
  defp prune_unpacks([new | _] = keep) do
    dirs = Path.wildcard(Path.join(Path.dirname(new), "geex_erts-*"))
    procs = in_use()

    for dir <- stale_unpacks(dirs, keep, procs) do
      File.rm_rf!(dir)
      Mix.shell().info("geex deploy: removed the old unpack #{Path.basename(dir)}")
    end

    for dir <- dirs -- keep, pids = users(dir, procs), pids != [] do
      Mix.shell().info(
        "geex deploy: kept #{Path.basename(dir)}, in use by pid #{Enum.join(pids, ", ")}"
      )
    end

    :ok
  end

  @doc """
  The unpacks in `dirs` to remove: not one of `keep`, and no process in `procs` (each
  `{pid, paths}`, its executable and arguments) runs from it.

      iex> beam = {7, ["/b/geex_erts-1_0.1.0+aa/erts/bin/beam.smp", "-root", "/b/geex_erts-1_0.1.0+aa"]}
      iex> Mix.Tasks.Geex.Deploy.stale_unpacks(
      ...>   ["/b/geex_erts-1_0.1.0+aa", "/b/geex_erts-1_0.1.0+bb", "/b/geex_erts-1_0.1.0+cc"],
      ...>   ["/b/geex_erts-1_0.1.0+cc"],
      ...>   [beam, {8, ["/bin/sh", "/b/geex_erts-1_0.1.0+bbb"]}]
      ...> )
      ["/b/geex_erts-1_0.1.0+bb"]
  """
  @spec stale_unpacks([Path.t()], [Path.t()], [{pos_integer(), [String.t()]}]) :: [Path.t()]
  def stale_unpacks(dirs, keep, procs) do
    Enum.filter(dirs, &(&1 not in keep and users(&1, procs) == []))
  end

  @doc "The processes in `procs` running from `dir`: a path that is it, or is under it."
  @spec users(Path.t(), [{pos_integer(), [String.t()]}]) :: [pos_integer()]
  def users(dir, procs) do
    for {pid, paths} <- procs,
        Enum.any?(paths, &(&1 == dir or String.starts_with?(&1, dir <> "/"))),
        do: pid
  end

  @doc false
  # Each process's executable and arguments, from /proc. A process that ends while it is read,
  # or that isn't ours to read, has none.
  @spec in_use() :: [{pos_integer(), [String.t()]}]
  def in_use do
    for entry <- File.ls!("/proc"), pid = parse_pid(entry) do
      exe =
        case File.read_link("/proc/#{pid}/exe") do
          {:ok, exe} -> [exe]
          {:error, _} -> []
        end

      args =
        case File.read("/proc/#{pid}/cmdline") do
          {:ok, cmdline} -> String.split(cmdline, <<0>>, trim: true)
          {:error, _} -> []
        end

      {pid, exe ++ args}
    end
  end

  defp parse_pid(entry) do
    case Integer.parse(entry) do
      {pid, ""} -> pid
      _ -> nil
    end
  end

  defp check(built) do
    case System.cmd(built, ["--version"], stderr_to_stdout: true) do
      {"geex " <> version, 0} ->
        String.trim(version)

      {out, status} ->
        Mix.raise("geex deploy: `#{built} --version` failed (exit #{status}): #{out}")
    end
  end

  defp rollback(bin_dir, link) do
    target = Path.join(bin_dir, "geex")
    prev = target <> ".prev"
    unless File.regular?(prev), do: Mix.raise("geex deploy: nothing to roll back to (#{prev})")

    swap = target <> ".swap"
    File.rename!(target, swap)
    File.rename!(prev, target)
    File.rename!(swap, prev)
    link!(target, link)
    Mix.shell().info("geex deploy: rolled back to #{check(target)}; the replaced one is #{prev}")
  end

  defp link!(target, link) do
    case File.read_link(link) do
      {:ok, ^target} ->
        :ok

      {:ok, other} ->
        Mix.raise("geex deploy: #{link} links to #{other}, not #{target}; left alone")

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(link))
        File.ln_s!(target, link)

      {:error, _} ->
        Mix.raise("geex deploy: #{link} exists and isn't a link; left alone")
    end
  end

  defp bin_dir do
    data =
      case System.get_env("XDG_DATA_HOME") do
        empty when empty in [nil, ""] -> Path.expand("~/.local/share")
        dir -> dir
      end

    Path.join([data, "geex", "bin"])
  end
end
