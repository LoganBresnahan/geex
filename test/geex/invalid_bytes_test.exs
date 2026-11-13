defmodule Geex.InvalidBytesTest do
  # BUG-15: a file can hold bytes that aren't UTF-8 (a Latin-1 file, a binary opened by mistake).
  # Drawing, measuring and editing such text never raises: each invalid byte is a grapheme of its
  # own, addressed as one, drawn as `�` in one column. Valid text (emoji, ZWJ, flags, CJK,
  # combining marks) is untouched: `Geex.Text` returns exactly what `String` does wherever
  # `String` doesn't raise, and the windowed paint's property (PaintWindowTest) still holds it to
  # the reference paint.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.{Gen, Loop, Text, Width}
  alias Geex.Buffer.Doc
  alias Geex.Highlight.Paint

  doctest Geex.Text

  # Bytes that are never UTF-8 on their own: continuation bytes, lead bytes cut short, 0xC0/0xC1,
  # 0xF5..0xFF.
  defp bad_byte,
    do:
      map(
        member_of(Enum.to_list(0x80..0xBF) ++ [0xC0, 0xC1, 0xC3, 0xE2, 0xF0, 0xFF, 0xFE]),
        &<<&1>>
      )

  # Valid pieces of every kind, with an emoji often right before an invalid byte (where OTP's
  # segmentation raises).
  defp piece,
    do:
      frequency([
        {4, Gen.piece()},
        {2, bad_byte()},
        {1, member_of(["👍", "👍🏽", "👨‍👩‍👧", "🇫🇷", "1️⃣", "日本", "é", "\t", "\r"])}
      ])

  defp line, do: map(list_of(piece(), max_length: 20), &Enum.join/1)

  defp graphemes_of(line), do: Text.graphemes(line)

  property "drawing and measuring text with invalid bytes never raises, and draws no bad byte" do
    check all(
            lines <- list_of(line(), min_length: 1, max_length: 5),
            text = Enum.join(lines, "\n"),
            w <- integer(1..40),
            hscroll <- integer(0..20),
            tab <- member_of([1, 2, 4, 8])
          ) do
      screen = Paint.to_screen(text, [], Geex.Fixtures.birds(), w, 6, 0, 0, hscroll, nil, tab)

      for y <- 0..(screen.h - 1), x <- 0..(screen.w - 1) do
        assert String.valid?(Geex.Screen.get_cell(screen, x, y).char)
      end

      assert is_integer(Loop.max_line_width(text, tab))

      for {line, row} <- Enum.with_index(lines) do
        n = length(graphemes_of(line))
        assert Text.length(line) == n
        assert Enum.join(graphemes_of(line)) == line

        for col <- 0..(n + 1) do
          assert {x, ^row} = Loop.cursor_xy(text, {row, col}, 0, tab)
          assert x >= 0
        end

        width = Width.line(line, tab)

        for dx <- 1..(width + 2),
            do: assert(Width.col_at_display(line, dx, tab) in 1..(n + 1))
      end
    end
  end

  property "editing text with invalid bytes never raises and addresses each byte as one" do
    check all(
            line <- line(),
            n = length(graphemes_of(line)),
            col <- integer(0..n),
            ins <- member_of(["x", "é", "👍", "\t"])
          ) do
      doc = Doc.new(line <> "\nnext")
      {:ok, inserted} = Doc.insert(doc, {0, col}, ins)
      {front, back} = Text.split_at(line, col)
      assert Doc.text(inserted) == front <> ins <> back <> "\nnext"
      new_line = front <> ins <> back

      # Deleting it back is its graphemes, unless it joined a neighbour (`x` before a lone
      # combining mark makes one grapheme `x́`: valid text's rule, not an invalid byte's).
      if length(graphemes_of(new_line)) == n + length(graphemes_of(ins)) do
        {:ok, back_doc} = Doc.delete(inserted, {0, col}, length(graphemes_of(ins)))
        assert Doc.text(back_doc) == line <> "\nnext"
      end
    end
  end

  property "Geex.Text is String wherever String doesn't raise" do
    check all(bin <- map(list_of(piece(), max_length: 12), &Enum.join/1)) do
      case (try do
              {:ok, String.graphemes(bin)}
            rescue
              ArgumentError -> :raised
            end) do
        {:ok, gs} ->
          assert Text.graphemes(bin) == gs
          assert Text.length(bin) == String.length(bin)
          assert Text.split_at(bin, 2) == String.split_at(bin, 2)
          assert Text.slice(bin, 1, 3) == String.slice(bin, 1, 3)

        :raised ->
          assert Enum.join(Text.graphemes(bin)) == bin
      end
    end
  end

  describe "the cases" do
    defp row0(text, w \\ 20) do
      screen = Paint.to_screen(text, [], Geex.Fixtures.birds(), w, 1, 0, 0, 0, nil, 4)

      Enum.map_join(0..(w - 1), &Geex.Screen.get_cell(screen, &1, 0).char)
      |> String.trim_trailing()
    end

    test "a Latin-1 line draws its byte as one �; the cursor counts it as one column" do
      text = "caf" <> <<0xE9>> <> "!"
      assert row0(text) == "caf�!"
      assert Loop.cursor_xy(text, {0, 3}, 0) == {3, 0}
      assert Loop.cursor_xy(text, {0, 4}, 0) == {4, 0}
      assert Text.length(text) == 5
    end

    test "an emoji right before invalid bytes: each byte is its own �" do
      text = "👍" <> <<0xFF, 0xFE>> <> "a"
      assert Text.graphemes(text) == ["👍", <<0xFF>>, <<0xFE>>, "a"]
      assert row0(text) == "👍" <> "" <> "��a"
      assert Loop.cursor_xy(text, {0, 1}, 0) == {2, 0}
      assert Loop.cursor_xy(text, {0, 3}, 0) == {4, 0}
      assert Width.line(text, 4) == 5
    end

    test "a line starting with an invalid byte" do
      text = <<0xFF>> <> "abc"
      assert row0(text) == "�abc"
      assert Loop.cursor_xy(text, {0, 0}, 0) == {0, 0}
      assert Loop.cursor_xy(text, {0, 1}, 0) == {1, 0}
      assert Width.col_at_display(text, 1, 4) == 1
      assert Width.col_at_display(text, 2, 4) == 2
    end

    test "Alt+\\ over invalid bytes: forward, backward, and through a long line's tail" do
      line = "(™" <> <<0xE9>> <> " bracket)"
      assert Geex.Loop.Keymap.matching_bracket({0, 0}, line) == {0, 11}
      assert Geex.Loop.Keymap.matching_bracket({0, 11}, line) == {0, 0}
      # A line over the backward search's budget above the cursor is read by its tail.
      long = String.duplicate("é", 900_000) <> "(☀" <> <<0xFF>> <> "\n)"
      assert Geex.Loop.Keymap.matching_bracket({1, 0}, long) == {0, 900_000}
    end

    test "valid emoji are untouched: ZWJ, flags, keycaps, skin tones, CJK, combining marks" do
      for text <- ["👨‍👩‍👧 x", "🇫🇷🇯🇵", "1️⃣2️⃣", "👍🏽👍🏿", "日本語", "éa"] do
        assert Text.graphemes(text) == String.graphemes(text)
        assert Width.line(text, 4) == Width.string(text)
      end

      assert row0("日本") == "日" <> "" <> "本"
    end
  end

  describe "what a fallback costs (mod-verify's review)" do
    # The fastest of three; bounds generous for CI's slower runner. Before, each fallback
    # re-segmented the rest of the text: 0.4–0.5 s here, 58 s for the line of pairs.
    defp ms(fun), do: for(_ <- 1..3, do: elem(:timer.tc(fun), 0)) |> Enum.min() |> div(1000)

    setup do
      fr = String.duplicate("café crème brûlée ", 120_000)
      long = binary_part(fr, 0, 40) <> "©" <> <<0xE9>> <> binary_part(fr, 40, byte_size(fr) - 40)
      %{long: long, pairs: String.duplicate("™" <> <<0xE9>>, 8_000)}
    end

    test "one © before an invalid byte near the start of a 2 MB French line", %{long: long} do
      assert ms(fn -> Paint.to_screen(long, [], Geex.Fixtures.birds(), 100, 5) end) < 300
      assert ms(fn -> Loop.cursor_xy(long, {0, 1_000_000}, 0, 4) end) < 300
      doc = Doc.new(long)
      assert ms(fn -> Doc.insert(doc, {0, 50}, "x") end) < 20
    end

    test "a 32 KB line of ™ and invalid bytes, each pair a fallback", %{pairs: pairs} do
      assert ms(fn -> Paint.to_screen(pairs, [], Geex.Fixtures.birds(), 100, 5) end) < 300
      assert ms(fn -> Width.line(pairs, 4) end) < 300
      assert Text.length(pairs) == 16_000
    end
  end
end
