defmodule Geex.DeployTest do
  # `mix geex.deploy`'s pruning (ADR-0036): an unpack a running geex uses is never removed.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Geex.Deploy

  doctest Deploy

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_deploy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "a process running from an unpack keeps it; a sibling with the same prefix is stale",
       %{dir: dir} do
    used = Path.join(dir, "geex_erts-1_0.1.0+aa")
    other = Path.join(dir, "geex_erts-1_0.1.0+aab")
    exe = Path.join([used, "bin", "sleep"])
    File.mkdir_p!(Path.dirname(exe))
    File.mkdir_p!(other)
    File.cp!(System.find_executable("sleep"), exe)
    File.chmod!(exe, 0o755)

    port = Port.open({:spawn_executable, exe}, [:binary, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      procs = Deploy.in_use()
      assert pid in Deploy.users(used, procs)
      assert Deploy.users(other, procs) == []
      assert Deploy.stale_unpacks([used, other], [], procs) == [other]
    after
      Port.close(port)
      System.cmd("kill", ["#{pid}"])
    end
  end
end
