defmodule Geex.Gen do
  @moduledoc """
  The generators geex's property tests share ([ADR-0044](../../doc/adr/0044-property-tests-with-stream-data.md)
  §3), weighted toward the text that breaks editors: CRLF and a lone `\\r`, combining marks
  (precomposed and decomposed), zero-width characters, wide CJK, emoji with a skin tone, a ZWJ
  family, a flag, tabs, empty lines and a missing trailing newline. An awkward case is added
  here once and every property picks it up.

  Pieces join across their boundaries, as they do in files: `"\\r"` then `"\\n"` is one
  grapheme, and a lone combining mark joins the grapheme before it. So a property derives
  graphemes from the string it was given (`String.graphemes/1`), never from the pieces the
  generator built it from.

  Every generator shrinks toward plain ASCII and fewer lines, so a failure arrives as the
  smallest text that still breaks the law.
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
    "﻿"
  ]

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

  @doc "A piece of a line: mostly plain ASCII, sometimes one of the awkward cases. Never `\\n`."
  @spec piece() :: StreamData.t(String.t())
  def piece, do: frequency([{4, member_of(@plain)}, {1, member_of(@awkward)}])

  @doc "A run of pieces with no newline in it: a line, or part of one."
  @spec fragment(keyword()) :: StreamData.t(String.t())
  def fragment(opts \\ []) do
    piece() |> list_of(max_length: Keyword.get(opts, :max_length, 12)) |> map(&Enum.join/1)
  end

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

  @doc "A line: usually one of a small set that recurs, sometimes a fragment."
  @spec line() :: StreamData.t(String.t())
  def line, do: frequency([{3, member_of(@lines)}, {1, fragment()}])

  @doc """
  A text of up to `:max_lines` lines (default 8), joined by `\\n` (sometimes `\\r\\n` throughout),
  with or without a trailing newline. Lines ending in `\\r` make CRLF line ends in an LF text.
  """
  @spec text(keyword()) :: StreamData.t(String.t())
  def text(opts \\ []) do
    gen all(
          lines <- list_of(line(), max_length: Keyword.get(opts, :max_lines, 8)),
          newline <- frequency([{4, constant("\n")}, {1, constant("\r\n")}]),
          trailing <- boolean()
        ) do
      joined = Enum.join(lines, newline)
      if trailing and lines != [], do: joined <> newline, else: joined
    end
  end

  @doc "Text an edit inserts: a character, a newline, a few lines, or awkward text."
  @spec insertion() :: StreamData.t(String.t())
  def insertion do
    frequency([
      {3, member_of(["x", "\n", "yy\nz", ""])},
      {1, fragment(max_length: 4)},
      {1, text(max_lines: 3)}
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
