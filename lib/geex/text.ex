defmodule Geex.Text do
  @moduledoc """
  `String`'s grapheme functions, total over text that isn't valid UTF-8 (BUG-15).

  A file can hold bytes that aren't UTF-8: a Latin-1 file, an image opened by mistake. Elixir
  already reads each such byte as a grapheme of its own (`String.graphemes("caf\\xE9")` is
  `["c", "a", "f", <<233>>]`), but OTP's segmentation raises `ArgumentError` when an extended
  pictographic (an emoji) comes right before one (`String.graphemes("👍" <> <<0xFF>>)`). Each
  function here returns exactly what `String`'s does, and only where `String`'s would raise
  segments the valid stretches as `String` does and gives each invalid byte its own grapheme,
  the rule Elixir follows everywhere else. So commands still address graphemes (ADR-0027), and
  a line of valid text is addressed exactly as before.
  """

  @doc """
  The graphemes of `text`.

      iex> Geex.Text.graphemes("👍" <> <<0xFF>> <> "a")
      ["👍", <<0xFF>>, "a"]
  """
  @spec graphemes(binary()) :: [binary()]
  def graphemes(text) do
    String.graphemes(text)
  rescue
    ArgumentError -> chunked(text)
  end

  @doc """
  The first grapheme of `text` and the rest, or `nil` when it is empty.

      iex> Geex.Text.next_grapheme("👍" <> <<0xFF>>)
      {"👍", <<0xFF>>}
  """
  @spec next_grapheme(binary()) :: {binary(), binary()} | nil
  def next_grapheme(text) do
    String.next_grapheme(text)
  rescue
    # Only the first grapheme is looked at: the valid run before the first invalid byte (or that
    # byte alone), so a step costs the grapheme, not the rest of the text (mod-verify's review).
    ArgumentError ->
      case :unicode.characters_to_binary(text) do
        {_, "", <<byte, rest::binary>>} ->
          {<<byte>>, rest}

        {_, valid, _rest} ->
          {g, _} = String.next_grapheme(valid)
          {g, binary_part(text, byte_size(g), byte_size(text) - byte_size(g))}
      end
  end

  @doc """
  The number of graphemes in `text`.

      iex> Geex.Text.length("👍" <> <<0xFF, 0xFE>>)
      3
  """
  @spec length(binary()) :: non_neg_integer()
  def length(text) do
    String.length(text)
  rescue
    ArgumentError -> chunked_length(text, 0)
  end

  @doc """
  `text` split before grapheme `at` (counted from the end when negative).

      iex> Geex.Text.split_at("👍" <> <<0xFF>> <> "a", 2)
      {"👍" <> <<0xFF>>, "a"}
  """
  @spec split_at(binary(), integer()) :: {binary(), binary()}
  def split_at(text, at) do
    String.split_at(text, at)
  rescue
    ArgumentError ->
      if at >= 0 do
        walk_split(text, at)
      else
        gs = chunked(text)
        {front, back} = Enum.split(gs, max(Kernel.length(gs) + at, 0))
        {Enum.join(front), Enum.join(back)}
      end
  end

  @doc """
  The graphemes of `text` from `start`, `count` of them, as `String.slice/3`.

      iex> Geex.Text.slice("👍" <> <<0xFF>> <> "ab", 1, 2)
      <<0xFF>> <> "a"
  """
  @spec slice(binary(), integer(), non_neg_integer()) :: binary()
  def slice(text, start, count) do
    String.slice(text, start, count)
  rescue
    ArgumentError ->
      if start >= 0 do
        {_, rest} = walk_split(text, start)
        elem(walk_split(rest, count), 0)
      else
        text |> chunked() |> Enum.slice(start, count) |> Enum.join()
      end
  end

  @doc "The graphemes of `text` in `range`, as `String.slice/2`."
  @spec slice(binary(), Range.t()) :: binary()
  def slice(text, %Range{} = range) do
    String.slice(text, range)
  rescue
    ArgumentError ->
      case range do
        first..last//1 when first >= 0 and last >= first -> slice(text, first, last - first + 1)
        _ -> text |> chunked() |> Enum.slice(range) |> Enum.join()
      end
  end

  @doc """
  The grapheme at `at` (counted from the end when negative), or `nil`.

      iex> Geex.Text.at("👍" <> <<0xFF>>, 1)
      <<0xFF>>
  """
  @spec at(binary(), integer()) :: binary() | nil
  def at(text, at) do
    String.at(text, at)
  rescue
    ArgumentError ->
      if at >= 0 do
        {_, rest} = walk_split(text, at)

        case next_grapheme(rest) do
          {g, _} -> g
          nil -> nil
        end
      else
        text |> chunked() |> Enum.at(at)
      end
  end

  # `text` split before grapheme `n`, walked a grapheme at a time: what it costs is the front.
  defp walk_split(text, n), do: walk_split(text, n, 0)

  defp walk_split(text, 0, off),
    do: {binary_part(text, 0, off), binary_part(text, off, byte_size(text) - off)}

  defp walk_split(text, n, off) do
    case next_grapheme(binary_part(text, off, byte_size(text) - off)) do
      nil -> {text, ""}
      {g, _rest} -> walk_split(text, n - 1, off + byte_size(g))
    end
  end

  @doc "The last grapheme of `text`, or `nil`."
  @spec last(binary()) :: binary() | nil
  def last(text) do
    String.last(text)
  rescue
    ArgumentError -> text |> chunked() |> List.last()
  end

  # The valid stretches segmented as `String` does; each byte that isn't UTF-8 a grapheme alone.
  # The valid stretches segmented by String, each invalid byte alone. Tail-recursive, building the
  # list once: a body-recursive version (one stack level and one list append per invalid byte)
  # took 3.8 s on a 256 KB Latin-1 line, and every key on such a line paid it (BUG-17).
  defp chunked(text), do: text |> chunked([]) |> Enum.reverse()

  defp chunked(<<>>, acc), do: acc

  defp chunked(text, acc) do
    case :unicode.characters_to_binary(text) do
      valid when is_binary(valid) ->
        Enum.reverse(String.graphemes(valid), acc)

      {kind, valid, <<byte, rest::binary>>} when kind in [:error, :incomplete] ->
        chunked(rest, [<<byte>> | Enum.reverse(String.graphemes(valid), acc)])
    end
  end

  # How many graphemes `chunked/1` would give, without building them.
  defp chunked_length(<<>>, n), do: n

  defp chunked_length(text, n) do
    case :unicode.characters_to_binary(text) do
      valid when is_binary(valid) ->
        n + String.length(valid)

      {kind, valid, <<_byte, rest::binary>>} when kind in [:error, :incomplete] ->
        chunked_length(rest, n + String.length(valid) + 1)
    end
  end
end
