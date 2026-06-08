defmodule Geex.ThemeTest do
  use ExUnit.Case, async: true

  alias Geex.{Ansi, Color, Highlight, Theme}
  alias Geex.Highlight.Span

  defp theme, do: Geex.Theme.default()

  describe "Geex.Color" do
    test "parses #RRGGBB to truecolor rgb" do
      assert Color.from_hex("#EF5D32") == {:rgb, 239, 93, 50}
      assert Color.from_hex("#6C99BB") == {:rgb, 108, 153, 187}
    end

    test "flattens #RRGGBBAA against the background (no terminal alpha)" do
      bg = {:rgb, 55, 39, 37}
      assert Color.from_hex("#00000000", bg) == bg, "alpha 0 -> background"
      assert Color.from_hex("#000000FF", bg) == {:rgb, 0, 0, 0}, "alpha 255 -> foreground"
    end
  end

  describe "Theme.style_for/2 (longest-prefix)" do
    test "exact capture hit" do
      assert %{fg: {:rgb, 239, 93, 50}} = Theme.style_for(theme(), "keyword")
      assert %{fg: {:rgb, 190, 115, 253}} = Theme.style_for(theme(), "string.escape")
    end

    test "carries font attrs from the Zed port" do
      assert Theme.style_for(theme(), "string").attrs == [:italic]
      assert Theme.style_for(theme(), "title").attrs == [:bold]
    end

    test "unstyled specific capture falls back to its prefix" do
      # constant.builtin -> constant; comment.unused -> comment (italic)
      assert Theme.style_for(theme(), "constant.builtin") == Theme.style_for(theme(), "constant")
      assert Theme.style_for(theme(), "comment.unused").attrs == [:italic]
      assert Theme.style_for(theme(), "comment.doc.__attribute__").fg == {:rgb, 107, 78, 50}
    end

    test "nil when neither the capture nor any prefix is styled" do
      assert Theme.style_for(theme(), "totally.unknown.capture") == nil
    end
  end

  describe "Ansi.sgr/1" do
    test "truecolor fg + italic" do
      assert Ansi.sgr(%Theme.Style{fg: {:rgb, 217, 215, 98}, attrs: [:italic]}) ==
               "\e[3;38;2;217;215;98m"
    end

    test "a style that paints nothing is empty" do
      assert Ansi.sgr(%Theme.Style{}) == ""
    end
  end

  describe "Ansi.highlight/3 — render stage" do
    test "narrower (more specific) span wins its bytes — escape inside a string" do
      text = "abcde"

      spans = [
        %Span{start_byte: 0, end_byte: 5, capture: "string"},
        %Span{start_byte: 2, end_byte: 4, capture: "string.escape"}
      ]

      out = Ansi.highlight(theme(), text, spans)
      # "ab" string-yellow-italic, "cd" escape-purple, "e" string again
      assert out =~ "\e[3;38;2;217;215;98mab"
      assert out =~ "\e[38;2;190;115;253mcd"
    end

    test "equal-width overlap: the more specific capture wins" do
      spans = [
        %Span{start_byte: 0, end_byte: 3, capture: "string"},
        %Span{start_byte: 0, end_byte: 3, capture: "string.special"}
      ]

      out = Ansi.highlight(theme(), "abc", spans)
      # string.special (#6C99BB italic), not string (#D9D762)
      assert out =~ "\e[3;38;2;108;153;187mabc"
      refute out =~ "217;215;98"
    end

    test "unstyled bytes keep the default (no escape emitted around them)" do
      assert Ansi.highlight(theme(), "  ", []) == "  "
    end

    test "end-to-end: real elixir highlighting renders truecolor" do
      {:ok, spans} = Highlight.spans("def f, do: :ok\n", "elixir")
      out = Ansi.highlight(theme(), "def f, do: :ok\n", spans)
      # `def` is a keyword (#EF5D32)
      assert out =~ "38;2;239;93;50"
      # and the bytes survive round-trip (strip SGR -> original text)
      assert strip_ansi(out) == "def f, do: :ok\n"
    end
  end

  defp strip_ansi(s), do: String.replace(s, ~r/\e\[[0-9;]*m/, "")
end
