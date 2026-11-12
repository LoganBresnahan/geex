defmodule Geex.AsciiTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Geex.Ascii

  property "the compiled search finds what a byte scan finds" do
    check all(bin <- binary(max_length: 60), from <- integer(0..70), k <- integer(-2..70)) do
      bytes = :binary.bin_to_list(bin)
      high = bytes |> Enum.with_index() |> Enum.find(fn {b, i} -> b >= 128 and i >= from end)
      assert Geex.Ascii.first_high(bin, from) == (high && elem(high, 1))
      assert Geex.Ascii.prefix?(bin, k) == bytes |> Enum.take(max(k, 0)) |> Enum.all?(&(&1 < 128))

      controls = for {b, i} <- Enum.with_index(bytes), b < 32 or b == 127, do: i
      assert Geex.Ascii.controls(bin, 0, byte_size(bin)) == controls
    end
  end
end
