defmodule Geex.Gen do
  @moduledoc """
  The generators geex's property tests share ([ADR-0044](../../doc/adr/0044-property-tests-with-stream-data.md)
  §3 and its 2026-11-12 amendment): the default for any property over text, weighted toward the
  text that breaks editors. An awkward case is added here once and every property picks it up:

    * line ends: CRLF, a lone `\\r`, empty lines, a missing trailing newline;
    * combining marks (precomposed and decomposed, and a mark alone), zero-width characters, a
      variation selector (VS16) on its own;
    * wide CJK, emoji with a skin tone, a ZWJ family, a flag, a keycap (`1️⃣`);
    * Prepend characters (U+0600, U+0D4E), which join the grapheme after them;
    * whitespace that isn't a space or a tab: a no-break space, a form feed, a vertical tab, an
      ideographic space (U+3000), so a rule about "blank" or "whitespace" says which it means;
    * tabs;
    * **invalid UTF-8**: a lone continuation byte, a Latin-1 `é` (`0xE9`), a truncated multibyte
      lead (`0xE2 0x82`), `0xC0`, `0xFF`. A file can hold them (BUG-15); each is one grapheme
      (`Geex.Text`). A property whose law or oracle doesn't hold for them passes `invalid: false`
      and says why;
    * **long lines**: past the 4 KB window threshold (ADR-0035's 2026-11-12 amendment), ASCII and
      not, so a window's edge falls inside words, gaps and brackets. Rare, and only in a deep run
      (`GEEX_PROPERTY_RUNS` of 1,000 or more) unless a property asks with `long: true`, so the
      default `mix test` stays quick. `long_line/1` is the generator itself.

  Pieces join across their boundaries, as they do in files: `"\\r"` then `"\\n"` is one
  grapheme, and a lone combining mark joins the grapheme before it. So a property derives
  graphemes from the string it was given (`Geex.Text.graphemes/1`, or `String.graphemes/1` with
  `invalid: false`), never from the pieces the generator built it from.

  Every generator shrinks toward plain ASCII and fewer lines, so a failure arrives as the
  smallest text that still breaks the law.

  Options, taken by every text generator and passed down: `invalid:` (default `true`), `long:`
  (default: whether this is a deep run).
  """

  import StreamData
  import ExUnitProperties, only: [gen: 2]

  @plain ~w(a b c x y)

  @awkward [
    " ",
    "\t",
    # precomposed, then decomposed (e + combining acute), then the mark alone
    "é",
    "é",
    "́",
    "λ",
    "ü",
    # wide: two display cells each
    "中",
    "文",
    "😀",
    # thumbs up + skin tone; a ZWJ family; a flag (two regional indicators)
    "\u{1F44D}\u{1F3FD}",
    "\u{1F468}‍\u{1F469}‍\u{1F467}",
    "\u{1F1EF}\u{1F1F5}",
    "\r",
    # zero width space; zero width no-break space (a BOM away from the start)
    "​",
    "﻿",
    # a keycap; VS16 alone (it joins what comes before it)
    "1\u{FE0F}\u{20E3}",
    "\u{FE0F}",
    # Prepend: Arabic number sign, Malayalam dot reph; each joins the grapheme after it
    "\u{0600}",
    "\u{0D4E}",
    # whitespace that isn't a space or a tab: no-break space, form feed, vertical tab,
    # ideographic space
    "\u{00A0}",
    "\f",
    "\v",
    "\u{3000}"
  ]

  # Bytes that aren't UTF-8 (BUG-15): a lone continuation byte, a Latin-1 é, a truncated
  # three-byte lead, an overlong lead, 0xFF.
  @invalid [<<0x80>>, <<0xE9>>, <<0xE2, 0x82>>, <<0xC0>>, <<0xFF>>]

  # Lines that recur, so two generated texts share lines and a diff or merge has something to
  # align. Simplest first: a shrink walks toward the head of the list.
  @lines [
    "a",
    "",
    "b",
    "c",
    "end",
    "  indented",
    "\tindented",
    "x\r",
    "é",
    "中文",
    "é",
    "\u{1F468}‍\u{1F469}‍\u{1F467}"
  ]

  @doc """
  A piece of a line: mostly plain ASCII, sometimes one of the awkward cases, now and then an
  invalid byte (unless `invalid: false`). Never `\\n`.
  """
  @spec piece(keyword()) :: StreamData.t(binary())
  def piece(opts \\ []) do
    if Keyword.get(opts, :invalid, true),
      do: frequency([{40, member_of(@plain)}, {10, member_of(@awkward)}, {1, invalid_byte()}]),
      else: frequency([{4, member_of(@plain)}, {1, member_of(@awkward)}])
  end

  @doc "One of the bytes that aren't UTF-8 (BUG-15), for a property about them."
  @spec invalid_byte() :: StreamData.t(binary())
  def invalid_byte, do: member_of(@invalid)

  @doc "A run of pieces with no newline in it: a line, or part of one."
  @spec fragment(keyword()) :: StreamData.t(binary())
  def fragment(opts \\ []) do
    opts
    |> piece()
    |> list_of(max_length: Keyword.get(opts, :max_length, 12))
    |> map(&Enum.join/1)
  end

  @doc """
  A line past 4 KB (the window threshold, ADR-0035's 2026-11-12 amendment): a short run of pieces
  (ASCII only, or with the awkward ones, invalid bytes as `:invalid` says) repeated past 4,096
  bytes, between a head and a tail of their own, so window edges fall in different places. Its
  own `\\r` at the end now and then, as a CRLF line.
  """
  @spec long_line(keyword()) :: StreamData.t(binary())
  def long_line(opts \\ []) do
    gen all(
          ascii? <- boolean(),
          unit <- list_of(long_piece(ascii?, opts), min_length: 1, max_length: 12),
          head <- list_of(long_piece(ascii?, opts), max_length: 30),
          tail <- list_of(long_piece(ascii?, opts), max_length: 30),
          crlf? <- frequency([{4, constant(false)}, {1, constant(true)}])
        ) do
      unit = Enum.join(unit)
      times = div(4_500, max(byte_size(unit), 1)) + 1

      Enum.join(head) <>
        String.duplicate(unit, times) <> Enum.join(tail) <> if(crlf?, do: "\r", else: "")
    end
  end

  # A long line's pieces: words, gaps and brackets, so the motions and the bracket search have
  # something to find at a window's edge; with the awkward pieces unless ASCII only.
  # Now and then a word or a gap longer than a window (1,024 graphemes), so a read runs into the
  # window's side and falls back to the whole line.
  defp long_piece(true, _opts),
    do:
      frequency([
        {8, member_of(~w(a bc xyz q))},
        {5, member_of([" ", "  ", "\t"])},
        {2, member_of(~w|( ) [ ] { } ,|)},
        {1, constant(String.duplicate("w", 1500))},
        {1, constant(String.duplicate(" ", 1500))}
      ])

  defp long_piece(false, opts),
    do: frequency([{4, long_piece(true, opts)}, {2, piece(Keyword.put(opts, :long, false))}])

  # Whether long lines come by default: in a deep run only (`GEEX_PROPERTY_RUNS`, config/runtime.exs).
  defp long?(opts),
    do:
      Keyword.get_lazy(opts, :long, fn ->
        Application.get_env(:stream_data, :max_runs, 100) >= 1000
      end)

  # What code is mostly made of where the typing assists act (roadmap item 19, the review's ask:
  # brackets, quotes, colons and the punctuation a pair closes before), with letters, a digit,
  # `_`, spaces, a tab, a backslash and now and then a combining mark.
  @code_pieces ~w|( ) [ ] { } ' " ` : ; . , = > a b x _ 1 \\| ++ [" ", " ", "\t", "\u0301"]

  @doc """
  A fragment of code-like text, up to `:max_length` (default 12) graphemes' worth of pieces
  weighted toward brackets, quotes and punctuation, so properties over the typing assists
  (ADR-0045) reach their triggers.
  """
  @spec code_fragment(keyword()) :: StreamData.t(String.t())
  def code_fragment(opts \\ []) do
    @code_pieces
    |> member_of()
    |> list_of(max_length: Keyword.get(opts, :max_length, 12))
    |> map(&Enum.join/1)
  end

  @doc "One piece of `code_fragment/1`: a key to type."
  @spec code_piece() :: StreamData.t(String.t())
  def code_piece, do: member_of(@code_pieces -- ["\u0301"])

  @doc """
  A line: usually one of a small set that recurs, sometimes a fragment, rarely (in a deep run, or
  with `long: true`) a long line.
  """
  @spec line(keyword()) :: StreamData.t(binary())
  def line(opts \\ []) do
    base = [{30, member_of(@lines)}, {10, fragment(opts)}]
    if long?(opts), do: frequency(base ++ [{1, long_line(opts)}]), else: frequency(base)
  end

  @doc """
  A text of up to `:max_lines` lines (default 8), joined by `\\n` (sometimes `\\r\\n` throughout),
  with or without a trailing newline. Lines ending in `\\r` make CRLF line ends in an LF text.
  """
  @spec text(keyword()) :: StreamData.t(binary())
  def text(opts \\ []) do
    gen all(
          lines <- list_of(line(opts), max_length: Keyword.get(opts, :max_lines, 8)),
          newline <- frequency([{4, constant("\n")}, {1, constant("\r\n")}]),
          trailing <- boolean()
        ) do
      joined = Enum.join(lines, newline)
      if trailing and lines != [], do: joined <> newline, else: joined
    end
  end

  @doc "Text an edit inserts: a character, a newline, a few lines, or awkward text."
  @spec insertion(keyword()) :: StreamData.t(binary())
  def insertion(opts \\ []) do
    frequency([
      {3, member_of(["x", "\n", "yy\nz", ""])},
      {1, fragment(Keyword.put(opts, :max_length, 4))},
      {1, text(Keyword.put(Keyword.put(opts, :max_lines, 3), :long, false))}
    ])
  end

  @doc "Who wrote a command (`Geex.Command.Meta.actor()`): a person, the disk, or an agent."
  @spec actor() :: StreamData.t(Geex.Command.Meta.actor())
  def actor do
    member_of([
      :human,
      :external,
      {:agent, %{harness: "claude-code", session: "s1"}},
      {:agent, %{harness: "claude-code", session: "s2"}},
      {:llm, "model"}
    ])
  end
end
