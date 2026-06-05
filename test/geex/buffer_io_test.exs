defmodule Geex.BufferIOTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer
  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.Insert

  # A unique tmp path per test (counter, not randomness — no Date/rand).
  defp tmp_path do
    name = "geex_buf_#{System.unique_integer([:positive])}.txt"
    path = Path.join(System.tmp_dir!(), name)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp insert(buf, line, col, text) do
    {:ok, cmd} = Insert.parse(%{line: line, col: col, text: text})
    {:ok, snap} = Buffer.dispatch(buf, Command.put_meta(cmd, Meta.human()))
    snap
  end

  describe "load on open" do
    test "loads an existing file's contents (LF round-trips)" do
      path = tmp_path()
      File.write!(path, "alpha\nbeta\n")
      buf = start_supervised!({Buffer, path: path})
      assert Buffer.get_text(buf) == "alpha\nbeta\n"
    end

    test "a missing path is a fresh empty buffer (created on first save)" do
      path = tmp_path()
      refute File.exists?(path)
      buf = start_supervised!({Buffer, path: path})
      assert Buffer.get_text(buf) == ""
      assert {:ok, ^path} = Buffer.save(buf)
      assert File.read!(path) == ""
    end

    test "explicit :text overrides loading" do
      path = tmp_path()
      File.write!(path, "on disk")
      buf = start_supervised!({Buffer, path: path, text: "in memory"})
      assert Buffer.get_text(buf) == "in memory"
    end

    test "an unreadable existing file fails the start cleanly (no raised File.Error)" do
      path = tmp_path()
      File.write!(path, "secret")
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o600) end)

      # root bypasses permission bits; only assert where the OS actually denies the read.
      # GenServer.start (not start_link) so the failed-init exit isn't linked to the test.
      case File.read(path) do
        {:error, :eacces} ->
          assert {:error, {:load_error, :eacces}} = GenServer.start(Buffer, path: path)

        {:ok, _} ->
          :ok
      end
    end
  end

  describe "save/1" do
    test "writes the current text back to the path and is byte-stable" do
      path = tmp_path()
      File.write!(path, "hello\nworld\n")
      buf = start_supervised!({Buffer, path: path})

      insert(buf, 0, 5, " there")
      assert {:ok, ^path} = Buffer.save(buf)
      assert File.read!(path) == "hello there\nworld\n"
    end

    test "clears dirty" do
      path = tmp_path()
      buf = start_supervised!({Buffer, path: path, text: ""})
      assert Buffer.snapshot(buf).dirty == false

      insert(buf, 0, 0, "x")
      assert Buffer.snapshot(buf).dirty == true

      assert {:ok, ^path} = Buffer.save(buf)
      assert Buffer.snapshot(buf).dirty == false
    end

    test "a buffer with no path cannot be saved" do
      buf = start_supervised!({Buffer, text: "scratch"})
      assert {:error, :no_path} = Buffer.save(buf)
    end

    test "save is not an edit — it does not touch the undo history" do
      path = tmp_path()
      buf = start_supervised!({Buffer, path: path, text: ""})
      insert(buf, 0, 0, "x")
      Buffer.save(buf)
      assert length(Buffer.history(buf)) == 1
    end
  end
end
