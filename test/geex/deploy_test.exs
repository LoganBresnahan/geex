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

  describe "trimming the release (ADR-0036's 2026-10-18 amendment)" do
    test "erts/bin keeps what the binary runs and loses the rest", %{dir: dir} do
      bin = Path.join(dir, "erts-1/bin")
      File.mkdir_p!(bin)

      for f <- ~w(beam.smp erlexec erl_child_setup inet_gethost epmd erlc dialyzer erl.src),
          do: File.write!(Path.join(bin, f), "")

      ExUnit.CaptureIO.capture_io(fn ->
        assert Deploy.trim_erts(bin, nil) == ~w(dialyzer epmd erl.src erlc)
      end)

      assert Enum.sort(File.ls!(bin)) == ~w(beam.smp erl_child_setup erlexec inet_gethost)
    end

    test "unresolved/1 follows geex's calls through the release and names what isn't there",
         %{dir: dir} do
      n = System.unique_integer([:positive])
      [a, b, c] = for x <- ~w(A B C), do: Module.concat(Geex.DeployFake, "#{x}#{n}")

      beam = fn app, mod, body ->
        # The calls to modules that don't exist warn, as they should.
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), Code.compile_string("defmodule #{inspect(mod)} do #{body} end"))
        end)

        assert_received [{^mod, code}]
        ebin = Path.join([dir, "lib", app, "ebin"])
        File.mkdir_p!(ebin)
        File.write!(Path.join(ebin, "#{mod}.beam"), code)
      end

      # geex calls a dependency and a module nobody ships; the dependency calls another such.
      # A module no geex code reaches may call what it likes.
      beam.("geex-0.1.0", a, "def f, do: {#{inspect(b)}.g(), :nowhere_#{n}.h()}")
      beam.("dep-1.0", b, "def g, do: :lost_#{n}.i()")
      beam.("dep-1.0", c, "def j, do: :unreached_#{n}.k()")

      assert Deploy.unresolved(dir) == %{
               :"nowhere_#{n}" => [a],
               :"lost_#{n}" => [b]
             }
    end

    test "boot_problems/2 emulates the boot: each path must exist, each preloaded module on it",
         %{dir: dir} do
      for d <- ["lib/a-1/ebin", "erts-1/lib"], do: File.mkdir_p!(Path.join(dir, d))
      File.write!(Path.join(dir, "lib/a-1/ebin/a.beam"), "")

      script = Path.join(dir, "start.script")

      write = fn instructions ->
        File.write!(script, :io_lib.format(~c"~p.~n", [{:script, {~c"x", ~c"1"}, instructions}]))
      end

      write.([
        {:path, [~c"$RELEASE_LIB/a-1/ebin"]},
        {:primLoad, [:a]},
        {:kernel_load_completed}
      ])

      assert Deploy.boot_problems(script, dir) == []

      write.([
        {:path, [~c"$RELEASE_LIB/a-1/ebin", ~c"$ROOT/lib/gone-2/ebin"]},
        {:primLoad, [:a, :b]}
      ])

      assert Deploy.boot_problems(script, dir) == [
               "no directory #{dir}/lib/gone-2/ebin",
               "no b.beam on the boot path"
             ]
    end

    test "the built release boots, by its boot script" do
      case Path.wildcard("_build/prod/rel/geex/releases/*/start.script") do
        [script] -> assert Deploy.boot_problems(script, "_build/prod/rel/geex") == []
        _ -> :ok
      end
    end

    # The safety net under the trim: on the release the last build assembled, geex's code reaches
    # nothing missing but the known few.
    test "the built release lacks nothing geex calls" do
      rel = "_build/prod/rel/geex"

      if File.dir?(Path.join(rel, "lib")) do
        missing = Map.keys(Deploy.unresolved(rel)) -- Map.keys(Deploy.expected_unresolved())
        assert missing == []
      end
    end
  end
end
