defmodule Geex.SupervisionTest do
  # Inspects the running application supervision tree — not parallel-safe.
  use ExUnit.Case, async: false

  alias Geex.CommandRegistry
  alias Geex.Commands.{Delete, Edit, Insert, Replace}

  test "CommandRegistry runs in the supervision tree, seeded with the built-ins" do
    assert is_pid(Process.whereis(CommandRegistry))

    names = CommandRegistry.all() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == [:delete, :edit, :insert, :replace]

    assert CommandRegistry.lookup(:insert) == {:ok, Insert}
    assert CommandRegistry.lookup(:delete) == {:ok, Delete}
    assert CommandRegistry.lookup(:replace) == {:ok, Replace}
    assert CommandRegistry.lookup(:edit) == {:ok, Edit}
  end

  test "Session and BufferSupervisor are up alongside it" do
    assert is_pid(Process.whereis(Geex.Session))
    assert is_pid(Process.whereis(Geex.BufferSupervisor))
  end
end
