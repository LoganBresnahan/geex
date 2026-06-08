defmodule Geex.RendererTest do
  use ExUnit.Case, async: true

  alias Geex.{Cell, Renderer, Screen}

  defp render(iodata), do: IO.iodata_to_binary(iodata)

  describe "diff/2 — no change" do
    test "identical screens emit nothing" do
      s = Screen.new(10, 3) |> Screen.draw_text(0, 0, "hello")
      assert render(Renderer.diff(s, s)) == ""
    end

    test "two blank same-size screens emit nothing" do
      a = Screen.new(10, 3)
      b = Screen.new(10, 3)
      assert render(Renderer.diff(a, b)) == ""
    end
  end

  describe "diff/2 — dimension change" do
    test "first flush (current is 0x0) clears and draws non-blank cells" do
      current = Screen.new(0, 0)
      next = Screen.new(5, 1) |> Screen.draw_text(0, 0, "hi")

      out = render(Renderer.diff(current, next))
      assert out =~ "\e[2J"
      # cursor to row 1 col 1, then "hi"
      assert out =~ "\e[1;1Hhi"
    end

    test "different dimensions clear even when content would otherwise diff cleanly" do
      current = Screen.new(5, 1)
      next = Screen.new(10, 1)
      assert render(Renderer.diff(current, next)) =~ "\e[2J"
    end
  end

  describe "diff/2 — incremental same-size" do
    test "single changed cell emits one cursor move + one char" do
      current = Screen.new(10, 3)
      next = Screen.set_cell(current, 4, 1, %Cell{char: "x"})

      # row 2 col 5 (1-indexed) → \e[2;5H, then "x"
      assert render(Renderer.diff(current, next)) == "\e[2;5Hx"
    end

    test "adjacent changed cells coalesce into one run" do
      current = Screen.new(10, 1)
      next = Screen.draw_text(current, 2, 0, "abc")
      assert render(Renderer.diff(current, next)) == "\e[1;3Habc"
    end

    test "non-adjacent changes produce two runs" do
      current = Screen.new(10, 1)

      next =
        current
        |> Screen.set_cell(1, 0, %Cell{char: "a"})
        |> Screen.set_cell(5, 0, %Cell{char: "b"})

      assert render(Renderer.diff(current, next)) == "\e[1;2Ha\e[1;6Hb"
    end

    test "changes on different rows produce one cursor move per row" do
      current = Screen.new(10, 3)

      next =
        current
        |> Screen.set_cell(0, 0, %Cell{char: "a"})
        |> Screen.set_cell(0, 2, %Cell{char: "b"})

      assert render(Renderer.diff(current, next)) == "\e[1;1Ha\e[3;1Hb"
    end

    test "deletions emit blank-cell overwrites" do
      current = Screen.new(5, 1) |> Screen.draw_text(0, 0, "abc")
      next = Screen.new(5, 1)
      # current shows "abc  ", next is "     " → cells 0..2 become blanks
      assert render(Renderer.diff(current, next)) == "\e[1;1H   "
    end

    test "a style-only change now emits the SGR escape + reset" do
      current = Screen.new(5, 1) |> Screen.set_cell(0, 0, %Cell{char: "a"})
      next = Screen.new(5, 1) |> Screen.set_cell(0, 0, %Cell{char: "a", fg: {:ansi, 1}})

      # {:ansi, 1} fg -> SGR 31; move, then \e[31m a \e[0m.
      assert render(Renderer.diff(current, next)) == "\e[1;1H\e[31ma\e[0m"
    end
  end

  describe "diff/2 — SGR styling" do
    test "a truecolor styled run emits one SGR + reset around its characters" do
      style = %Cell{fg: {:rgb, 239, 93, 50}, attrs: [:italic]}
      next = Screen.new(5, 1) |> Screen.draw_text(0, 0, "def", style)

      assert render(Renderer.diff(Screen.new(5, 1), next)) ==
               "\e[1;1H\e[3;38;2;239;93;50mdef\e[0m"
    end

    test "adjacent cells with different styles split into separate runs" do
      next =
        Screen.new(5, 1)
        |> Screen.set_cell(0, 0, %Cell{char: "a", fg: {:ansi, 1}})
        |> Screen.set_cell(1, 0, %Cell{char: "b", fg: {:ansi, 2}})

      # Two style-runs, each its own cursor-move + SGR + reset.
      assert render(Renderer.diff(Screen.new(5, 1), next)) ==
               "\e[1;1H\e[31ma\e[0m\e[1;2H\e[32mb\e[0m"
    end

    test "a plain run still emits no SGR (unstyled output is unchanged)" do
      next = Screen.new(5, 1) |> Screen.draw_text(0, 0, "abc")
      assert render(Renderer.diff(Screen.new(5, 1), next)) == "\e[1;1Habc"
    end
  end
end
