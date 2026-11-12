defmodule Geex.Highlight.PaintWindowTest do
  # BUG-13: a frame paints, of each row, only the graphemes that can show (from the horizontal
  # scroll to the pane's right edge), and `Geex.Width.seek/3` finds where they start without
  # measuring the line from its start a grapheme at a time. Held to the full paint as it was
  # (`Geex.PaintReference`, the oracle) and to a plain grapheme walk.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.{Gen, PaintReference, Selection, Width}
  alias Geex.Highlight.{Paint, Span}

  defp theme, do: Geex.Fixtures.birds()

  @captures ~w(keyword string comment function number punctuation.bracket string.special.key)

  # Lines of every kind: short and long (past any pane), tabs, wide CJK, emoji, combining marks,
  # control characters, CRLF's `\r`.
  defp row do
    gen all(
          pieces <- list_of(Gen.piece(), max_length: 30),
          extra <- member_of(["", "", "\t\tx", "日本語", "👍🏽é", "\r", "a\u0007b"]),
          times <- frequency([{3, constant(1)}, {1, integer(2..12)}])
        ) do
      String.duplicate(Enum.join(pieces) <> extra, times)
    end
  end

  defp spans(text) do
    size = byte_size(text)

    list_of(
      gen all(
            a <- integer(0..max(size, 0)),
            len <- integer(0..40),
            capture <- member_of(@captures)
          ) do
        %Span{start_byte: a, end_byte: min(a + len, size), capture: capture}
      end,
      max_length: 12
    )
  end

  defp selection(lines) do
    one_of([
      constant(nil),
      gen all(
            l1 <- integer(0..(length(lines) - 1)),
            c1 <- integer(0..60),
            l2 <- integer(0..(length(lines) - 1)),
            c2 <- integer(0..60)
          ) do
        %Selection{anchor: {l1, c1}, active: {l2, c2}}
      end
    ])
  end

  property "the windowed paint draws every cell the full paint does" do
    check all(
            lines <- list_of(row(), min_length: 1, max_length: 6),
            text = Enum.join(lines, "\n"),
            spans <- spans(text),
            selection <- selection(lines),
            w <- integer(1..50),
            h <- integer(1..8),
            scroll <- integer(0..3),
            x0 <- integer(0..4),
            hscroll <- frequency([{2, constant(0)}, {3, integer(0..30)}, {1, integer(0..300)}]),
            tab <- member_of([1, 2, 4, 8])
          ) do
      args = [text, spans, theme(), w, h, scroll, x0, hscroll, selection, tab]
      assert apply(Paint, :to_screen, args) == apply(PaintReference, :to_screen, args)
    end
  end

  property "spans fetched for the painted ranges paint what all of them do" do
    check all(
            lines <- list_of(row(), min_length: 1, max_length: 6),
            text = Enum.join(lines, "\n"),
            # In start order, as the reactor's index answers (`Geex.Highlight.SpanIndex`): a
            # span seen first in a later window then starts after every span of an earlier one.
            spans <- map(spans(text), &Enum.sort_by(&1, fn s -> s.start_byte end)),
            w <- integer(1..50),
            hscroll <- integer(0..120),
            tab <- member_of([2, 4])
          ) do
      # A reactor answers a range with the spans that overlap it (`Reactor.render/3`).
      fetch = fn ranges ->
        Enum.flat_map(ranges, fn {from, to} ->
          Enum.filter(spans, &(&1.end_byte > from and &1.start_byte < to))
        end)
      end

      assert Paint.to_screen(text, fetch, theme(), w, 6, 0, 2, hscroll, nil, tab) ==
               Paint.to_screen(text, spans, theme(), w, 6, 0, 2, hscroll, nil, tab)
    end
  end

  test "a span over two windows, fetched for each, is counted once" do
    # Scrolled sideways, the rows' windows are bytes 5–8 and 16–19. The keyword covers both, the
    # string only the first; both are 12 bytes wide, so the later one wins the bytes they share
    # (6 and 7). Fetched per window the keyword comes twice, the second time after the string.
    text = "aaaaaaaaaa\nbbbbbbbbbb"
    keyword = %Span{start_byte: 6, end_byte: 18, capture: "keyword"}
    string = %Span{start_byte: 0, end_byte: 12, capture: "string"}
    all = [keyword, string]
    assert Paint.visible_ranges(text, 0, 2, 3, 5) == [{5, 8}, {16, 19}]

    fetch = fn ranges ->
      Enum.flat_map(ranges, fn {from, to} ->
        Enum.filter(all, &(&1.end_byte > from and &1.start_byte < to))
      end)
    end

    assert fetch.([{5, 8}, {16, 19}]) == [keyword, string, keyword]

    assert Paint.to_screen(text, fetch, theme(), 3, 2, 0, 0, 5, nil, 2) ==
             Paint.to_screen(text, all, theme(), 3, 2, 0, 0, 5, nil, 2)
  end

  # Where a place is, walking the line a grapheme at a time.
  defp walk(line, target, tab) do
    line
    |> String.graphemes()
    |> Enum.reduce_while({0, 0, 0}, fn g, {b, c, v} ->
      wd = Width.advance(g, v, tab)

      stop? =
        case target do
          {:col, t} -> c >= t
          {:vcol, t} -> v + wd > t
          :end -> false
        end

      if stop?, do: {:halt, {b, c, v}}, else: {:cont, {b + byte_size(g), c + 1, v + wd}}
    end)
  end

  property "Width.seek/3 finds what a grapheme walk finds" do
    check all(
            line <- row(),
            n <- integer(-1..400),
            kind <- member_of([:col, :vcol, :end]),
            tab <- member_of([1, 2, 4, 8])
          ) do
      target = if kind == :end, do: :end, else: {kind, if(kind == :col, do: max(n, 0), else: n)}
      assert Width.seek(line, target, tab) == walk(line, target, tab)
    end
  end

  test "a highlighted 2 MB line paints its scrolled columns in their colours, fast" do
    line = String.duplicate("def x(a, b) ", 175_000)
    # `def` at the start of each 12-byte unit is a keyword.
    spans =
      for i <- 0..174_999, do: %Span{start_byte: i * 12, end_byte: i * 12 + 3, capture: "keyword"}

    hscroll = 2_000_004

    {us, screen} =
      :timer.tc(fn -> Paint.to_screen(line, spans, theme(), 40, 1, 0, 0, hscroll, nil, 2) end)

    assert screen ==
             PaintReference.to_screen(
               binary_part(line, 2_000_004, 200),
               Enum.filter(spans, &(&1.start_byte >= 2_000_004))
               |> Enum.map(fn s ->
                 %{s | start_byte: s.start_byte - 2_000_004, end_byte: s.end_byte - 2_000_004}
               end),
               theme(),
               40,
               1
             )

    # The 2 MB line's spans are all handed over here (a reactor would hand over the window's);
    # the painting itself is the window's.
    assert div(us, 1000) < 500
  end

  test "a plain 2 MB line paints fast, scrolled to its end" do
    line = String.duplicate("ab, cd ", 300_000)

    ms =
      for(
        _ <- 1..3,
        do:
          elem(
            :timer.tc(fn ->
              Paint.to_screen(line, [], theme(), 100, 30, 0, 6, 2_099_950, nil, 2)
            end),
            0
          )
      )
      |> Enum.min()
      |> div(1000)

    assert ms < 100, "#{ms} ms"
  end
end
