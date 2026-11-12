defmodule Geex.Ascii do
  @moduledoc """
  Finding, natively, where a binary stops being plain ASCII, and where its control characters
  are: what lets a long line be cut by its bytes (BUG-12, BUG-13, ADR-0035's 2026-11-12
  amendment). The byte patterns are compiled once (`:binary.compile_pattern/1`) and kept in
  `:persistent_term`; a pattern given as a plain list would be compiled again on every call,
  which costs more than the search on a short line.
  """

  @high for b <- 128..255, do: <<b>>
  @controls for b <- Enum.to_list(0..31) ++ [127], do: <<b>>

  @doc """
  The offset of the first byte of `bin` from `from` on that isn't ASCII (128 or above), or
  `nil`.

      iex> {Geex.Ascii.first_high("abé"), Geex.Ascii.first_high("abc"), Geex.Ascii.first_high("éa", 2)}
      {2, nil, nil}
  """
  @spec first_high(binary(), non_neg_integer()) :: non_neg_integer() | nil
  def first_high(bin, from \\ 0) when from >= 0 do
    from = min(from, byte_size(bin))

    case :binary.match(bin, pattern(:high), scope: {from, byte_size(bin) - from}) do
      {at, 1} -> at
      :nomatch -> nil
    end
  end

  @doc """
  Whether the first `k` bytes of `bin` (all of it, when shorter) are ASCII.

      iex> {Geex.Ascii.prefix?("abé", 2), Geex.Ascii.prefix?("abé", 3)}
      {true, false}
  """
  @spec prefix?(binary(), integer()) :: boolean()
  def prefix?(bin, k) do
    k = k |> max(0) |> min(byte_size(bin))
    k == 0 or :binary.match(bin, pattern(:high), scope: {0, k}) == :nomatch
  end

  @doc """
  The offsets of the control characters (below 32, and 127: a tab among them) in bytes
  `[from, from + len)` of `bin`.

      iex> Geex.Ascii.controls("a\\tb\\rc", 0, 5)
      [1, 3]
  """
  @spec controls(binary(), non_neg_integer(), non_neg_integer()) :: [non_neg_integer()]
  def controls(_bin, _from, 0), do: []

  def controls(bin, from, len),
    do: for({at, 1} <- :binary.matches(bin, pattern(:controls), scope: {from, len}), do: at)

  defp pattern(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        compiled = :binary.compile_pattern(if name == :high, do: @high, else: @controls)
        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end
end
