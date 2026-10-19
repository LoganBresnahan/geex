defmodule Mix.Tasks.Geex.Deploy do
  @shortdoc "Build geex's release tarball and install it with install.sh (ADR-0041)"
  @moduledoc """
  Build geex and install it on this machine the way a release installs
  ([ADR-0041](../../../doc/adr/0041-release-without-burrito.md)).

      mix geex.deploy             build, check, install
      mix geex.deploy --no-build  install the last build (_build/package) as it is
      mix geex.deploy --rollback  switch back to the previous version

  1. **Build:** `MIX_ENV=prod mix release --overwrite`. Mix assembles the release, then two
     steps of geex's own run: `trim_release/1` drops the VM programs geex never runs, strips the
     rest, and stops the build if a module geex calls is missing, a native library is one the
     release can't count on, or the boot script names something that isn't there. `package/1`
     puts the launcher in `bin/geex` and packs the release into
     `_build/package/geex-<version>-<os>-<arch>.tar.gz`, with its `SHA256SUMS`. The first prod
     build compiles the tree_sitter_wasm NIF in release mode, which takes a few minutes. The old
     `geex.app` is removed first, so the version is this commit's even when no module changed,
     and so is the old release directory, so the tarball carries this release only (BUG-6).
  2. **Install:** `install.sh` from this checkout, with `GEEX_DOWNLOAD_URL` pointing at
     `_build/package`: the same script, checks and layout as `curl … | sh` from a release. It
     verifies the sha256, runs the new `geex --version`, unpacks into
     `$GEEX_INSTALL_DIR/versions/<version>`, points `~/.local/bin/geex` at it, and prunes
     versions older than the previous one that no running geex uses. A dirty build's version
     repeats with other code under it, so it is installed with `--force`; a committed build
     already installed is left as it is. `GEEX_INSTALL_DIR` and `GEEX_BIN_DIR` pass through, so
     a sandbox works.

  `--rollback` is `install.sh --rollback`.

  A build is for the machine it was built on (its VM is the one running Mix). One built with
  the runtime `rel/build-runtime.sh` makes, as CI's are, passes the native-library check that a
  release build (`GEEX_RELEASE=1`) enforces; one built with another OTP only warns.
  """
  use Mix.Task

  @package "_build/package"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [build: :boolean, rollback: :boolean])

    cond do
      opts[:rollback] ->
        install_sh(["--rollback"])

      true ->
        if Keyword.get(opts, :build, true), do: build()
        install(Path.expand(@package))
    end
  end

  defp build do
    Mix.shell().info("geex deploy: building (MIX_ENV=prod mix release --overwrite)")
    # The version names the commit, but Mix rewrites geex.app only when a module changed, so a
    # docs-only commit would keep the previous commit's version. Removing it makes it fresh.
    File.rm("_build/prod/lib/geex/ebin/geex.app")
    # `mix release` keeps every earlier release beside the new one (each build's version
    # differs), and the tarball packs the whole directory (BUG-6). Start empty.
    File.rm_rf!("_build/prod/rel/geex")

    {_, status} =
      System.cmd("mix", ["release", "--overwrite"],
        env: [{"MIX_ENV", "prod"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("geex deploy: the build failed (exit #{status})")
  end

  defp install(package) do
    {version, _target} =
      case Path.wildcard(Path.join(package, "geex-*.tar.gz")) do
        [tarball] -> parse_tarball(Path.basename(tarball))
        [] -> Mix.raise("geex deploy: no build in #{package}")
        many -> Mix.raise("geex deploy: more than one build in #{package}: #{inspect(many)}")
      end

    force = if String.ends_with?(version, ".dirty"), do: ["--force"], else: []

    install_sh(["--version", version | force], [{"GEEX_DOWNLOAD_URL", "file://" <> package}])
  end

  defp install_sh(args, env \\ []) do
    {_, status} =
      System.cmd("sh", [Path.expand("install.sh") | args],
        env: env,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("geex deploy: install.sh #{Enum.join(args, " ")} failed")
  end

  @doc """
  A tarball's version and target, from its name.

      iex> Mix.Tasks.Geex.Deploy.parse_tarball("geex-0.3.0+1a2b3c4d.5e6f7a8b-linux-x64.tar.gz")
      {"0.3.0+1a2b3c4d.5e6f7a8b", "linux-x64"}
  """
  @spec parse_tarball(String.t()) :: {String.t(), String.t()}
  def parse_tarball(name) do
    [arch, os | rest] =
      name |> String.trim_trailing(".tar.gz") |> String.split("-") |> Enum.reverse()

    ["geex" | version] = Enum.reverse(rest)
    {Enum.join(version, "-"), "#{os}-#{arch}"}
  end

  @doc """
  The `<os>-<arch>` this VM runs on, as release names spell it (`linux-x64`, `darwin-arm64`).
  A release carries the VM that built it, so this is the release's target too.
  """
  @spec target() :: String.t()
  def target, do: target(:os.type(), to_string(:erlang.system_info(:system_architecture)))

  @doc """
      iex> Mix.Tasks.Geex.Deploy.target({:unix, :linux}, "aarch64-unknown-linux-gnu")
      "linux-arm64"

      iex> Mix.Tasks.Geex.Deploy.target({:unix, :darwin}, "aarch64-apple-darwin24.6.0")
      "darwin-arm64"

      iex> Mix.Tasks.Geex.Deploy.target({:unix, :linux}, "x86_64-pc-linux-gnu")
      "linux-x64"
  """
  @spec target({atom(), atom()}, String.t()) :: String.t()
  def target(os_type, architecture) do
    os =
      case os_type do
        {:unix, :linux} -> "linux"
        {:unix, :darwin} -> "darwin"
      end

    arch =
      case architecture |> String.split("-") |> hd() do
        "x86_64" -> "x64"
        a when a in ["aarch64", "arm64"] -> "arm64"
      end

    "#{os}-#{arch}"
  end

  # The VM's own programs geex runs (ADR-0036's 2026-10-18 amendment): the launcher execs
  # `erlexec`, which starts `beam.smp`; `erl_child_setup` starts every port (git, inotifywait);
  # `inet_gethost` looks up a host name for a download (ADR-0040 §3). The rest of `erts-*/bin` is
  # tooling (erlc, dialyzer, ct_run, escript…), embedded-system helpers (heart, run_erl, to_erl)
  # and `epmd`, which only distribution starts.
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

  # The shared libraries a Linux release may link (ADR-0041 §1): glibc's own, which every system
  # the release runs on has, and GCC's unwinder, which Rust's standard library links (the
  # tree_sitter_wasm NIF) and every glibc system carries. OpenSSL, ncurses, zlib and the C++
  # runtime are linked in statically.
  @linux_system ~w(libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1
                   ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 libgcc_s.so.1)

  # The oldest glibc the Linux release supports: Ubuntu 22.04's, where CI builds it.
  @glibc_floor {2, 35}

  # Files in a release that are test scaffolding, never loaded: crypto's test engine links
  # libcrypto on its own.
  @release_drop ["lib/crypto-*/priv/lib/otp_test_engine.so"]

  @doc """
  A release step, between Mix's `:assemble` and `package/1`: drop the VM programs geex never
  runs, strip the debug information from the ones it does (`beam.smp` carries ~43 MB of it), and
  check what the release needs: every module geex's code reaches (`unresolved/1`), every shared
  library its native code links (`native_problems/2`), and what its boot script loads
  (`boot_problems/2`).
  """
  @spec trim_release(Mix.Release.t()) :: Mix.Release.t()
  def trim_release(%Mix.Release{path: path} = release) do
    [bin] = Path.wildcard(Path.join(path, "erts-*/bin"))
    trim_erts(bin, System.find_executable("strip"))

    for pattern <- @release_drop,
        file <- Path.wildcard(Path.join(path, pattern)),
        do: File.rm!(file)

    case Map.drop(unresolved(path), Map.keys(@expected_unresolved)) do
      none when none == %{} ->
        :ok

      missing ->
        Mix.raise(
          "geex deploy: the release lacks modules geex's code calls: " <>
            Enum.map_join(missing, "; ", fn {m, from} ->
              "#{inspect(m)} (from #{inspect(from)})"
            end)
        )
    end

    check_native(path)

    [script] = Path.wildcard(Path.join(path, "releases/*/start.script"))

    case boot_problems(script, path) do
      [] -> release
      problems -> Mix.raise("geex deploy: the release won't boot: " <> Enum.join(problems, "; "))
    end
  end

  # A release build (GEEX_RELEASE=1) stops on a native problem; a local one, which carries
  # whatever OTP built it and runs only here, says what it links.
  defp check_native(path) do
    case native_problems(path, :os.type()) do
      [] ->
        :ok

      problems ->
        message = "the release's native code " <> Enum.join(problems, "; ")

        if System.get_env("GEEX_RELEASE") == "1",
          do: Mix.raise("geex deploy: " <> message),
          else: Mix.shell().info("geex deploy: (a local build, so only a note) " <> message)
    end
  end

  @doc """
  A release step, after `trim_release/1`: write the launcher to `bin/geex`, drop what Mix
  generated for its own scripts, and pack the release as
  `_build/package/geex-<version>-<os>-<arch>.tar.gz`, with a `SHA256SUMS` beside it.
  """
  @spec package(Mix.Release.t()) :: Mix.Release.t()
  def package(%Mix.Release{path: path, version: version} = release) do
    launcher =
      EEx.eval_file("rel/launcher.sh.eex",
        assigns: [version: version, erts: to_string(release.erts_version)]
      )

    File.write!(Path.join(path, "bin/geex"), launcher)
    File.chmod!(Path.join(path, "bin/geex"), 0o755)

    # Mix's own launch scripts (the launcher replaces them) and the distribution cookie (geex
    # never starts distribution, and a published cookie is everyone's).
    rel = Path.join(path, "releases/#{version}")

    for f <-
          [Path.join(path, "bin/geex.bat"), Path.join(path, "releases/COOKIE")] ++
            for(
              f <- ~w(elixir elixir.bat iex iex.bat env.sh env.bat remote.vm.args
                      start_clean.boot start_clean.script),
              do: Path.join(rel, f)
            ),
        do: File.rm_rf!(f)

    out = Path.expand(@package)
    File.rm_rf!(out)
    File.mkdir_p!(out)
    name = "geex-#{version}-#{target()}"
    File.cp_r!(path, Path.join(out, name))

    {_, 0} =
      System.cmd("tar", ["-C", out, "-czf", "#{name}.tar.gz", name],
        cd: out,
        env: [{"COPYFILE_DISABLE", "1"}],
        stderr_to_stdout: true
      )

    File.rm_rf!(Path.join(out, name))
    tarball = Path.join(out, "#{name}.tar.gz")
    sha = :crypto.hash(:sha256, File.read!(tarball)) |> Base.encode16(case: :lower)
    File.write!(Path.join(out, "SHA256SUMS"), "#{sha}  #{name}.tar.gz\n")
    Mix.shell().info("geex deploy: packed #{tarball}")
    release
  end

  @doc """
  What stops the release at `rel` booting in embedded mode by its boot script `script`, which
  loads every module up front (ADR-0036's 2026-10-18 amendment): a `{path, dirs}` naming a
  directory that isn't there, or a `{primLoad, modules}` module with no `.beam` on the path set
  before it. The boot emulated, without starting a VM. `[]` when it boots.
  """
  @spec boot_problems(Path.t(), Path.t()) :: [String.t()]
  def boot_problems(script, rel) do
    {:ok, [{:script, _name, instructions}]} = :file.consult(String.to_charlist(script))

    expand = fn dir ->
      dir
      |> to_string()
      |> String.replace("$RELEASE_LIB", Path.join(rel, "lib"))
      |> String.replace("$ROOT", rel)
    end

    {problems, _path} =
      Enum.reduce(instructions, {[], []}, fn
        {:path, dirs}, {problems, _path} ->
          dirs = Enum.map(dirs, expand)
          gone = for d <- dirs, not File.dir?(d), do: "no directory #{d}"
          {problems ++ gone, dirs}

        {:primLoad, modules}, {problems, path} ->
          lost =
            for m <- modules,
                not Enum.any?(path, &File.regular?(Path.join(&1, "#{m}.beam"))),
                do: "no #{m}.beam on the boot path"

          {problems ++ lost, path}

        _other, acc ->
          acc
      end)

    problems
  end

  @doc """
  What in the release at `rel` the release can't count on where it runs (ADR-0041 §1), on the
  OS `os_type` (`:os.type/0`):

    * on Linux, a shared library outside `@linux_system` that a VM program or a NIF links, or a
      glibc symbol newer than the floor (2.35);
    * on macOS, a library outside the OS (`/usr/lib`, `/System`), or a Mach-O whose code
      signature doesn't verify: Apple silicon kills an arm64 program whose signature a strip or
      a patch broke.

  `[]` when there's nothing.
  """
  @spec native_problems(Path.t(), {atom(), atom()}) :: [String.t()]
  def native_problems(rel, os_type) do
    for file <- native_files(rel), problem <- file_problems(file, os_type) do
      "#{Path.relative_to(file, rel)} #{problem}"
    end
  end

  @doc false
  # The VM's programs and every NIF's shared object.
  @spec native_files(Path.t()) :: [Path.t()]
  def native_files(rel) do
    Path.wildcard(Path.join(rel, "erts-*/bin/*")) ++
      Path.wildcard(Path.join(rel, "lib/*/priv/**/*.so"))
  end

  defp file_problems(file, {:unix, :darwin}) do
    {otool, 0} = System.cmd("otool", ["-L", file], stderr_to_stdout: true)
    {id, _} = System.cmd("otool", ["-D", file], stderr_to_stdout: true)

    foreign =
      for lib <- otool_libraries(otool) -- otool_libraries(id),
          not String.starts_with?(lib, ["/usr/lib/", "/System/Library/"]),
          do: "links #{lib}"

    case System.cmd("codesign", ["--verify", "--strict", file], stderr_to_stdout: true) do
      {_, 0} -> foreign
      {out, _} -> foreign ++ ["has no valid code signature: #{String.trim(out)}"]
    end
  end

  defp file_problems(file, _linux) do
    {dynamic, 0} = System.cmd("readelf", ["-d", file], stderr_to_stdout: true)
    {symbols, 0} = System.cmd("readelf", ["-W", "--dyn-syms", file], stderr_to_stdout: true)

    foreign = for lib <- elf_needed(dynamic), lib not in @linux_system, do: "links #{lib}"

    case glibc_needed(symbols) do
      newer when newer > @glibc_floor ->
        {major, minor} = newer
        floor = Tuple.to_list(@glibc_floor) |> Enum.join(".")
        foreign ++ ["needs glibc #{major}.#{minor}, newer than the #{floor} floor"]

      _ ->
        foreign
    end
  end

  @doc """
  The libraries in `readelf -d`'s output (its `NEEDED` entries).

      iex> Mix.Tasks.Geex.Deploy.elf_needed(\"""
      ...>  0x0000000000000001 (NEEDED)             Shared library: [libgcc_s.so.1]
      ...>  0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
      ...>  0x000000000000000e (SONAME)             Library soname: [x.so]
      ...> \""")
      ["libgcc_s.so.1", "libc.so.6"]
  """
  @spec elf_needed(String.t()) :: [String.t()]
  def elf_needed(readelf) do
    for [_, lib] <- Regex.scan(~r/\(NEEDED\)\s+Shared library: \[([^\]]+)\]/, readelf), do: lib
  end

  @doc """
  The newest glibc symbol version named in `readelf --dyn-syms`'s output, or `{0, 0}`.

      iex> Mix.Tasks.Geex.Deploy.glibc_needed(\"""
      ...>      1: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND memcpy@GLIBC_2.14 (2)
      ...>      2: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND pthread_create@GLIBC_2.34 (3)
      ...>      3: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND free@GLIBC_2.2.5 (4)
      ...> \""")
      {2, 34}
  """
  @spec glibc_needed(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def glibc_needed(readelf) do
    Regex.scan(~r/@GLIBC_(\d+)\.(\d+)/, readelf)
    |> Enum.map(fn [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)} end)
    |> Enum.max(fn -> {0, 0} end)
  end

  @doc """
  The libraries in `otool -L`'s (or `-D`'s) output: each indented line's path.

      iex> Mix.Tasks.Geex.Deploy.otool_libraries(\"""
      ...> erts/bin/beam.smp:
      ...> \t/usr/lib/libncurses.5.4.dylib (compatibility version 5.4.0, current version 5.4.0)
      ...> \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
      ...> \""")
      ["/usr/lib/libncurses.5.4.dylib", "/usr/lib/libSystem.B.dylib"]
  """
  @spec otool_libraries(String.t()) :: [String.t()]
  def otool_libraries(otool) do
    for line <- String.split(otool, "\n"),
        String.starts_with?(line, "\t"),
        do: line |> String.trim() |> String.replace(~r/ \(compatibility version.*\)$/, "")
  end

  @doc false
  @spec expected_unresolved() :: %{module() => String.t()}
  def expected_unresolved, do: @expected_unresolved

  @doc false
  # Remove everything in an `erts-*/bin` directory but `@erts_keep`, and strip what's kept with
  # `strip` (an executable's path), when there is one. On macOS a stripped program is signed
  # again (ad hoc): the strip breaks the signature the linker made, and Apple silicon kills an
  # arm64 program without a valid one.
  @spec trim_erts(Path.t(), Path.t() | nil) :: [String.t()]
  def trim_erts(bin, strip) do
    removed = for f <- File.ls!(bin), f not in @erts_keep, do: File.rm_rf!(Path.join(bin, f)) && f

    if strip do
      kept = for f <- @erts_keep, File.exists?(Path.join(bin, f)), do: Path.join(bin, f)
      # `-S` is the debug information only, in GNU's strip and Apple's alike.
      {_, 0} = System.cmd(strip, ["-S" | kept], stderr_to_stdout: true)

      if :os.type() == {:unix, :darwin} do
        {_, 0} = System.cmd("codesign", ["-s", "-", "-f" | kept], stderr_to_stdout: true)
      end
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
end
