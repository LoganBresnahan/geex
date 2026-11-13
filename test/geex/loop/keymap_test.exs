defmodule Geex.Loop.KeymapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Geex.Loop.Keymap

  alias Geex.Loop.{Bindings, Keymap}
  alias Geex.Commands.{Delete, Insert, Replace}

  # A key as the loop hands it to the keymap: a bound key translated by the default bindings
  # into the command it runs (ADR-0047), the editor's own keys as they are. So these tests say
  # what a key does with the keys geex ships.
  defp resolve(event, cursor, text), do: Keymap.resolve(command(event), cursor, text)
  defp vertical?(event), do: Keymap.vertical?(command(event))
  defp command(event), do: Bindings.translate(event, Bindings.defaults())

  describe "resolve/3 — edits on the one shared path" do
    test "a printable char inserts it and advances the cursor" do
      assert {:edit, %Insert{line: 0, col: 2, text: "x"}, {0, 3}} =
               resolve({:char, "x"}, {0, 2}, "ab")
    end

    test "a wide char advances one grapheme column (screen width is the renderer's job)" do
      assert {:edit, %Insert{text: "中"}, {0, 1}} =
               resolve({:char, "中"}, {0, 0}, "")
    end

    test "Enter inserts a newline and moves to the next line start" do
      assert {:edit, %Insert{line: 1, col: 3, text: "\n"}, {2, 0}} =
               resolve({:key, :enter}, {1, 3}, "a\nbcd\ne")
    end

    test "Tab inserts two spaces" do
      assert {:edit, %Insert{text: "  "}, {0, 2}} = resolve({:key, :tab}, {0, 0}, "")
    end

    test "Backspace mid-line deletes the grapheme before the cursor" do
      assert {:edit, %Delete{line: 0, col: 1, count: 1}, {0, 1}} =
               resolve({:key, :backspace}, {0, 2}, "abc")
    end

    test "Backspace at column 0 joins onto the previous line (Replace across the boundary)" do
      assert {:edit, %Replace{start_line: 0, start_col: 2, end_line: 1, end_col: 0, text: ""},
              {0, 2}} =
               resolve({:key, :backspace}, {1, 0}, "ab\ncd")
    end

    test "Backspace at the very start of the buffer is ignored" do
      assert :ignore = resolve({:key, :backspace}, {0, 0}, "abc")
    end
  end

  describe "resolve/3 — cursor motion (clamped, wrapping)" do
    test "left within a line" do
      assert {:move, {0, 1}} = resolve({:key, :left}, {0, 2}, "abc")
    end

    test "left at column 0 wraps to the end of the previous line" do
      assert {:move, {0, 2}} = resolve({:key, :left}, {1, 0}, "ab\ncd")
    end

    test "left at the very start stays put" do
      assert {:move, {0, 0}} = resolve({:key, :left}, {0, 0}, "abc")
    end

    test "right within a line" do
      assert {:move, {0, 2}} = resolve({:key, :right}, {0, 1}, "abc")
    end

    test "right at the line end wraps to the next line start" do
      assert {:move, {1, 0}} = resolve({:key, :right}, {0, 2}, "ab\ncd")
    end

    test "right at the buffer end stays put" do
      assert {:move, {0, 3}} = resolve({:key, :right}, {0, 3}, "abc")
    end

    test "up keeps the column, clamped to the shorter line" do
      assert {:move, {0, 2}} = resolve({:key, :up}, {1, 4}, "ab\ncdef")
    end

    test "down past the last line stays on it" do
      assert {:move, {1, 0}} = resolve({:key, :down}, {1, 0}, "ab\ncd")
    end
  end

  describe "goal column — sticky vertical motion" do
    test "vertical?/1 flags up/down and Alt+I/K, nothing else" do
      assert vertical?({:key, :up})
      assert vertical?({:key, :down})
      assert vertical?({:alt, ?i})
      # Alt+Shift+K moves the line down (ADR-0052), not the cursor.
      refute vertical?({:alt, ?K})
      refute vertical?({:key, :left})
      refute vertical?({:alt, ?l})
      refute vertical?({:char, "x"})
    end

    test "goal_column/2 is the column mid-line, :eol at the line end" do
      text = "hello\nhi"
      assert Keymap.goal_column({0, 2}, text) == 2
      assert Keymap.goal_column({0, 5}, text) == :eol
      # an empty line: column 0 is already the end
      assert Keymap.goal_column({1, 2}, "ab\n") == :eol
    end

    test "apply_goal/3 keeps a numeric column, clamped to the target line" do
      text = "0123456789\nhi\nlong enough line"
      # goal 7 on a long line lands at 7; on the 2-char line clamps to 2 (its end)
      assert Keymap.apply_goal({0, 0}, 7, text) == {0, 7}
      assert Keymap.apply_goal({1, 0}, 7, text) == {1, 2}
      assert Keymap.apply_goal({2, 0}, 7, text) == {2, 7}
    end

    test "apply_goal/3 with :eol tracks the end of each line (empty lines included)" do
      text = "hello\n\ngoodbye world"
      assert Keymap.apply_goal({0, 0}, :eol, text) == {0, 5}
      assert Keymap.apply_goal({1, 0}, :eol, text) == {1, 0}
      assert Keymap.apply_goal({2, 0}, :eol, text) == {2, 13}
    end

    test "the goal survives a short line: down through 'hi' and back to a long line restores the column" do
      text = "0123456789\nhi\nABCDEFGHIJ"
      goal = Keymap.goal_column({0, 7}, text)
      # down to the short line clamps, but the goal is unchanged, so down again restores col 7
      assert Keymap.apply_goal({1, 0}, goal, text) == {1, 2}
      assert Keymap.apply_goal({2, 0}, goal, text) == {2, 7}
    end
  end

  describe "resolve/3 — control" do
    test "Ctrl-X / Ctrl-Q / Ctrl-C all quit (flow-control/signal-robust)" do
      assert :quit = resolve({:ctrl, ?x}, {0, 0}, "")
      assert :quit = resolve({:ctrl, ?q}, {0, 0}, "")
      assert :quit = resolve({:ctrl, ?c}, {0, 0}, "")
    end

    test "Ctrl-O saves (ADR-0026's reserved save chord — Ctrl-S is XOFF)" do
      assert :save = resolve({:ctrl, ?o}, {0, 0}, "")
      assert :save = resolve({:ctrl, ?O}, {0, 0}, "")
    end

    test "an unknown key is ignored" do
      assert :ignore = resolve({:ctrl, ?z}, {0, 0}, "")
    end
  end

  describe "resolve/3 — selection (ADR-0029)" do
    test "Alt+S starts a selection, Alt+A selects all, Esc clears; Alt+N is the next match" do
      assert :select_start = resolve({:alt, ?s}, {0, 0}, "abc")
      assert :select_start = resolve({:alt, ?S}, {0, 0}, "abc")
      assert :select_all = resolve({:alt, ?a}, {0, 0}, "abc")
      assert :select_all = resolve({:alt, ?A}, {0, 0}, "abc")
      assert :next_match = resolve({:alt, ?n}, {0, 0}, "abc")
      assert :search = resolve({:alt, ?q}, {0, 0}, "abc")
      assert :select_clear = resolve({:key, :esc}, {0, 0}, "abc")
    end

    test "Alt+C / Alt+X / Alt+V are copy / cut / paste (Alt+X distinct from Ctrl-X quit)" do
      assert :copy = resolve({:alt, ?c}, {0, 0}, "abc")
      assert :cut = resolve({:alt, ?x}, {0, 0}, "abc")
      assert :paste = resolve({:alt, ?v}, {0, 0}, "abc")
      assert :quit = resolve({:ctrl, ?x}, {0, 0}, "abc")
    end
  end

  describe "resolve/3 — undo/redo (ADR-0031)" do
    test "Alt+Z undoes, Alt+Shift+Z redoes — case-sensitive (as Alt+R and Alt+Shift+R are)" do
      assert :undo = resolve({:alt, ?z}, {0, 0}, "abc")
      assert :redo = resolve({:alt, ?Z}, {0, 0}, "abc")
    end
  end

  describe "resolve/3 — Alt chords" do
    test "Alt+M opens the minibuffer" do
      assert :minibuffer = resolve({:alt, ?m}, {0, 0}, "")
      assert :minibuffer = resolve({:alt, ?M}, {0, 0}, "")
    end

    test "Alt+WASD moves like the arrows (arrow-key alternative)" do
      text = "abc\ndef"

      assert resolve({:alt, ?l}, {0, 0}, text) ==
               resolve({:key, :right}, {0, 0}, text)

      assert resolve({:alt, ?j}, {0, 1}, text) ==
               resolve({:key, :left}, {0, 1}, text)

      assert resolve({:alt, ?i}, {1, 1}, text) == resolve({:key, :up}, {1, 1}, text)

      assert resolve({:alt, ?k}, {0, 1}, text) ==
               resolve({:key, :down}, {0, 1}, text)
    end

    test "Alt+H/; jump to line start / end" do
      text = "foo bar baz"
      assert {:move, {0, 0}} = resolve({:alt, ?h}, {0, 5}, text)
      assert {:move, {0, 11}} = resolve({:alt, ?;}, {0, 5}, text)
    end

    test "Alt+U/O move by word (whitespace-delimited, clamped to the line)" do
      text = "foo bar baz"
      # forward (O) from start / mid-word → start of "bar"
      assert {:move, {0, 4}} = resolve({:alt, ?o}, {0, 0}, text)
      assert {:move, {0, 4}} = resolve({:alt, ?o}, {0, 1}, text)
      # backward (U) from "baz" → start of "bar"
      assert {:move, {0, 4}} = resolve({:alt, ?u}, {0, 8}, text)
      # forward at the last word clamps to the line end; backward at the first clamps to col 0
      assert {:move, {0, 11}} = resolve({:alt, ?o}, {0, 8}, text)
      assert {:move, {0, 0}} = resolve({:alt, ?u}, {0, 2}, text)
    end

    test "Alt+G opens grid mode (ADR-0027)" do
      assert :grid = resolve({:alt, ?g}, {0, 0}, "abc")
      assert :grid = resolve({:alt, ?G}, {0, 0}, "abc")
    end

    test "Alt+B opens the command palette (ADR-0028 §3, ADR-0037)" do
      assert :palette = resolve({:alt, ?b}, {0, 0}, "abc")
      assert :palette = resolve({:alt, ?B}, {0, 0}, "abc")
    end

    test "unbound Alt letters are ignored" do
      assert :ignore = resolve({:alt, ?y}, {0, 0}, "abc")
      assert :ignore = resolve({:alt, ?Y}, {0, 0}, "abc")
    end

    test "the pane and file keys (ADR-0037)" do
      for {letter, action} <- [
            {?f, :find_file},
            {?w, :close},
            {?t, :toggle_tree},
            {?e, :toggle_edits},
            {?d, :fast_forward}
          ],
          c <- [letter, letter - 32] do
        assert resolve({:alt, c}, {0, 0}, "abc") == action, "Alt+#{<<c>>}"
      end
    end
  end

  describe "resolve/3 — the panes and the preview (ADR-0043 §1, ADR-0051)" do
    test "Alt+> and Alt+< are the next pane and the one before; Alt+P (and Alt+Shift+P) the preview" do
      assert resolve({:alt, ?>}, {0, 0}, "abc") == :next_pane
      assert resolve({:alt, ?<}, {0, 0}, "abc") == :prev_pane
      assert resolve({:alt, ?p}, {0, 0}, "abc") == :toggle_preview
      assert resolve({:alt, ?P}, {0, 0}, "abc") == :toggle_preview
    end

    test "Page Up/Down do nothing in the editor" do
      for k <- [:page_up, :page_down],
          do: assert(resolve({:key, k}, {0, 0}, "a") == :ignore)
    end
  end

  describe "Home, End, Delete" do
    test "Home and End go to the line's start and end" do
      assert {:move, {1, 0}} = resolve({:key, :home}, {1, 2}, "ab\ncdef")
      assert {:move, {1, 4}} = resolve({:key, :end}, {1, 2}, "ab\ncdef")
    end

    test "Delete removes the grapheme under the cursor and stays put" do
      assert {:edit, %Delete{line: 0, col: 1, count: 1}, {0, 1}} =
               resolve({:key, :delete}, {0, 1}, "abc")
    end

    test "Delete at a line's end joins the next line" do
      assert {:edit, %Replace{start_line: 0, start_col: 2, end_line: 1, end_col: 0, text: ""},
              {0, 2}} = resolve({:key, :delete}, {0, 2}, "ab\ncd")
    end

    test "Delete at the very end of the buffer is ignored" do
      assert :ignore = resolve({:key, :delete}, {1, 2}, "ab\ncd")
    end
  end

  # Roadmap item 18.7: Tab follows the file. The indented lines vote, tab-led against space-led;
  # unindented and blank ones don't; a tie, or none, is spaces.
  property "indent_style/1 is the majority of the indented lines" do
    check all(
            lines <-
              list_of(
                one_of([
                  constant({:tab, "\tx"}),
                  constant({:tab, "\t  y"}),
                  constant({:space, "  x"}),
                  constant({:space, " \tz"}),
                  constant({:none, "x"}),
                  constant({:none, "   "}),
                  constant({:none, ""})
                ]),
                max_length: 60
              )
          ) do
      text = Enum.map_join(lines, "\n", &elem(&1, 1))
      tabs = Enum.count(lines, &(elem(&1, 0) == :tab))
      spaces = Enum.count(lines, &(elem(&1, 0) == :space))
      assert Keymap.indent_style(text) == if(tabs > spaces, do: :tabs, else: :spaces)
    end
  end

  # ADR-0050: indenting lines, then un-indenting them, by the same kind of level.
  # Indents of every kind, and the shared generator's lines (ADR-0044's 2026-11-12 amendment).
  defp shift_line,
    do:
      frequency([
        {3,
         member_of([
           "",
           "x",
           "  x",
           "\tx",
           "   ",
           "\t\ty",
           " \tz",
           "a b",
           "x\r",
           "  y\r",
           "\r",
           "é",
           "  👍🏽 e\u0301",
           " \t\r",
           "\f",
           "\u00A0x",
           "  \u00A0"
         ])},
        {1, Geex.Gen.line()}
      ])

  defp apply_shift(text, nil), do: text

  defp apply_shift(text, {%Replace{} = cmd, _shifts}) do
    range = {{cmd.start_line, cmd.start_col}, {cmd.end_line, cmd.end_col}}
    {:ok, doc} = Geex.Buffer.Doc.replace(Geex.Buffer.Doc.new(text), range, cmd.text)
    Geex.Buffer.Doc.text(doc)
  end

  property "indent then un-indent gives the lines back; lines outside the range never change" do
    check all(
            lines <- list_of(shift_line(), min_length: 1, max_length: 12),
            a <- integer(0..(length(lines) - 1)),
            b <- integer(a..(length(lines) - 1)),
            tab_size <- member_of([2, 4, 8]),
            unit <- member_of(["\t", String.duplicate(" ", tab_size)])
          ) do
      text = Enum.join(lines, "\n")
      indented = apply_shift(text, Keymap.shift_lines(text, {a, b}, {:indent, unit}))
      back = apply_shift(indented, Keymap.shift_lines(indented, {a, b}, {:unindent, tab_size}))

      # Spaces come back off only from a line whose leading spaces were whole levels; a tab always.
      # A blank line (spaces and tabs only) is never touched either way, so it always comes back.
      whole? = fn l ->
        n = byte_size(l) - byte_size(String.trim_leading(l, " "))
        blank?(l) or unit == "\t" or rem(n, tab_size) == 0
      end

      if Enum.all?(Enum.slice(lines, a..b), whole?), do: assert(back == text)

      new_lines = String.split(indented, "\n")
      assert length(new_lines) == length(lines)

      for {{old, new}, i} <- Enum.with_index(Enum.zip(lines, new_lines)) do
        cond do
          i < a or i > b -> assert new == old
          blank?(old) -> assert new == old
          true -> assert new == unit <> old
        end
      end

      # Un-indenting never touches a blank line either.
      unindented = apply_shift(text, Keymap.shift_lines(text, {a, b}, {:unindent, tab_size}))

      for {old, new} <- Enum.zip(lines, String.split(unindented, "\n")),
          blank?(old),
          do: assert(new == old)
    end
  end

  defp blank?(l), do: String.match?(l, ~r/\A[ \t]*\r?\z/)

  test "indent_style/1 reads only the first 1000 lines" do
    text = String.duplicate("  x\n", 1000) <> String.duplicate("\tx\n", 2000)
    assert Keymap.indent_style(text) == :spaces
  end

  # Roadmap item 19: a pair closed as you type it, then Backspace, gives back the text as it was.
  property "an auto-closed pair and Backspace undo each other" do
    check all(
            line <- Geex.Gen.code_fragment(max_length: 12),
            seed <- non_negative_integer(),
            g <- member_of(["(", "[", "{", "'", "\"", "`"])
          ) do
      col = rem(seed, Geex.Text.length(line) + 1)

      with {:edit, cmd, cursor} = action <- Keymap.autoclose({:char, g}, {0, col}, line, []) do
        pairs = Keymap.track([], {:char, g}, action, {0, col})
        paired = apply_text(cmd, line)
        {:edit, back, back_to} = Keymap.unpair(cursor, paired, pairs)
        assert back_to == {0, col}
        assert apply_text(back, paired) == line
      end
    end
  end

  # Roadmap item 19 (the review's ask): whatever is typed, Backspaced or moved over, every pair
  # still tracked has its opener and its closer where it says, and the cursor between them; so a
  # step-over or a Backspace on a tracked pair never acts on text geex didn't put there.
  property "tracked pairs always sit on a real opener and closer, around the cursor" do
    check all(
            start <- Geex.Gen.code_fragment(max_length: 6),
            keys <-
              list_of(
                frequency([
                  {6, map(Geex.Gen.code_piece(), &{:char, &1})},
                  {1, constant({:key, :backspace})},
                  {1, constant({:key, :left})},
                  {1, constant({:key, :right})}
                ]),
                max_length: 30
              )
          ) do
      Enum.reduce(keys, {start, {0, Geex.Text.length(start)}, []}, fn key,
                                                                      {text, cursor, pairs} ->
        action =
          case key do
            {:char, _} -> Keymap.autoclose(key, cursor, text, pairs)
            {:key, :backspace} -> Keymap.unpair(cursor, text, pairs)
            _ -> nil
          end || resolve(key, cursor, text)

        pairs = Keymap.track(pairs, key, action, cursor)

        {text, cursor} =
          case action do
            {:edit, cmd, to} -> {apply_text(cmd, text), to}
            {:move, to} -> {text, to}
            _ -> {text, cursor}
          end

        {_, c} = cursor

        for {0, o, cl} <- pairs do
          open = Geex.Text.at(text, o)

          assert Map.get(
                   %{"(" => ")", "[" => "]", "{" => "}", "'" => "'", "\"" => "\"", "`" => "`"},
                   open
                 ) ==
                   Geex.Text.at(text, cl),
                 "#{inspect(text)}: #{inspect({o, cl})} isn't a pair"

          assert o < c and c <= cl, "#{inspect(text)}: cursor #{c} outside #{inspect({o, cl})}"
        end

        {text, cursor, pairs}
      end)
    end
  end

  # The other half (the re-verify's ask): a pair typed and then filled, the cursor moved about
  # inside it and back, is still tracked, so its closer steps over.
  property "a pair geex closed stays tracked while the cursor stays inside" do
    check all(
            g <- member_of(["(", "[", "{"]),
            fill <- string(Enum.concat([?a..?z, ?0..?9, [?\s]]), max_length: 8),
            back <- non_negative_integer()
          ) do
      type = fn {text, cursor, pairs}, key ->
        action = Keymap.autoclose(key, cursor, text, pairs) || resolve(key, cursor, text)
        pairs = Keymap.track(pairs, key, action, cursor)

        case action do
          {:edit, cmd, to} -> {apply_text(cmd, text), to, pairs}
          {:move, to} -> {text, to, pairs}
        end
      end

      run =
        Enum.reduce(
          [{:char, g} | for(c <- Geex.Text.graphemes(fill), do: {:char, c})],
          {"", {0, 0}, []},
          &type.(&2, &1)
        )

      moves = rem(back, Geex.Text.length(fill) + 1)

      run =
        Enum.reduce(
          List.duplicate({:key, :left}, moves) ++ List.duplicate({:key, :right}, moves),
          run,
          &type.(&2, &1)
        )

      {text, _, _} = type.(run, {:char, Map.fetch!(%{"(" => ")", "[" => "]", "{" => "}"}, g)})
      assert text == g <> fill <> Map.fetch!(%{"(" => ")", "[" => "]", "{" => "}"}, g)
    end
  end

  # Roadmap item 19: Enter adds only line breaks and whitespace, and the new line starts with
  # the indent before the cursor. The oracle is the line's construction: an indent of spaces and
  # tabs, then a body that starts with a letter (the review: the property mustn't restate the
  # code's own reading of the indent).
  property "Enter with the indent kept adds only whitespace, and keeps the indent" do
    check all(
            indent <- map(list_of(member_of([" ", "\t"]), max_length: 6), &Enum.join/1),
            body <- Geex.Gen.code_fragment(max_length: 10),
            seed <- non_negative_integer(),
            unit <- member_of(["  ", "    ", "\t"]),
            colon <- boolean()
          ) do
      line = indent <> "a" <> body
      col = rem(seed, Geex.Text.length(line) + 1)
      {:edit, cmd, {1, new_col}} = Keymap.newline({0, col}, line, unit, colon: colon)
      [_first, second | _] = cmd |> apply_text(line) |> String.split("\n")

      squash = &String.replace(&1, ~r/\s/u, "")
      assert squash.(apply_text(cmd, line)) == squash.(line)

      base = Geex.Text.slice(indent, 0, col)
      assert String.starts_with?(second, base)
      assert new_col >= Geex.Text.length(base)
    end
  end

  defp apply_text(cmd, text) do
    {:ok, editor} = Geex.Dispatch.apply_command(cmd, Geex.EditorState.new(text))
    Geex.EditorState.text(editor)
  end

  # The review's planted bug (`inner = unit`): the opener's level is on top of the line's indent.
  test "Enter after an opener on an indented line indents one level past it" do
    assert {:edit, %{text: "\n      "}, {1, 6}} = Keymap.newline({0, 6}, "    f(", "  ")
    assert {:edit, %{text: "\n\t\t\n\t"}, {1, 2}} = Keymap.newline({0, 3}, "\tf{}", "\t")

    assert {:edit, %{text: "\n    "}, {1, 4}} =
             Keymap.newline({0, 6}, "  def:", "  ", colon: true)
  end

  test "CRLF lines: the CR is the line's end, and the break is CRLF" do
    text = "foo\r\nbar"

    assert {:edit, %{text: "()", col: 3}, {0, 4}} =
             Keymap.autoclose({:char, "("}, {0, 3}, text, [])

    # A cursor after the CR counts as the line's end.
    assert {:edit, %{text: "()", col: 3}, {0, 4}} =
             Keymap.autoclose({:char, "("}, {0, 4}, text, [])

    assert {:edit, %{text: "\r\n  "}, {1, 2}} = Keymap.newline({0, 5}, "  foo\r\nx", "  ")
    # A line of only indent, its CR aside, is cleared.
    assert {:edit, %Geex.Commands.Replace{text: "\r\n  "}, {2, 2}} =
             Keymap.newline({1, 2}, "x\r\n  \r\ny", "  ")

    assert {:edit, %{text: "\r\n", col: 0}, {2, 0}} = Keymap.newline({1, 1}, "a\r\n\r\nb", "  ")
  end

  test "string state spans all three quotes, backslashes escaping inside a string" do
    assert {:edit, %{text: "''"}, _} =
             Keymap.autoclose({:char, "'"}, {0, 16}, ~S|x = "it's" + |, [])

    # An escaped quote keeps the string open; an escaped backslash doesn't.
    assert Keymap.autoclose({:char, "'"}, {0, 8}, ~S|"it's \"|, []) == nil
    assert {:edit, _, _} = Keymap.autoclose({:char, "'"}, {0, 9}, ~S|"it's \\"|, [])
    assert Keymap.autoclose({:char, "\""}, {0, 6}, ~S|'say |, []) == nil
    assert {:edit, _, _} = Keymap.autoclose({:char, "`"}, {0, 0}, "", [])
    assert Keymap.autoclose({:char, "`"}, {0, 0}, "", [], backtick: false) == nil
  end

  test "quotes that would close a string, or follow a closer or an accented letter, don't pair" do
    # print(f"{x}") — the opener after `f` doesn't pair; the closer after `}` mustn't either.
    assert Keymap.autoclose({:char, "\""}, {0, 11}, "print(f\"{x}", []) == nil
    assert Keymap.autoclose({:char, "`"}, {0, 18}, "css`color: red;", []) == nil
    # An escaped quote inside a closed string doesn't count: the next one opens a string.
    line = ~S(x = "a\"b" + )
    assert {:edit, %{text: "\"\""}, _} = Keymap.autoclose({:char, "\""}, {0, 13}, line, [])
    assert Keymap.autoclose({:char, "\""}, {0, 6}, ~S(x = "a\"), []) == nil
    assert Keymap.autoclose({:char, "'"}, {0, 5}, "(cat)", []) == nil
    assert Keymap.autoclose({:char, "'"}, {0, 4}, "José", []) == nil
    assert Keymap.autoclose({:char, "'"}, {0, 0}, "", [], single_quote: false) == nil
    assert {:edit, _, _} = Keymap.autoclose({:char, "\""}, {0, 0}, "", [], single_quote: false)
  end

  test "kind_opts/1: prose, Rust and Lisp keep `'`; Python, YAML and Makefiles open on `:`" do
    assert Keymap.kind_opts("/p/a.rs")[:single_quote] == false
    assert Keymap.kind_opts("/p/a.clj")[:single_quote] == false
    assert Keymap.kind_opts("/p/a.ex")[:single_quote] == true
    assert Keymap.kind_opts("/p/x.yml")[:colon] == true
    assert Keymap.kind_opts("/p/Makefile.am")[:colon] == true
    assert Keymap.kind_opts("/p/a.ex")[:colon] == false
    assert Keymap.kind_opts("/p/d.tsv")[:indent] == false

    assert Keymap.kind_opts(nil) == [
             single_quote: true,
             backtick: true,
             colon: false,
             indent: true
           ]

    assert Keymap.kind_opts("/p/a.el")[:backtick] == false
    assert Keymap.kind_opts("/p/a.hs")[:single_quote] == false
  end

  # The property's first counterexample, shrunk: a combining accent right after the indent.
  test "Enter's indent is counted by grapheme" do
    line = "    \u0301aaaa"
    {:edit, cmd, {1, 3}} = Keymap.newline({0, 4}, line, "  ")
    assert cmd.text == "\n   "
  end

  # Roadmap item 19: the "Indent with" setting and the kinds of file that use tabs.
  test "indent_with/3: Makefiles always tabs; Go, TSV and git config by kind; the rest follow" do
    spaced = "x:\n  y\n"

    for path <-
          ~w(/p/Makefile /p/makefile /p/GNUmakefile /p/BSDmakefile /p/Makefile.am /p/Makefile.in /p/rules.mk /p/rules.mk.in /p/a.mak),
        setting <- [:follow, :spaces, :tabs],
        do: assert(Keymap.indent_with(spaced, path, setting) == :tabs, "#{path} #{setting}")

    for path <- ~w(/p/main.go /p/go.mod /p/go.work /p/data.tsv /p/.gitmodules /home/u/.gitconfig) do
      assert Keymap.indent_with(spaced, path, :follow) == :tabs, path
      assert Keymap.indent_with("", path, :spaces) == :spaces, path
    end

    assert Keymap.indent_with(spaced, "/p/a.rb", :follow) == :spaces
    assert Keymap.indent_with("\tx\n", "/p/a.rb", :follow) == :tabs
    assert Keymap.indent_with(spaced, "/p/a.rb", :tabs) == :tabs
    assert Keymap.indent_with(spaced, nil, :follow) == :spaces
  end

  # geex-d3's last note: only the line ending's `\r` is its end; one before it is text.
  test "End stops before a CRLF line's CR, not before an extra one" do
    assert resolve({:key, :end}, {0, 0}, "foo\r\nbar") == {:move, {0, 3}}
    assert resolve({:key, :end}, {0, 0}, "a\r\r\nb") == {:move, {0, 2}}
  end
end
