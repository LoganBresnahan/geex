defmodule Geex.Input.PasteTest do
  # A bracketed paste gathered across reads (roadmap item 19, ADR-0026's 2026-11-09 amendment).
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.Input.Paste

  doctest Geex.Input.Paste

  # Feed `reads` one after another from a start: the paste events, and what followed the end.
  defp gather([first | reads]) do
    start =
      case Paste.start(first) do
        {:more, p, early} -> {p, early, nil}
        {:done, events, rest} -> {nil, events, rest}
      end

    Enum.reduce(reads, start, fn read, {p, acc, rest} ->
      case p do
        nil ->
          {nil, acc, rest <> read}

        p ->
          case Paste.feed(p, read) do
            {:more, p, events} -> {p, acc ++ events, nil}
            {:done, events, rest} -> {nil, acc ++ events, rest}
          end
      end
    end)
  end

  test "split anywhere, even through the end marker or a character, it comes out the same" do
    body = "if (x) {\r\n\t\e[31my(\"é\");\r\n}\u0000"
    stream = "\e[200~" <> body <> "\e[201~z"

    for k <- 7..(byte_size(stream) - 1) do
      <<a::binary-size(k), b::binary>> = stream
      assert {nil, [{:paste, ^body}], "z"} = gather([a, b]), "split at #{k}"
    end
  end

  property "however the reads fall, the paste is the bytes between the markers" do
    check all(
            # The bytes a marker is made of, and the shared generator's pieces (ADR-0044's
            # 2026-11-12 amendment): a multi-byte character or an invalid byte cut by a read.
            body <-
              map(
                list_of(
                  frequency([
                    {3, member_of(["a", "é", "\r\n", "\e", "[", "2", "0", "~", "\t"])},
                    {1, Geex.Gen.piece()}
                  ]),
                  max_length: 40
                ),
                &Enum.join/1
              ),
            cuts <- list_of(integer(1..8), max_length: 20)
          ) do
      stream = "\e[200~" <> body <> "\e[201~"

      {reads, rest} =
        Enum.reduce(cuts, {[], stream}, fn n, {acc, rest} ->
          n = min(n, byte_size(rest))
          <<read::binary-size(n), rest::binary>> = rest
          {[read | acc], rest}
        end)

      # The first read must hold the whole start marker (`Parser.paste?/1` hands it over then).
      [first | more] = Enum.reverse([rest | reads])
      {first, more} = merge_until(first, more, 6)
      {_p, events, _rest} = gather([first | more])
      # Bytes that aren't UTF-8 arrive replaced (BUG-11), a character cut by a read whole.
      assert Enum.map_join(events, fn {:paste, t} -> t end) == String.replace_invalid(body)
    end
  end

  defp merge_until(first, [next | more], n) when byte_size(first) < n,
    do: merge_until(first <> next, more, n)

  defp merge_until(first, more, _n), do: {first, more}

  test "past a megabyte with no end, it is handed on in pieces that split no character" do
    big = String.duplicate("é", 600_000) <> "\r\n" <> String.duplicate("x", 10)
    {:more, p, []} = Paste.start("\e[200~")
    {:more, p, [{:paste, first}]} = Paste.feed(p, big)
    assert String.valid?(first)
    {:done, [{:paste, second}], ""} = Paste.feed(p, "\e[201~")
    assert first <> second == big
  end

  test "a paste whose end never came is what came" do
    {:more, p, []} = Paste.start("\e[200~half")
    {:more, p, []} = Paste.feed(p, " a line")
    assert Paste.finish(p) == [{:paste, "half a line"}]
  end
end

defmodule Geex.TerminalIOUnicodeTest do
  # BUG-11 (found by the review of roadmap item 19): OTP's `:prim_tty` reader, meeting bytes that
  # aren't UTF-8, asks its parent to read them as Latin-1 and blocks for the answer. The answer,
  # driven without a terminal: what OTP's `user_drv` sends, then UTF-8 again.
  use ExUnit.Case, async: true

  test "the reader's handshake is answered, and UTF-8 comes back" do
    test = self()
    unicode = fn tty, on? -> send(test, {:unicode, on?}) && tty end
    assert Geex.TerminalIO.answer_unicode(:tty, test, unicode) == :tty

    assert_received {:unicode, false}
    assert_received {^test, :set_unicode_state, true}
    assert_received {:unicode, true}

    # In that order: told Latin-1, the reader let go, then UTF-8.
    {:messages, []} = Process.info(self(), :messages)
  end
end
