defmodule Geex.Loop.LongLinesTest do
  # BUG-12: on a long line `Geex.Loop.Keymap` reads only a window around the cursor (an ASCII
  # line by bytes), so a key costs the same near the end of a 2 MB line as at its start. The
  # properties hold the windowed answers to the whole-line ones (written out here, reading the
  # line whole as the code did before); the timings hold the cost.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.Buffer.Doc
  alias Geex.Commands.Replace
  alias Geex.Loop.Keymap

  # A line long enough to be read through a window (over 4 KB), from pieces that put words,
  # spaces, brackets and characters of several bytes everywhere; now and then a word or a gap
  # longer than the window, so a read runs into its side and falls back to the whole line.
  defp piece(ascii?) do
    common = [
      {8, member_of(~w(a bc xyz q))},
      {5, member_of([" ", "  ", "\t"])},
      {2, member_of(~w|( ) [ ] { } ,|)},
      {1, constant(String.duplicate("w", 1500))},
      {1, constant(String.duplicate(" ", 1500))}
    ]

    wide = [{2, member_of(["é", "é", "👍🏽", "λ", "日"])}]
    frequency(if ascii?, do: common, else: common ++ wide)
  end

  # A few dozen pieces, then more of them, until the line passes 4.5 KB: a short list to shrink.
  defp long_line do
    gen all(
          ascii? <- boolean(),
          head <- list_of(piece(ascii?), min_length: 1, max_length: 40),
          tail <- list_of(piece(ascii?), min_length: 1, max_length: 40),
          crlf? <- boolean()
        ) do
      unit = Enum.join(tail)
      head = Enum.join(head)
      reps = div(4500, max(byte_size(unit), 1)) + 1
      head <> String.duplicate(unit, reps) <> if(crlf?, do: "\r", else: "")
    end
  end

  defp body(l), do: String.replace_suffix(l, "\r", "")
  defp space?(g), do: g in [" ", "\t"]

  # The whole-line answers, as Keymap computed them before BUG-12's window.
  defp ref_word_forward(gs, col) do
    n = length(gs)
    rest = Enum.drop(gs, min(col, n))
    word = Enum.take_while(rest, &(not space?(&1)))
    gap = rest |> Enum.drop(length(word)) |> Enum.take_while(&space?/1)
    min(col, n) + length(word) + length(gap)
  end

  defp ref_word_back(gs, col) do
    before = gs |> Enum.take(min(col, length(gs))) |> Enum.reverse()
    gap = Enum.take_while(before, &space?/1)
    word = before |> Enum.drop(length(gap)) |> Enum.take_while(&(not space?(&1)))
    min(col, length(gs)) - length(gap) - length(word)
  end

  defp ref_word_at(gs, col) do
    t = List.to_tuple(gs)
    n = tuple_size(t)
    word? = &(not space?(elem(t, &1)))

    start =
      cond do
        col < n and word?.(col) -> col
        i = Enum.find(col..(n - 1)//1, word?) -> i
        i = Enum.find((min(col, n) - 1)..0//-1, word?) -> i
        true -> nil
      end

    if start do
      a = Enum.find(start..0//-1, &(&1 == 0 or not word?.(&1 - 1)))
      b = Enum.find(start..n//1, &(&1 == n or not word?.(&1)))
      {a, b}
    end
  end

  property "on a long line the word motions and Alt+8 answer as reading it whole would" do
    check all(l <- long_line(), seed <- integer(0..1_000_000)) do
      gs = String.graphemes(body(l))
      col = rem(seed, length(gs) + 1)
      text = "first\n" <> l <> "\nlast"

      assert Keymap.resolve({:cmd, :word_forward}, {1, col}, text) ==
               {:move, {1, ref_word_forward(gs, col)}}

      assert Keymap.resolve({:cmd, :word_back}, {1, col}, text) ==
               {:move, {1, ref_word_back(gs, col)}}

      want =
        case ref_word_at(gs, col) do
          nil -> nil
          {a, b} when a == b -> nil
          {a, b} -> {{1, a}, {1, b}}
        end

      assert Keymap.select_more(:word, text, {1, col}, nil) == want
    end
  end

  property "on a long line a move keeps the text whole, and a character move comes back" do
    check all(
            l <- long_line(),
            seed <- integer(0..1_000_000),
            len <- integer(1..8),
            how <- member_of([:left, :right, :word_back, :word_forward])
          ) do
      b_gs = String.graphemes(body(l))
      a = rem(seed, max(length(b_gs) - len, 1))
      b = min(a + len, length(b_gs))
      text = "first\n" <> l <> "\nlast"

      with {%Replace{} = cmd, {1, f}, {1, t}} <- Keymap.move_text(text, {{1, a}, {1, b}}, how) do
        moved = run(text, cmd)
        [_, new_l, _] = String.split(moved, "\n")
        assert String.ends_with?(new_l, if(String.ends_with?(l, "\r"), do: "\r", else: ""))
        new_gs = String.graphemes(body(new_l))
        assert Enum.sort(new_gs) == Enum.sort(b_gs)

        assert Enum.slice(new_gs, f..(t - 1)//1) |> Enum.join() |> String.trim() ==
                 Enum.slice(b_gs, a..(b - 1)//1) |> Enum.join() |> String.trim()

        if how in [:left, :right] do
          back = if how == :left, do: :right, else: :left
          {cmd2, {1, ^a}, {1, ^b}} = Keymap.move_text(moved, {{1, f}, {1, t}}, back)
          assert run(moved, cmd2) == text
        end
      end
    end
  end

  property "on a long line a bracket's pair's pair is the bracket" do
    check all(l <- long_line(), seed <- integer(0..1_000_000)) do
      gs = String.graphemes(body(l))
      text = "x\n" <> l <> "\ny"
      brackets = for {g, c} <- Enum.with_index(gs), g in ~w|( ) [ ] { }|, do: c

      if brackets != [] do
        c = Enum.at(brackets, rem(seed, length(brackets)))

        case Keymap.matching_bracket({1, c}, text) do
          nil -> :ok
          pair -> assert Keymap.matching_bracket(pair, text) == {1, c}
        end
      end
    end
  end

  describe "a 2 MB line costs what a short one does" do
    setup do
      line = String.duplicate("ab, cd ", 300_000)
      n = String.length(line)
      %{text: "x(\n" <> line <> "\n)\n", c: n - 10}
    end

    defp fast(fun, bound \\ 50) do
      # The fastest of three, so a loaded machine's pause doesn't count; before BUG-12's window
      # each of these took 0.3–0.7 s.
      ms = for(_ <- 1..3, do: elem(:timer.tc(fun), 0)) |> Enum.min() |> div(1000)
      assert ms < bound, "#{ms} ms"
    end

    test "Alt+O, Alt+U, Alt+8 and Alt+8 again near its end", %{text: text, c: c} do
      fast(fn -> Keymap.resolve({:cmd, :word_forward}, {1, c}, text) end)
      fast(fn -> Keymap.resolve({:cmd, :word_back}, {1, c}, text) end)
      fast(fn -> Keymap.select_more(:word, text, {1, c}, nil) end)
      fast(fn -> Keymap.select_more(:word, text, {1, c}, {{1, c - 3}, {1, c}}) end)
    end

    test "the sideways moves near its end", %{text: text, c: c} do
      for how <- [:left, :right, :word_back, :word_forward] do
        fast(fn -> Keymap.move_text(text, {{1, c - 3}, {1, c - 1}}, how) end)
      end
    end

    test "Alt+\\ near its end, and from the line below it", %{text: text, c: c} do
      # Alt+\\ may read its whole 200,000-character budget (ADR-0052 §4), so it costs that, not a
      # window: ~30 ms here, 60–110 ms on CI's runner, 0.66–0.9 s before BUG-12's fix.
      fast(fn -> Keymap.matching_bracket({1, c}, text) end, 250)
      fast(fn -> Keymap.matching_bracket({2, 0}, text) end, 250)
    end
  end

  test "backward, a pair at the end of a 1 MB line above the cursor's is found" do
    text = String.duplicate("a", 1_000_000) <> "(\n)"
    assert Keymap.matching_bracket({1, 0}, text) == {0, 1_000_000}
    assert Keymap.matching_bracket({0, 1_000_000}, text) == {1, 0}
    # From inside the pair, the bracket around.
    assert Keymap.matching_bracket({1, 2}, "(\n  x)") == {0, 0}
    long = String.duplicate("a", 1_000_000) <> "(\n  x)"
    assert Keymap.matching_bracket({1, 2}, long) == {0, 1_000_000}
  end

  test "a combining mark just past an ASCII window joins the character before it" do
    # The window around column 4000 ends at byte 5024, where the mark joins the space before it
    # into one character that isn't a space: the word runs on through it.
    line =
      String.duplicate("x", 3990) <>
        " " <>
        String.duplicate("x", 1032) <>
        " \u0301" <>
        String.duplicate("y", 10)

    assert Keymap.select_more(:word, line, {0, 4000}, nil) ==
             {{0, 3991}, {0, String.length(line)}}
  end

  test "a bracket a combining mark joins isn't a bracket, read by bytes or not" do
    # `(` with a combining acute is one character, `(́`, and not a bracket.
    assert Keymap.matching_bracket({0, 1}, "x(\u0301)") == nil
    assert Keymap.matching_bracket({0, 2}, "x(\u0301") == nil
  end

  test "a non-ASCII long line: the pair at its end is found, counted from its end" do
    text = String.duplicate("é", 900_000) <> "(\n)"
    assert Keymap.matching_bracket({1, 0}, text) == {0, 900_000}
  end

  defp run(text, %Replace{} = cmd) do
    range = {{cmd.start_line, cmd.start_col}, {cmd.end_line, cmd.end_col}}
    {:ok, doc} = Doc.replace(Doc.new(text), range, cmd.text)
    Doc.text(doc)
  end
end
