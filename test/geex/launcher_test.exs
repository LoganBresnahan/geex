defmodule Geex.LauncherTest do
  # The launcher (rel/launcher.sh.eex, ADR-0041 §2 and §4), rendered as `package/1` renders it,
  # in an install.sh layout whose VM (`erlexec`) and installer are stubs that print what they got.
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "geex_launcher_#{Geex.Fixtures.uniq()}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    root = root |> then(&System.cmd("pwd", ["-P"], cd: &1)) |> elem(0) |> String.trim()

    share = Path.join(root, "share")
    release = Path.join(share, "versions/1.0.0")
    bin = Path.join(root, "bin")
    tmp = Path.join(root, "tmp")
    Enum.each([bin, tmp], &File.mkdir_p!/1)
    lay_out(release)
    File.ln_s!(Path.join(release, "bin/geex"), Path.join(bin, "geex"))

    %{root: root, share: share, release: release, bin: bin, tmp: tmp}
  end

  defp lay_out(release) do
    launcher =
      EEx.eval_file("rel/launcher.sh.eex", assigns: [version: "1.0.0", erts: "16.0"])

    script(Path.join(release, "bin/geex"), launcher)
    script(Path.join(release, "erts-16.0/bin/erlexec"), "#!/bin/sh\necho \"vm $*\"\n")

    # What the bundled installer got: its arguments, the two directories, and its command line.
    File.write!(Path.join(release, "install.sh"), """
    echo "install.sh $* dir=$GEEX_INSTALL_DIR bin=${GEEX_BIN_DIR:-}"
    echo "cmdline=$(ps -o args= -p $$)"
    """)
  end

  defp script(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    File.chmod!(path, 0o755)
  end

  defp geex(ctx, path, args, env \\ []) do
    System.cmd(path, args,
      env: [{"GEEX_BIN_DIR", nil}, {"GEEX_DOWNLOAD_URL", nil}, {"TMPDIR", ctx.tmp} | env],
      stderr_to_stdout: true
    )
  end

  test "self rollback, prune and uninstall run the bundled install.sh on this install", ctx do
    for cmd <- ~w(rollback prune uninstall) do
      assert {out, 0} = geex(ctx, Path.join(ctx.bin, "geex"), ["self", cmd])
      assert out =~ "install.sh --#{cmd} dir=#{ctx.share} bin=#{ctx.bin}\n"
      # Read from stdin: no command line names versions/, or uninstall would refuse itself.
      [cmdline] = Regex.run(~r/cmdline=.*/, out)
      refute cmdline =~ "versions/"
    end
  end

  test "a GEEX_BIN_DIR of the user's own wins over the link's directory", ctx do
    assert {out, 0} =
             geex(ctx, Path.join(ctx.bin, "geex"), ["self", "prune"], [{"GEEX_BIN_DIR", "/elsewhere"}])

    assert out =~ "bin=/elsewhere\n"
  end

  test "self update runs the downloaded install.sh, then removes it", ctx do
    dl = Path.join(ctx.root, "dl")
    File.mkdir_p!(dl)
    File.write!(Path.join(dl, "install.sh"), ~s|echo "new installer $*"\n|)
    env = [{"GEEX_DOWNLOAD_URL", "file://" <> dl}]

    assert {out, 0} = geex(ctx, Path.join(ctx.bin, "geex"), ~w(self update --version v1.2.3), env)
    assert out == "new installer --version 1.2.3\n"
    assert {out, 0} = geex(ctx, Path.join(ctx.bin, "geex"), ~w(self update), env)
    assert out == "new installer \n"
    assert File.ls!(ctx.tmp) == []

    File.rm!(Path.join(dl, "install.sh"))
    assert {out, 1} = geex(ctx, Path.join(ctx.bin, "geex"), ~w(self update), env)
    assert out =~ "geex self: couldn't download"
  end

  test "anything else goes to the VM", ctx do
    for args <- [~w(self frob), ~w(self prune extra), ~w(a.txt), ~w(-- self)] do
      assert {out, 0} = geex(ctx, Path.join(ctx.bin, "geex"), args)
      assert out =~ ~r/^vm .*-extra #{Enum.join(args, " ")}\n$/
    end
  end

  test "a release install.sh didn't install leaves self to the VM", ctx do
    elsewhere = Path.join(ctx.root, "rel/geex")
    lay_out(elsewhere)
    assert {out, 0} = geex(ctx, Path.join(elsewhere, "bin/geex"), ~w(self prune))
    assert out =~ ~r/^vm .*-extra self prune\n$/
  end
end
