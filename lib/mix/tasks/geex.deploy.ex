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
     tree_sitter_wasm NIF in release mode, which takes a few minutes.
  2. **Fresh unpack:** Burrito runs the binary from a directory named after the version, and it
     skips unpacking when that directory already exists. A dirty tree's version (`+<sha>.dirty`)
     repeats across builds, so the new build's directory is removed first, and the first run
     unpacks this build.
  3. **Check:** the new binary must print `geex <version>` for `--version`.
  4. **Install:** the binary goes to `$XDG_DATA_HOME/geex/bin/geex` (default
     `~/.local/share/geex/bin`), and the one it replaces is kept as `geex.prev`. The swap is a
     rename, so a running geex keeps its file. `~/.local/bin/geex` links to it. An existing
     `~/.local/bin/geex` that is anything else is left alone, and the task stops.

  Restart a running geex to use the new one. `--rollback` swaps `geex` and `geex.prev`.
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

    {_, status} =
      System.cmd("mix", ["release", "--overwrite"],
        env: [{"MIX_ENV", "prod"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("geex deploy: the build failed (exit #{status})")
  end

  defp install(built, bin_dir, link) do
    unless File.regular?(built), do: Mix.raise("geex deploy: no build at #{built}")

    fresh_unpack(built)
    version = check(built)

    File.mkdir_p!(bin_dir)
    target = Path.join(bin_dir, "geex")
    staged = target <> ".new"
    File.cp!(built, staged)
    File.chmod!(staged, 0o755)
    if File.exists?(target), do: File.rename!(target, target <> ".prev")
    File.rename!(staged, target)

    link!(target, link)
    Mix.shell().info("geex deploy: installed #{version} at #{target}, linked from #{link}")
  end

  # Remove the unpack directory this build would use, so its first run unpacks it.
  defp fresh_unpack(built) do
    case System.cmd(built, ["maintenance", "directory"], stderr_to_stdout: true) do
      {out, 0} ->
        dir = out |> String.split("\n", trim: true) |> List.last("") |> String.trim()

        if String.contains?(dir, "/.burrito/geex_erts-") do
          File.rm_rf!(dir)
        else
          Mix.raise("geex deploy: unexpected unpack directory #{inspect(dir)}")
        end

      {out, status} ->
        Mix.raise("geex deploy: `maintenance directory` failed (exit #{status}): #{out}")
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
