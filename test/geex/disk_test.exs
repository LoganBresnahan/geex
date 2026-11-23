defmodule Geex.DiskTest do
  # BUG-22: the user's files without OTP's file server. One test holds that server (a read left
  # waiting on a FIFO) for the whole VM, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Disk, Fifo}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_disk_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "as File does" do
    test "read and write", %{dir: dir} do
      path = Path.join(dir, "é ü.txt")
      assert Disk.write(path, ["a", ?b, "c"]) == :ok
      assert Disk.read(path) == {:ok, "abc"}
      assert Disk.write(path, "new") == :ok
      assert File.read(path) == {:ok, "new"}

      missing = Path.join(dir, "nope")
      assert Disk.read(missing) == {:error, :enoent}
      assert Disk.read(dir) == File.read(dir)
      deep = Path.join(dir, "no/such/f")
      assert Disk.write(deep, "x") == File.write(deep, "x")
      assert Disk.write(dir, "x") == File.write(dir, "x")
    end

    test "what is there", %{dir: dir} do
      file = Path.join(dir, "f")
      File.write!(file, "x")
      link = Path.join(dir, "link")
      File.ln_s!(file, link)
      missing = Path.join(dir, "nope")

      for path <- [file, dir, link, missing] do
        assert Disk.exists?(path) == File.exists?(path)
        assert Disk.regular?(path) == File.regular?(path)
        assert Disk.dir?(path) == File.dir?(path)
        assert Disk.stat(path) == File.stat(path)
        assert Disk.lstat(path) == File.lstat(path)
      end

      assert {:ok, %File.Stat{type: :symlink}} = Disk.lstat(link)
      assert {:ok, %File.Stat{type: :regular, size: 1}} = Disk.stat(link)
    end

    test "ls, rename, rm, rmdir, mkdir_p", %{dir: dir} do
      File.write!(Path.join(dir, "é ü.txt"), "")
      File.write!(Path.join(dir, "plain"), "")
      assert {:ok, names} = Disk.ls(dir)
      assert Enum.sort(names) == Enum.sort(File.ls!(dir))
      assert Disk.ls(Path.join(dir, "nope")) == File.ls(Path.join(dir, "nope"))
      assert Disk.ls(Path.join(dir, "plain")) == File.ls(Path.join(dir, "plain"))

      assert Disk.rename(Path.join(dir, "plain"), Path.join(dir, "moved")) == :ok
      assert File.exists?(Path.join(dir, "moved"))
      assert Disk.rename(Path.join(dir, "gone"), Path.join(dir, "x")) == {:error, :enoent}

      assert Disk.rm(Path.join(dir, "moved")) == :ok
      assert Disk.rm(Path.join(dir, "moved")) == File.rm(Path.join(dir, "moved"))

      deep = Path.join(dir, "a/b/c")
      assert Disk.mkdir_p(deep) == :ok
      assert File.dir?(deep)
      assert Disk.mkdir_p(deep) == :ok

      assert Disk.mkdir_p(Path.join(dir, "é ü.txt/x")) ==
               File.mkdir_p(Path.join(dir, "é ü.txt/x"))

      assert Disk.rmdir(Path.join(dir, "a")) == File.rmdir(Path.join(dir, "a"))
      assert Disk.rmdir(deep) == :ok
      refute File.exists?(deep)
    end

    test "read_link_all", %{dir: dir} do
      file = Path.join(dir, "f")
      File.write!(file, "")
      link = Path.join(dir, "link")
      File.ln_s!("f", link)

      assert Disk.read_link_all(link) == {:ok, ~c"f"}
      assert Disk.read_link_all(link) == :file.read_link_all(link)
      assert Disk.read_link_all(file) == {:error, :einval}
    end
  end

  describe "a FIFO, a device or a socket is never opened" do
    test "read and write answer at once, and the FIFO stays", %{dir: dir} do
      fifo = Fifo.make!(Path.join(dir, "fifo"))
      link = Path.join(dir, "link")
      File.ln_s!(fifo, link)

      assert Fifo.within(fifo, 1_000, fn -> Disk.read(fifo) end) == {:error, :not_regular}
      assert Fifo.within(fifo, 1_000, fn -> Disk.write(fifo, "x") end) == {:error, :not_regular}
      assert Fifo.within(fifo, 1_000, fn -> Disk.read(link) end) == {:error, :not_regular}
      assert Fifo.within(fifo, 1_000, fn -> Disk.write(link, "x") end) == {:error, :not_regular}
      assert {:ok, %File.Stat{type: :other}} = File.lstat(fifo)

      assert Disk.read("/dev/null") == {:error, :not_regular}
    end
  end

  # The bug itself: a read that never returns holds OTP's file server, and every other call
  # through it waits behind, on any file. Geex's calls on the user's files don't go through it.
  describe "with OTP's file server held" do
    test "every call answers, while File's own waits", %{dir: dir} do
      file = Path.join(dir, "f.txt")
      File.write!(file, "hi")
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)
      link = Path.join(dir, "link")
      File.ln_s!(file, link)
      written = Path.join(dir, "w")
      moved = Path.join(dir, "w2")
      deep = Path.join(dir, "a/b")
      other_fifo = Fifo.make!(Path.join(dir, "other"))
      fifo = Fifo.make!(Path.join(dir, "held"))

      {holder, ref} = spawn_monitor(fn -> File.read(fifo) end)
      on_exit(fn -> Fifo.release(fifo) end)
      Process.sleep(100)

      checks = [
        {"read", fn -> Disk.read(file) end, {:ok, "hi"}},
        {"write", fn -> Disk.write(written, "x") end, :ok},
        {"exists?", fn -> Disk.exists?(file) end, true},
        {"regular?", fn -> Disk.regular?(file) end, true},
        {"dir?", fn -> Disk.dir?(sub) end, true},
        {"stat", fn -> elem(Disk.stat(file), 0) end, :ok},
        {"lstat", fn -> Disk.lstat(link) |> elem(1) |> Map.get(:type) end, :symlink},
        {"ls", fn -> Disk.ls(sub) end, {:ok, []}},
        {"rename", fn -> Disk.rename(written, moved) end, :ok},
        {"rm", fn -> Disk.rm(moved) end, :ok},
        {"mkdir_p", fn -> Disk.mkdir_p(deep) end, :ok},
        {"rmdir", fn -> Disk.rmdir(deep) end, :ok},
        {"read_link_all", fn -> elem(Disk.read_link_all(link), 0) end, :ok},
        {"read of another FIFO", fn -> Disk.read(other_fifo) end, {:error, :not_regular}}
      ]

      {held?, answers} =
        try do
          # Held: File's own call waits (else this test proves nothing).
          held? = answer(fn -> File.exists?(file) end, 300) == :waited
          {held?, for({name, fun, _} <- checks, do: {name, answer(fun, 1_000)})}
        after
          Fifo.release(fifo)
          # Only a regression leaves a read on it: one dirty thread held for the rest of the run.
          Fifo.release(other_fifo)
        end

      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 2_000
      assert held?, "the file server wasn't held"

      for {{name, _, expected}, {_, got}} <- Enum.zip(checks, answers),
          do: assert({name, got} == {name, expected})
    end
  end

  # Without releasing anything: a call left waiting behind the held server is let go.
  defp answer(fun, ms) do
    task = Task.async(fun)

    case Task.yield(task, ms) do
      {:ok, got} ->
        got

      nil ->
        Task.shutdown(task, :brutal_kill)
        :waited
    end
  end

  # A mutant putting a `File` call back in one of these passed every other test.
  describe "the modules that touch the user's files" do
    @modules ~w(
      lib/geex/buffer.ex lib/geex/reconcile.ex lib/geex/session.ex lib/geex/loop.ex
      lib/geex/loop/file_ops.ex lib/geex/tree.ex lib/geex/tree/watcher.ex
      lib/geex/markdown/preview.ex lib/geex/search/project.ex lib/geex/loop/resolver.ex
    )

    test "make no call through the file server: Geex.Disk's instead" do
      found = for path <- @modules, call <- server_calls(path), do: "#{path}:#{call}"
      assert found == []
    end

    # `File.cwd/0`: the VM's own, never a file of the user's; `:file.format_error/1` and
    # `:file.native_name_encoding/0` make no call (the latter answers with the server held).
    defp server_calls(path) do
      ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

      {_, found} =
        Macro.prewalk(ast, [], fn
          {{:., meta, [{:__aliases__, _, [:File]}, fun]}, _, _} = node, acc
          when fun not in [:cwd, :cwd!] ->
            {node, ["#{meta[:line]} File.#{fun}" | acc]}

          {{:., meta, [{:__aliases__, _, [:Path]}, :wildcard]}, _, _} = node, acc ->
            {node, ["#{meta[:line]} Path.wildcard" | acc]}

          {{:., meta, [mod, fun]}, _, _} = node, acc
          when mod in [:file, :filelib] and fun not in [:format_error, :native_name_encoding] ->
            {node, ["#{meta[:line]} :#{mod}.#{fun}" | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(found)
    end
  end
end
