defmodule Geex.Command.TypeTest do
  use ExUnit.Case, async: true
  doctest Geex.Command.Type

  alias Geex.Command.Type

  test "string casts scalars" do
    assert Type.cast(:string, "hi") == {:ok, "hi"}
    assert Type.cast(:string, 42) == {:ok, "42"}
  end

  test "integer casts ints and numeric strings, rejects junk" do
    assert Type.cast(:integer, 7) == {:ok, 7}
    assert Type.cast(:integer, "7") == {:ok, 7}
    assert {:error, _} = Type.cast(:integer, "7x")
    assert {:error, _} = Type.cast(:integer, "nope")
  end

  test "boolean casts bools and the two strings" do
    assert Type.cast(:boolean, true) == {:ok, true}
    assert Type.cast(:boolean, "false") == {:ok, false}
    assert {:error, _} = Type.cast(:boolean, "yes")
  end

  test "unknown type is an error, not a crash" do
    assert {:error, _} = Type.cast(:coord_range, "a1-g3")
  end
end
