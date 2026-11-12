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
    ArgumentError ->
      [g | _] = chunked(text)
      {g, binary_part(text, byte_size(g), byte_size(text) - byte_size(g))}
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
    ArgumentError -> Kernel.length(chunked(text))
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
      gs = chunked(text)
      at = if at < 0, do: max(Kernel.length(gs) + at, 0), else: at
      {front, back} = Enum.split(gs, at)
      {Enum.join(front), Enum.join(back)}
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
    ArgumentError -> text |> chunked() |> Enum.slice(start, count) |> Enum.join()
  end

  @doc "The graphemes of `text` in `range`, as `String.slice/2`."
  @spec slice(binary(), Range.t()) :: binary()
  def slice(text, %Range{} = range) do
    String.slice(text, range)
  rescue
    ArgumentError -> text |> chunked() |> Enum.slice(range) |> Enum.join()
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
    ArgumentError -> text |> chunked() |> Enum.at(at)
  end

  @doc "The last grapheme of `text`, or `nil`."
  @spec last(binary()) :: binary() | nil
  def last(text) do
    String.last(text)
  rescue
    ArgumentError -> text |> chunked() |> List.last()
  end

  # The valid stretches segmented as `String` does; each byte that isn't UTF-8 a grapheme alone.
  defp chunked(<<>>), do: []

  defp chunked(text) do
    case :unicode.characters_to_binary(text) do
      valid when is_binary(valid) ->
        String.graphemes(valid)

      {kind, valid, <<byte, rest::binary>>} when kind in [:error, :incomplete] ->
        String.graphemes(valid) ++ [<<byte>> | chunked(rest)]
    end
  end
end
