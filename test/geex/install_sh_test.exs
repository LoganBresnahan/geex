defmodule Geex.InstallShTest do
  # install.sh (ADR-0041 §4), run by `sh` (dash on Debian and Ubuntu) on fake packages: each a
  # tarball whose `bin/geex` only answers `--version`, in a file:// download directory.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Geex.Deploy

  @script Path.expand("install.sh")

  setup do
    root = Path.join(System.tmp_dir!(), "geex_install_sh_#{Geex.Fixtures.uniq()}")
    dirs = for d <- ~w(home share bin dl), into: %{}, do: {d, Path.join(root, d)}
    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(root) end)
    # The scripts' paths, as install.sh resolves them (the temp dir may sit under a symlink).
    real = fn dir ->
      dir |> then(&System.cmd("pwd", ["-P"], cd: &1)) |> elem(0) |> String.trim()
    end

    %{dirs: dirs, versions: Path.join(real.(dirs["share"]), "versions"), bin: real.(dirs["bin"])}
  end

  # A package for VERSION in the download directory, its SHA256SUMS listing every one there.
  defp package(%{dirs: dirs}, version, marker \\ "") do
    name = "geex-#{version}-#{Deploy.target()}"
    stage = Path.join(dirs["dl"], name)
    File.mkdir_p!(Path.join(stage, "bin"))
    launcher = Path.join(stage, "bin/geex")
    File.write!(launcher, "#!/bin/sh\necho \"geex #{version}\"\n")
    File.chmod!(launcher, 0o755)
    File.write!(Path.join(stage, "marker"), marker)
    {_, 0} = System.cmd("tar", ["-czf", "#{name}.tar.gz", name], cd: dirs["dl"])
    File.rm_rf!(stage)
    write_sums(dirs["dl"])
  end

  defp write_sums(dl) do
    sums =
      for f <- Path.wildcard(Path.join(dl, "*.tar.gz")) do
        sha = :crypto.hash(:sha256, File.read!(f)) |> Base.encode16(case: :lower)
        "#{sha}  #{Path.basename(f)}\n"
      end

    File.write!(Path.join(dl, "SHA256SUMS"), sums)
  end

  defp install(%{dirs: dirs}, args) do
    System.cmd("sh", [@script | args],
      env: [
        {"HOME", dirs["home"]},
        {"GEEX_INSTALL_DIR", dirs["share"]},
        {"GEEX_BIN_DIR", dirs["bin"]},
        {"GEEX_DOWNLOAD_URL", "file://" <> dirs["dl"]}
      ],
      stderr_to_stdout: true
    )
  end

  defp linked(%{bin: bin}), do: File.read_link(Path.join(bin, "geex"))
  defp installed(%{versions: versions}), do: versions |> File.ls!() |> Enum.sort()

  test "installs a version, links it, and says so again without reinstalling", ctx do
    package(ctx, "1.0.0")
    assert {out, 0} = install(ctx, ["--version", "1.0.0"])
    assert out =~ "installed geex 1.0.0"
    assert linked(ctx) == {:ok, Path.join(ctx.versions, "1.0.0/bin/geex")}
    assert {"geex 1.0.0\n", 0} = System.cmd(Path.join(ctx.bin, "geex"), ["--version"])

    assert {out, 0} = install(ctx, ["--version", "v1.0.0"])
    assert out =~ "already installed"
  end

  test "keeps the current and the previous version, and prunes the rest", ctx do
    for v <- ~w(1.0.0 2.0.0 3.0.0), do: package(ctx, v)
    for v <- ~w(1.0.0 2.0.0), do: assert({_, 0} = install(ctx, ["--version", v]))
    assert installed(ctx) == ~w(1.0.0 2.0.0)

    assert {out, 0} = install(ctx, ["--version", "3.0.0"])
    assert out =~ "removed 1.0.0"
    assert installed(ctx) == ~w(2.0.0 3.0.0)
  end

  test "a version a running process uses is kept until it's free", ctx do
    for v <- ~w(1.0.0 2.0.0 3.0.0 4.0.0), do: package(ctx, v)
    for v <- ~w(1.0.0 2.0.0), do: assert({_, 0} = install(ctx, ["--version", v]))

    # A process naming 1.0.0's directory in its arguments, as the VM's -root does. (`; :` keeps
    # the shell from exec'ing sleep, which would drop the argument.)
    port =
      Port.open({:spawn_executable, "/bin/sh"},
        args: ["-c", "sleep 30; :", Path.join(ctx.versions, "1.0.0/erts/bin/beam.smp")]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      assert {out, 0} = install(ctx, ["--version", "3.0.0"])
      assert out =~ "kept 1.0.0"
      assert installed(ctx) == ~w(1.0.0 2.0.0 3.0.0)
    after
      Port.close(port)
      System.cmd("kill", ["#{pid}"])
    end

    assert {out, 0} = install(ctx, ["--version", "4.0.0"])
    assert out =~ "removed 1.0.0"
    assert installed(ctx) == ~w(3.0.0 4.0.0)
  end

  test "a download whose sha256 doesn't match unpacks nothing and switches nothing", ctx do
    package(ctx, "1.0.0")
    package(ctx, "2.0.0")
    assert {_, 0} = install(ctx, ["--version", "1.0.0"])

    File.write!(
      Path.join(ctx.dirs["dl"], "SHA256SUMS"),
      String.duplicate("0", 64) <> "  geex-2.0.0-#{Deploy.target()}.tar.gz\n"
    )

    assert {out, 1} = install(ctx, ["--version", "2.0.0"])
    assert out =~ "but SHA256SUMS says"
    assert installed(ctx) == ~w(1.0.0)
    assert linked(ctx) == {:ok, Path.join(ctx.versions, "1.0.0/bin/geex")}
  end

  test "a version with no line in SHA256SUMS fails closed", ctx do
    package(ctx, "1.0.0")
    File.write!(Path.join(ctx.dirs["dl"], "SHA256SUMS"), "")
    assert {out, 1} = install(ctx, ["--version", "1.0.0"])
    assert out =~ "no line for"
    assert installed(ctx) == []
  end

  test "--force installs the same version again", ctx do
    package(ctx, "1.0.0", "first")
    assert {_, 0} = install(ctx, ["--version", "1.0.0"])
    package(ctx, "1.0.0", "second")
    assert {_, 0} = install(ctx, ["--version", "1.0.0", "--force"])
    assert File.read!(Path.join(ctx.versions, "1.0.0/marker")) == "second"
    assert installed(ctx) == ~w(1.0.0)
  end

  test "--rollback switches back to the previous version, and back again", ctx do
    for v <- ~w(1.0.0 2.0.0), do: package(ctx, v) && install(ctx, ["--version", v])

    assert {out, 0} = install(ctx, ["--rollback"])
    assert out =~ "rolled back to geex 1.0.0"
    assert linked(ctx) == {:ok, Path.join(ctx.versions, "1.0.0/bin/geex")}

    assert {_, 0} = install(ctx, ["--rollback"])
    assert linked(ctx) == {:ok, Path.join(ctx.versions, "2.0.0/bin/geex")}
  end

  test "a geex link it didn't make is left alone", ctx do
    package(ctx, "1.0.0")
    File.ln_s!("/usr/bin/true", Path.join(ctx.bin, "geex"))
    assert {out, 1} = install(ctx, ["--version", "1.0.0"])
    assert out =~ "left alone"
    assert linked(ctx) == {:ok, "/usr/bin/true"}
  end

  test "--uninstall while a geex runs removes nothing", ctx do
    package(ctx, "1.0.0")
    assert {_, 0} = install(ctx, ["--version", "1.0.0"])

    port =
      Port.open({:spawn_executable, "/bin/sh"},
        args: ["-c", "sleep 30; :", Path.join(ctx.versions, "1.0.0/erts/bin/beam.smp")]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      assert {out, 1} = install(ctx, ["--uninstall"])
      assert out =~ "nothing was removed"
      assert linked(ctx) == {:ok, Path.join(ctx.versions, "1.0.0/bin/geex")}
      assert installed(ctx) == ~w(1.0.0)
    after
      Port.close(port)
      System.cmd("kill", ["#{pid}"])
    end
  end

  test "--uninstall removes the versions and the link, and nothing else", ctx do
    package(ctx, "1.0.0")
    assert {_, 0} = install(ctx, ["--version", "1.0.0"])
    themes = Path.join(ctx.dirs["share"], "themes")
    File.mkdir_p!(themes)

    assert {_, 0} = install(ctx, ["--uninstall"])
    refute File.exists?(Path.join(ctx.bin, "geex"))
    refute File.exists?(ctx.versions)
    assert File.dir?(themes)
  end
end
