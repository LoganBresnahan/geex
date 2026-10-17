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
  keys (arrows, Home, End, Delete), and a mouse report becomes a mouse event; every other one
  (Page Up/Down, modified arrows, F-keys…) is **dropped**, never typed into
  the buffer as text. An incomplete sequence stays leftover until the rest
  arrives (bounded, so garbage can't be held forever).

  ## Mouse reports ([ADR-0039](../../../doc/adr/0039-mouse.md))

  `Geex.TerminalIO` asks for SGR reports (mode 1006): `ESC [ < b ; x ; y M` for a press, a drag
  or a wheel notch, `m` for a release. The numbers are decimal, so any column or row fits. A
  terminal that doesn't know 1006 sends the old form, `ESC [ M` and three bytes (each value plus
  32); it is read too, so its bytes never land in the buffer, up to the old form's limit of
  column and row 223.

  ## Event shapes

      {:key, :up | :down | :left | :right | :home | :end | :delete |
             :enter | :tab | :backspace | :esc}
      {:char, <<utf8 grapheme>>}
      {:ctrl, ?a..?z}            # Ctrl-letter as the lowercase atom
      {:ctrl, 0x40 | 0x5C..0x5F} # bytes 0, 28–31: Ctrl-@, Ctrl-\\, Ctrl-], Ctrl-^, Ctrl-_
      {:alt, ?a..?z | ?A..?Z}   # Alt/Meta-letter (ESC-prefixed)
      {:alt, ?0..?9 | ?- | ?= | ?, | ?.}   # the pane and tab keys
      {:mouse, %{action: :press | :release | :drag | :wheel | :move,
                 button: :left | :middle | :right | :up | :down | :wheel_left | :wheel_right
                         | :none | pos_integer(),
                 x: col, y: row,        # 0-based, from the terminal's top-left
                 mods: [:shift | :alt | :ctrl]}}
  """

  import Bitwise

  # The longest incomplete control sequence held as leftover.
  @max_sequence 32

  @type event ::
          {:key, atom()}
          | {:char, binary()}
          | {:ctrl, byte()}
          | {:alt, byte()}
          | {:mouse, mouse()}

  @type mouse :: %{
          action: :press | :release | :drag | :wheel | :move,
          button: atom() | pos_integer(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          mods: [:shift | :alt | :ctrl]
        }

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

  @doc """
  Give up waiting on a `leftover` that nothing followed. A terminal sends a whole control
  sequence in one write, so bytes still incomplete after a short pause were typed by a person:
  the ESC is the Esc key, and what follows it is ordinary input. The caller (`Geex.TerminalIO`)
  calls this when no bytes arrive for a few tens of milliseconds.

      iex> Geex.Input.Parser.flush("\\e")
      [{:key, :esc}]

      iex> Geex.Input.Parser.flush("\\e[")
      [{:key, :esc}, {:char, "["}]
  """
  @spec flush(binary()) :: [event()]

  def flush(<<>>), do: []
  def flush(<<"\e", rest::binary>>), do: [{:key, :esc} | flush(rest)]

  def flush(bytes) do
    case parse(bytes) do
      {events, <<>>} -> events
      {events, leftover} when byte_size(leftover) < byte_size(bytes) -> events ++ flush(leftover)
      # an incomplete UTF-8 tail: nothing to make of it
      {events, _stuck} -> events
    end
  end

  @doc """
  Whether a `leftover` is the start of a mouse report. Nobody types `ESC [ <` or `ESC [ M`, so it
  is a report whose rest is late (a slow link, a busy terminal), and the caller waits for the rest
  instead of flushing it: flushed, it would be typed into the buffer.

      iex> Geex.Input.Parser.mouse_report?("\\e[<0;12")
      true
      iex> Geex.Input.Parser.mouse_report?("\\e[M ")
      true
      iex> Geex.Input.Parser.mouse_report?("\\e[")
      false
  """
  @spec mouse_report?(binary()) :: boolean()
  def mouse_report?(<<"\e[<", _::binary>>), do: true
  def mouse_report?(<<"\e[M", _::binary>>), do: true
  def mouse_report?(_leftover), do: false

  defp do_parse(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # CSI: ESC [ params* intermediates* final, read whole. A known one becomes a key; an unknown
  # one is dropped. Incomplete → leftover (up to @max_sequence bytes, then dropped). A byte
  # outside the CSI ranges means it wasn't a sequence: drop the ESC [ and re-scan the rest.
  # The old mouse report, for a terminal without SGR mode 1006: `ESC [ M` and three raw bytes.
  # Before the CSI clause, which would read the `M` as a final byte and type the three bytes.
  defp do_parse(<<"\e[M", b, x, y, rest::binary>>, acc),
    do: do_parse(rest, push(legacy_mouse(b, x, y), acc))

  defp do_parse(<<"\e[M", rest::binary>> = seq, acc) when byte_size(rest) < 3,
    do: {Enum.reverse(acc), seq}

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

  # ESC + a digit, `-`, `=`, `,` or `.`: the pane and tab keys (ADR-0038). Not `[` or `\`:
  # `ESC [` starts a CSI and `ESC \` is ST, so those chords can't be told from a sequence.
  defp do_parse(<<"\e", c, rest::binary>>, acc) when c in ?0..?9 or c in [?-, ?=, ?,, ?.],
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

  # The other control bytes: 0 Ctrl-@ (Ctrl-Space), 28 Ctrl-\, 29 Ctrl-], 30 Ctrl-^, 31 Ctrl-_.
  # Keys, so they are never typed into the buffer as text.
  defp do_parse(<<b, rest::binary>>, acc) when b == 0 or b in 28..31,
    do: do_parse(rest, [{:ctrl, b + ?@} | acc])

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
  defp csi_key("<" <> params, final) when final in [?M, ?m], do: sgr_mouse(params, final)
  defp csi_key(_params, _final), do: nil

  # An SGR mouse report's `b;x;y` (1-based) with `M` (press, drag, wheel) or `m` (release).
  defp sgr_mouse(params, final) do
    with [b, x, y] <- String.split(params, ";"),
         {b, ""} <- Integer.parse(b),
         {x, ""} when x >= 1 <- Integer.parse(x),
         {y, ""} when y >= 1 <- Integer.parse(y) do
      mouse(b, x - 1, y - 1, final == ?m)
    else
      _ -> nil
    end
  end

  # The old report has no release form of its own: button 3 means "released".
  defp legacy_mouse(b, x, y) when b >= 32 and x > 32 and y > 32 do
    b = b - 32
    mouse(b, x - 33, y - 33, (b &&& 3) == 3 and (b &&& 224) == 0)
  end

  defp legacy_mouse(_b, _x, _y), do: nil

  # The button byte: the low two bits and bits 6–7 name the button, 4 is Shift, 8 Alt (Meta), 16
  # Ctrl, 32 says the mouse moved with it held (a drag), 64 is the wheel.
  defp mouse(b, x, y, release?) do
    mods = for {bit, mod} <- [{4, :shift}, {8, :alt}, {16, :ctrl}], (b &&& bit) != 0, do: mod
    low = b &&& 3

    {action, button} =
      cond do
        (b &&& 64) != 0 and (b &&& 128) == 0 ->
          {:wheel, Enum.at([:up, :down, :wheel_left, :wheel_right], low)}

        (b &&& 128) != 0 ->
          # Buttons 8 to 11 (back, forward and the like).
          {press_or(b, release?), 8 + low + if((b &&& 64) != 0, do: 4, else: 0)}

        release? ->
          {:release, if(low == 3, do: :none, else: Enum.at([:left, :middle, :right], low))}

        true ->
          # Low bits 3 with the motion bit: a move with no button held (mode 1003, not asked for).
          if low == 3 and (b &&& 32) != 0,
            do: {:move, :none},
            else: {press_or(b, false), Enum.at([:left, :middle, :right, :none], low)}
      end

    {:mouse, %{action: action, button: button, x: x, y: y, mods: mods}}
  end

  defp press_or(_b, true), do: :release
  defp press_or(b, false), do: if((b &&& 32) != 0, do: :drag, else: :press)

  defp ss3_key(?A), do: {:key, :up}
  defp ss3_key(?B), do: {:key, :down}
  defp ss3_key(?C), do: {:key, :right}
  defp ss3_key(?D), do: {:key, :left}
  defp ss3_key(?H), do: {:key, :home}
  defp ss3_key(?F), do: {:key, :end}
  defp ss3_key(_c), do: nil
end
