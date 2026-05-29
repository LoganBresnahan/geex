defmodule Geex.CommandRegistryTest do
  # async: false — each test starts its own registry instance, but they share the
  # module namespace; keep them serial to avoid any name reuse surprises.
  use ExUnit.Case, async: false

  alias Geex.CommandRegistry
  alias Geex.Commands.{Delete, Insert}

  setup context do
    name = :"reg_#{context.test}"
    {:ok, _pid} = start_supervised({CommandRegistry, name: name, commands: [Insert]})
    %{reg: name}
  end

  test "seeds commands and looks them up by name", %{reg: reg} do
    assert CommandRegistry.lookup(reg, :insert) == {:ok, Insert}
  end

  test "unknown name returns :error", %{reg: reg} do
    assert CommandRegistry.lookup(reg, :nope) == :error
  end

  test "register/2 adds a command at runtime (the dynamic set)", %{reg: reg} do
    assert CommandRegistry.lookup(reg, :delete) == :error
    assert :ok = CommandRegistry.register(reg, Delete)
    assert CommandRegistry.lookup(reg, :delete) == {:ok, Delete}
  end

  test "all/1 lists registered command info", %{reg: reg} do
    CommandRegistry.register(reg, Delete)
    names = CommandRegistry.all(reg) |> Enum.map(& &1.name) |> Enum.sort()
    assert names == [:delete, :insert]
  end
end
