defmodule Geex.Input.Parser do
  @moduledoc """
  Pure escape-sequence parser. Bytes in, key events out.

  Stateless except for the caller-held leftover buffer — the parser
  itself is a pure function. The caller appends new bytes to the
  leftover from the previous call and re-parses.

  Returns `{events, leftover}` where `events` is a list of key events
  in order and `leftover` is any unparsed bytes (a partial escape
  sequence) that should be prepended to the next chunk.

  Covers regular chars, Enter, Backspace, Tab, ESC alone, Ctrl-letter,
  Alt-letter, and the control sequences a terminal sends for special keys.
  A control sequence is read **as one unit**: a CSI (`ESC [`, parameter
  bytes `0x30–0x3F`, intermediate bytes `0x20–0x2F`, a final byte
  `0x40–0x7E`) or an SS3 (`ESC O` and one byte). The ones geex uses become
  keys (arrows, Home, End, Delete); every other one (Page Up/Down,
  modified arrows, F-keys, mouse reports…) is **dropped**, never typed into
  the buffer as text. An incomplete sequence stays leftover until the rest
  arrives (bounded, so garbage can't be held forever).

  ## Event shapes

      {:key, :up | :down | :left | :right | :home | :end | :delete |
             :enter | :tab | :backspace | :esc}
      {:char, <<utf8 grapheme>>}
      {:ctrl, ?a..?z}            # Ctrl-letter as the lowercase atom
      {:alt, ?a..?z | ?A..?Z}   # Alt/Meta-letter (ESC-prefixed)
  """

  # The longest incomplete control sequence held as leftover.
  @max_sequence 32

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

  # CSI: ESC [ params* intermediates* final, read whole. A known one becomes a key; an unknown
  # one is dropped. Incomplete → leftover (up to @max_sequence bytes, then dropped). A byte
  # outside the CSI ranges means it wasn't a sequence: drop the ESC [ and re-scan the rest.
  defp do_parse(<<"\e[", rest::binary>> = seq, acc) do
    case csi_end(rest, 0) do
      {:final, n} ->
        <<params::binary-size(n), final, after_seq::binary>> = rest
        do_parse(after_seq, push(csi_key(params, final), acc))

      :partial when byte_size(seq) <= @max_sequence ->
        {Enum.reverse(acc), seq}

      :partial ->
        {Enum.reverse(acc), <<>>}

      :invalid ->
        do_parse(rest, acc)
    end
  end

  # SS3: ESC O and one byte (application-mode arrows, Home/End, F1–F4). It arrives whole, so a
  # lone `ESC O` at the end of a chunk is Alt+Shift+O.
  defp do_parse(<<"\eO", c, rest::binary>>, acc), do: do_parse(rest, push(ss3_key(c), acc))

  # ESC + a letter = Alt/Meta-letter. A terminal sends an Alt chord atomically, so it
  # arrives in one chunk (`\em`); a bare ESC stays leftover (clause below) until more bytes
  # come. CSI (`[`) and SS3 (`O` + a byte) match the clauses above, not this one.
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

  defp push(nil, acc), do: acc
  defp push(event, acc), do: [event | acc]

  # Where a CSI's final byte is, after `ESC [`: {:final, params_length}, :partial, or :invalid.
  defp csi_end(<<b, _::binary>>, n) when b in 0x40..0x7E, do: {:final, n}
  defp csi_end(<<b, rest::binary>>, n) when b in 0x20..0x3F, do: csi_end(rest, n + 1)
  defp csi_end(<<>>, _n), do: :partial
  defp csi_end(_other, _n), do: :invalid

  # The CSI sequences geex maps. xterm sends Home/End as `ESC [ H` / `ESC [ F`; the VT220
  # style (tmux, the Linux console, rxvt) as `ESC [ 1 ~` / `7 ~` and `4 ~` / `8 ~`.
  defp csi_key("", ?A), do: {:key, :up}
  defp csi_key("", ?B), do: {:key, :down}
  defp csi_key("", ?C), do: {:key, :right}
  defp csi_key("", ?D), do: {:key, :left}
  defp csi_key("", ?H), do: {:key, :home}
  defp csi_key("", ?F), do: {:key, :end}
  defp csi_key(n, ?~) when n in ["1", "7"], do: {:key, :home}
  defp csi_key(n, ?~) when n in ["4", "8"], do: {:key, :end}
  defp csi_key("3", ?~), do: {:key, :delete}
  defp csi_key(_params, _final), do: nil

  defp ss3_key(?A), do: {:key, :up}
  defp ss3_key(?B), do: {:key, :down}
  defp ss3_key(?C), do: {:key, :right}
  defp ss3_key(?D), do: {:key, :left}
  defp ss3_key(?H), do: {:key, :home}
  defp ss3_key(?F), do: {:key, :end}
  defp ss3_key(_c), do: nil
end
