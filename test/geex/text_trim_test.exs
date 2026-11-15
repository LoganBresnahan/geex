defmodule Geex.TextTrimTest do
  # `Geex.Text.trim_trailing_blanks/1`, a save's trim (ADR-0054 §4), cut by bytes since BUG-18:
  # it must take off exactly the space and tab graphemes the old grapheme walk took, at the cost
  # of the trailing run, not of the line.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.{Gen, Text}

  # The oracle: the trim as it was before BUG-18, the whole line split into graphemes, the
  # trailing space and tab graphemes dropped, a CRLF line's "\r" kept.
  defp walked(line) do
    {body, cr} =
      if String.ends_with?(line, "\r"),
        do: {binary_part(line, 0, byte_size(line) - 1), "\r"},
        else: {line, ""}

    kept =
      body
      |> Text.graphemes()
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 in [" ", "\t"]))
      |> Enum.reverse()
      |> Enum.join()

    kept <> cr
  end

  # What can come right before a trailing run: the generator's awkward text, and the characters
  # that sit on the run's edge: Prepend characters of 2, 3 and 4 bytes (one joins a space, never a
  # tab; the 4-byte one fills the whole tail `joined?` looks at, mod-verify's review), a run of
  # them, a 4-byte character, a combining mark, and bytes that aren't UTF-8 (a lone lead byte, a
  # cut character, a Prepend's bytes after a stray lead byte).
  @edges [
    "",
    "\u0600",
    "\u0D4E",
    "\u0600\u0600",
    "\u{110BD}",
    "a\u0301",
    "😀",
    "\u200D",
    "\f",
    "\u00A0",
    <<0xE0>>,
    <<0xF0, 0x9F, 0x98>>,
    <<0xF0, 0xD8, 0x80>>,
    <<0xE0, 0xB5>>
  ]

  defp trailing_line do
    gen all(
          front <- Gen.fragment(max_length: 6),
          edge <- member_of(@edges),
          run <- list_of(member_of([" ", "\t"]), max_length: 4),
          cr <- member_of(["", "\r"])
        ) do
      front <> edge <> Enum.join(run) <> cr
    end
  end

  property "takes off exactly the space and tab graphemes the grapheme walk takes" do
    check all(line <- one_of([trailing_line(), Gen.line(long: true)])) do
      assert Text.trim_trailing_blanks(line) == walked(line)
    end
  end

  test "a space a Prepend character joins stays; a tab after one goes" do
    assert Text.trim_trailing_blanks("x\u0600 \t ") == "x\u0600 "
    assert Text.trim_trailing_blanks("x\u0D4E \r") == "x\u0D4E \r"
    assert Text.trim_trailing_blanks("x\u0600\t ") == "x\u0600"
    assert Text.trim_trailing_blanks("\u0600\u0600 ") == "\u0600\u0600 "

    # A 4-byte Prepend (Kaithi number sign) fills the whole tail; a 3-byte tail would drop the space.
    assert Text.trim_trailing_blanks("x\u{110BD} \t") == "x\u{110BD} "
  end

  test "bytes that aren't UTF-8 before the run join nothing" do
    # A Prepend's bytes after a lead byte they don't continue: the lead byte is a grapheme alone,
    # the Prepend decodes and joins the space.
    assert Text.trim_trailing_blanks(<<0xF0, 0xD8, 0x80, "  ">>) == <<0xF0, 0xD8, 0x80, " ">>
    # A Prepend cut short: two stray bytes, each a grapheme alone.
    assert Text.trim_trailing_blanks(<<0xE0, 0xB5, "  ">>) == <<0xE0, 0xB5>>
    assert Text.trim_trailing_blanks(<<"x", 0xFF, " ">>) == <<"x", 0xFF>>
  end

  test "a line of only blanks becomes empty; a line not ending in one comes back as it is" do
    assert Text.trim_trailing_blanks(" \t \r") == "\r"
    assert Text.trim_trailing_blanks(" \t") == ""
    assert Text.trim_trailing_blanks("\r") == "\r"
    assert Text.trim_trailing_blanks("") == ""
    assert Text.trim_trailing_blanks("a\u00A0") == "a\u00A0"
    assert Text.trim_trailing_blanks("a \f") == "a \f"
  end

  # BUG-18: each trailing line was split into graphemes whole, 3,561 ms for a 10 MB save. A line's
  # trim now costs its trailing run: 10,000 lines of 1,000 bytes cost about what 10,000 short
  # lines with the same end do, whether the character before the space is ASCII or not (the old
  # walk: about a hundred times more). The fastest of three, in microseconds (mod-verify's review).
  test "a line's trim costs its trailing run, not its length" do
    us = fn fun -> Enum.min(for _ <- 1..3, do: elem(:timer.tc(fun), 0)) end
    trim_all = fn lines -> fn -> Enum.each(lines, &Text.trim_trailing_blanks/1) end end
    body = String.duplicate("x", 1_000)

    for edge <- [" ", "é "] do
      short = us.(trim_all.(List.duplicate("x" <> edge, 10_000)))
      long = us.(trim_all.(List.duplicate(body <> edge, 10_000)))
      assert long < 3 * short + 20_000, "#{inspect(edge)}: #{long} µs against #{short} µs"
    end

    assert Text.trim_trailing_blanks(body <> "é ") == body <> "é"
  end
end
