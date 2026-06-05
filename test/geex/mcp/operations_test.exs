defmodule Geex.MCP.OperationsTest do
  # call/2 drives the app-global Session/BufferSupervisor — not parallel-safe.
  use ExUnit.Case, async: false

  alias Geex.Buffer
  alias Geex.MCP.Operations
  alias Geex.Session

  defp tmp_path do
    name = "geex_ops_#{System.unique_integer([:positive])}.txt"
    path = Path.join(System.tmp_dir!(), name)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp open(path) do
    {:ok, op} = Operations.lookup("open_file")
    result = Operations.call(op, %{"path" => path})

    case Geex.BufferSupervisor.whereis(Path.expand(path)) do
      {:ok, pid} ->
        on_exit(fn ->
          if Process.alive?(pid),
            do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
        end)

      :error ->
        :ok
    end

    result
  end

  setup do
    on_exit(fn -> Session.set_active_buffer(nil) end)
    :ok
  end

  describe "tools/0 — the operation-tool descriptors" do
    test "exposes the buffer + disk-file lifecycle tools with field-spec-projected schemas" do
      names = Enum.map(Operations.tools(), & &1["name"]) |> Enum.sort()

      assert names == [
               "close_file",
               "create_file",
               "delete_file",
               "open_file",
               "rename_file",
               "save_file"
             ]

      open = Enum.find(Operations.tools(), &(&1["name"] == "open_file"))
      assert open["inputSchema"]["type"] == "object"
      assert open["inputSchema"]["required"] == ["path"]
      assert open["inputSchema"]["properties"]["path"]["type"] == "string"
      assert open["inputSchema"]["additionalProperties"] == false

      save = Enum.find(Operations.tools(), &(&1["name"] == "save_file"))
      assert save["inputSchema"]["required"] == []

      # create_file: required path + optional content (default not surfaced in schema).
      create = Enum.find(Operations.tools(), &(&1["name"] == "create_file"))
      assert create["inputSchema"]["required"] == ["path"]
      assert create["inputSchema"]["properties"]["content"]["type"] == "string"

      # rename_file: two required string args.
      rename = Enum.find(Operations.tools(), &(&1["name"] == "rename_file"))
      assert Enum.sort(rename["inputSchema"]["required"]) == ["from", "to"]

      # close_file: path is optional (defaults to the active buffer).
      close = Enum.find(Operations.tools(), &(&1["name"] == "close_file"))
      assert close["inputSchema"]["required"] == []
      assert close["inputSchema"]["properties"]["path"]["type"] == "string"
    end
  end

  describe "lookup/1" do
    test "finds the operation tools by name" do
      assert {:ok, %{name: "open_file"}} = Operations.lookup("open_file")
      assert {:ok, %{name: "save_file"}} = Operations.lookup("save_file")
    end

    test "an unknown name is :error (so the protocol falls through to the edit registry)" do
      assert Operations.lookup("insert") == :error
      assert Operations.lookup("frobnicate") == :error
    end

    test "operation names are disjoint from edit-command names (the routing invariant)" do
      op_names = Operations.tools() |> Enum.map(& &1["name"]) |> MapSet.new()
      cmd_names = Geex.CommandRegistry.all() |> Enum.map(&to_string(&1.name)) |> MapSet.new()

      assert MapSet.disjoint?(op_names, cmd_names),
             "operation/edit-command name collision would shadow routing and duplicate tools/list"
    end
  end

  describe "call/2 — argument validation (shared with edit tools)" do
    test "a missing required arg is {:invalid_args, _}, not a crash" do
      {:ok, op} = Operations.lookup("open_file")
      assert {:invalid_args, why} = Operations.call(op, %{})
      assert why =~ "path"
    end
  end

  describe "call/2 — open_file" do
    test "opens a file, makes it active, and returns its text" do
      path = tmp_path()
      File.write!(path, "alpha\nbeta\n")

      assert {:ok, "alpha\nbeta\n"} = open(path)
      assert {:ok, pid} = Session.active_buffer()
      assert Buffer.get_text(pid) == "alpha\nbeta\n"
    end

    test "a missing file opens as a fresh empty buffer" do
      path = tmp_path()
      assert {:ok, ""} = open(path)
    end
  end

  describe "call/2 — save_file" do
    test "writes the active buffer back to disk and confirms the path" do
      path = tmp_path()
      File.write!(path, "")
      open(path)

      # edit through the real path so dirty is set
      {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "hi"})
      {:ok, _} = Geex.Dispatch.run(Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))

      {:ok, op} = Operations.lookup("save_file")
      assert {:ok, text} = Operations.call(op, %{})
      assert text =~ "saved "
      assert File.read!(path) == "hi"
    end

    test "no active buffer is a clean {:error, _}" do
      Session.set_active_buffer(nil)
      {:ok, op} = Operations.lookup("save_file")
      assert {:error, ":no_active_buffer"} = Operations.call(op, %{})
    end

    test "an active buffer with no path is a clean {:error, _}" do
      scratch = start_supervised!({Buffer, text: "scratch"})
      Session.set_active_buffer(scratch)
      {:ok, op} = Operations.lookup("save_file")
      assert {:error, ":no_path"} = Operations.call(op, %{})
    end
  end

  describe "call/2 — create_file" do
    test "creates a file with content and confirms the path" do
      path = tmp_path()
      {:ok, op} = Operations.lookup("create_file")
      assert {:ok, msg} = Operations.call(op, %{"path" => path, "content" => "hi\n"})
      assert msg =~ "created "
      assert File.read!(path) == "hi\n"
    end

    test "an existing file is a clean {:error, _} with an actionable message" do
      path = tmp_path()
      File.write!(path, "x")
      {:ok, op} = Operations.lookup("create_file")
      assert {:error, why} = Operations.call(op, %{"path" => path})
      assert why =~ "already exists"
    end
  end

  describe "call/2 — delete_file" do
    test "deletes a file and confirms" do
      path = tmp_path()
      File.write!(path, "x")
      {:ok, op} = Operations.lookup("delete_file")
      assert {:ok, msg} = Operations.call(op, %{"path" => path})
      assert msg =~ "deleted "
      refute File.exists?(path)
    end

    test "deleting an open buffer with unsaved edits reports the discard, never silent" do
      path = tmp_path()
      File.write!(path, "x")
      open(path)
      {:ok, cmd} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "Z"})
      {:ok, _} = Geex.Dispatch.run(Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))

      {:ok, op} = Operations.lookup("delete_file")
      assert {:ok, msg} = Operations.call(op, %{"path" => path})
      assert msg =~ "discarded unsaved edits"
    end

    test "a missing file is a clean {:error, _}" do
      path = tmp_path()
      {:ok, op} = Operations.lookup("delete_file")
      assert {:error, why} = Operations.call(op, %{"path" => path})
      assert why =~ "enoent"
    end
  end

  describe "call/2 — rename_file" do
    test "renames a file and confirms from -> to" do
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "x")
      {:ok, op} = Operations.lookup("rename_file")
      assert {:ok, msg} = Operations.call(op, %{"from" => from, "to" => to})
      assert msg =~ "renamed "
      assert msg =~ " -> "
      assert File.read!(to) == "x"
    end

    test "an existing destination is a clean {:error, _}" do
      from = tmp_path()
      to = tmp_path()
      File.write!(from, "a")
      File.write!(to, "b")
      {:ok, op} = Operations.lookup("rename_file")
      assert {:error, why} = Operations.call(op, %{"from" => from, "to" => to})
      assert why =~ "destination already exists"
    end

    test "a missing 'to' arg is {:invalid_args, _}, not a crash" do
      {:ok, op} = Operations.lookup("rename_file")
      assert {:invalid_args, why} = Operations.call(op, %{"from" => "a"})
      assert why =~ "to"
    end
  end

  describe "call/2 — close_file" do
    test "closes the active buffer (no path arg)" do
      path = tmp_path()
      File.write!(path, "")
      open(path)
      {:ok, op} = Operations.lookup("close_file")
      assert {:ok, msg} = Operations.call(op, %{})
      assert msg =~ "closed "
    end

    test "an explicit null path closes the active buffer (collapses to nil)" do
      path = tmp_path()
      File.write!(path, "")
      open(path)
      {:ok, op} = Operations.lookup("close_file")
      assert {:ok, msg} = Operations.call(op, %{"path" => nil})
      assert msg =~ "closed "
    end

    test "no active buffer is a clean {:error, _}" do
      Session.set_active_buffer(nil)
      {:ok, op} = Operations.lookup("close_file")
      assert {:error, why} = Operations.call(op, %{})
      assert why =~ "no active buffer"
    end
  end
end
