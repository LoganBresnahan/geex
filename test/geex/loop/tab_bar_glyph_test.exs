defmodule Geex.Loop.TabBarGlyphTest do
  # The markdown preview's glyph on the tab bar (ADR-0043 §1, the review's F26/F27): between a
  # tab's name and its ×, which keeps the label's last two columns; lit on a preview tab; one
  # column, not East Asian Ambiguous.
  use ExUnit.Case, async: true

  alias Geex.Loop.TabBar

  test "a tab with the glyph reads ` N name ◫ × `; the × keeps the last two columns" do
    bar = TabBar.layout([{"a.md", :source}, "b.txt", {"a.md", :preview}], 0, 60, false)
    assert Enum.map(bar.tabs, & &1.label) == [" 1 a.md ◫ × ", " 2 b.txt × ", " 3 a.md ◫ × "]
    assert Enum.map(bar.tabs, & &1.glyph) == [%{x: 8, lit: false}, nil, %{x: 31, lit: true}]
  end

  test "a click on the glyph toggles that tab's preview; the × still closes, the name shows" do
    bar = TabBar.layout([{"a.md", :source}, "b.txt"], 0, 60, false)
    assert TabBar.hit(bar, 8) == {:toggle_preview, 0}
    assert TabBar.hit(bar, 9) == {:toggle_preview, 0}
    assert TabBar.hit(bar, 10) == {:close_tab, 0}
    assert TabBar.hit(bar, 11) == {:close_tab, 0}
    assert TabBar.hit(bar, 3) == {:tab, 0}
    # A tab without the glyph is as before.
    assert TabBar.hit(bar, 21) == {:close_tab, 1}
    assert TabBar.hit(bar, 19) == {:tab, 1}
  end

  test "the glyph is one column in any font: not East Asian Ambiguous, Wide or Full" do
    glyph = TabBar.preview_glyph()
    assert Geex.Width.string(glyph) == 1
    # U+25EB WHITE SQUARE WITH VERTICAL BISECTING LINE: East Asian Width N (Neutral).
    assert glyph == "◫"
    refute glyph == "¶"
  end
end
