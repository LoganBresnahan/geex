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
    test "exposes open_file and save_file with field-spec-projected schemas" do
      names = Enum.map(Operations.tools(), & &1["name"]) |> Enum.sort()
      assert names == ["open_file", "save_file"]

      open = Enum.find(Operations.tools(), &(&1["name"] == "open_file"))
      assert open["inputSchema"]["type"] == "object"
      assert open["inputSchema"]["required"] == ["path"]
      assert open["inputSchema"]["properties"]["path"]["type"] == "string"
      assert open["inputSchema"]["additionalProperties"] == false

      save = Enum.find(Operations.tools(), &(&1["name"] == "save_file"))
      assert save["inputSchema"]["required"] == []
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
end
