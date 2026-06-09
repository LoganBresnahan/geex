defmodule Geex.Input.Parser do
  @moduledoc """
  Pure escape-sequence parser. Bytes in, key events out.

  Stateless except for the caller-held leftover buffer — the parser
  itself is a pure function. The caller appends new bytes to the
  leftover from the previous call and re-parses.

  Returns `{events, leftover}` where `events` is a list of key events
  in order and `leftover` is any unparsed bytes (a partial escape
  sequence) that should be prepended to the next chunk.

  v0.1 covers: regular ASCII chars, arrow keys, Enter, Backspace,
  Tab, ESC alone, Ctrl-letter (sort of). Mouse, F-keys, bracketed
  paste, kitty keyboard protocol come later.

  ## Event shapes

      {:key, :up | :down | :left | :right | :enter | :tab |
             :backspace | :esc}
      {:char, <<utf8 grapheme>>}
      {:ctrl, ?a..?z}            # Ctrl-letter as the lowercase atom
      {:alt, ?a..?z | ?A..?Z}   # Alt/Meta-letter (ESC-prefixed)
  """

  @type event ::
          {:key, atom()}
          | {:char, binary()}
          | {:ctrl, byte()}
          | {:alt, byte()}

  @doc """
  Parse a binary chunk into events plus any unparsed leftover bytes.

      iex> Geex.Input.Parser.parse("a")
      {[{:char, "a"}], ""}

      iex> Geex.Input.Parser.parse("\\e[A")
      {[{:key, :up}], ""}

      iex> Geex.Input.Parser.parse("\\e[")
      {[], "\\e["}

      iex> Geex.Input.Parser.parse("ab\\e[Cd")
      {[{:char, "a"}, {:char, "b"}, {:key, :right}, {:char, "d"}], ""}

      iex> Geex.Input.Parser.parse("\\em")
      {[{:alt, ?m}], ""}
  """
  @spec parse(binary()) :: {[event()], binary()}
  def parse(bytes) when is_binary(bytes), do: do_parse(bytes, [])

  defp do_parse(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # CSI sequences (ESC [ ...) — currently just the four arrows.
  defp do_parse(<<"\e[A", rest::binary>>, acc), do: do_parse(rest, [{:key, :up} | acc])
  defp do_parse(<<"\e[B", rest::binary>>, acc), do: do_parse(rest, [{:key, :down} | acc])
  defp do_parse(<<"\e[C", rest::binary>>, acc), do: do_parse(rest, [{:key, :right} | acc])
  defp do_parse(<<"\e[D", rest::binary>>, acc), do: do_parse(rest, [{:key, :left} | acc])

  # Partial CSI — keep it as leftover, await more bytes.
  defp do_parse(<<"\e[", _::binary>> = partial, acc) when byte_size(partial) < 3,
    do: {Enum.reverse(acc), partial}

  # ESC + a letter = Alt/Meta-letter. A terminal sends an Alt chord atomically, so it
  # arrives in one chunk (`\em`); a bare ESC stays leftover (clause below) until more bytes
  # come. `[` is not a letter, so CSI sequences match the clauses above, not this one.
  defp do_parse(<<"\e", c, rest::binary>>, acc) when c in ?a..?z or c in ?A..?Z,
    do: do_parse(rest, [{:alt, c} | acc])

  # ESC followed by another byte we don't recognise — emit ESC, reparse rest.
  # (Real impl would use a small timeout to decide; v0.1 leans on "if more
  # bytes are here, it was a sequence we don't know yet — drop ESC and
  # re-scan the rest").
  defp do_parse(<<"\e", rest::binary>>, acc) when byte_size(rest) >= 1,
    do: do_parse(rest, [{:key, :esc} | acc])

  # ESC alone — leftover, may complete on next chunk.
  defp do_parse(<<"\e">>, acc), do: {Enum.reverse(acc), <<"\e">>}

  # Common control characters.
  defp do_parse(<<"\r", rest::binary>>, acc), do: do_parse(rest, [{:key, :enter} | acc])
  defp do_parse(<<"\n", rest::binary>>, acc), do: do_parse(rest, [{:key, :enter} | acc])
  defp do_parse(<<"\t", rest::binary>>, acc), do: do_parse(rest, [{:key, :tab} | acc])
  defp do_parse(<<127, rest::binary>>, acc), do: do_parse(rest, [{:key, :backspace} | acc])
  defp do_parse(<<8, rest::binary>>, acc), do: do_parse(rest, [{:key, :backspace} | acc])

  # Ctrl-letter: bytes 1..26 map to Ctrl-a..Ctrl-z (skipping the ones above
  # that have their own meaning: 8 backspace, 9 tab, 10 nl, 13 cr, 27 esc).
  defp do_parse(<<b, rest::binary>>, acc) when b in 1..26 and b not in [8, 9, 10, 13],
    do: do_parse(rest, [{:ctrl, b + ?a - 1} | acc])

  # Printable ASCII / UTF-8: grab one grapheme cluster at a time.
  defp do_parse(bytes, acc) do
    case String.next_grapheme(bytes) do
      {grapheme, rest} -> do_parse(rest, [{:char, grapheme} | acc])
      nil -> {Enum.reverse(acc), bytes}
    end
  end
end
