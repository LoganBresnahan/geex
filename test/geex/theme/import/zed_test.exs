defmodule Geex.Theme.Import.ZedTest do
  use ExUnit.Case, async: true

  alias Geex.Theme
  alias Geex.Theme.Import.Zed

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "zed-birds-of-paradise.json"])

  describe "import_file/1 — the real Birds of Paradise Zed theme" do
    test "imports near-losslessly into the native theme" do
      assert {:ok, theme} = Zed.import_file(@fixture)
      assert theme.name == "Birds of Paradise"
      assert theme.appearance == :dark

      # Palette from the editor.* keys + first players entry.
      assert theme.palette.bg == {:rgb, 55, 39, 37}
      assert theme.palette.fg == {:rgb, 230, 225, 196}
      assert theme.palette.cursor == {:rgb, 239, 93, 50}

      # Syntax: color -> fg; font_style/font_weight -> attrs.
      assert %{fg: {:rgb, 239, 93, 50}} = Theme.style_for(theme, "keyword")
      assert Theme.style_for(theme, "comment").attrs == [:italic]
      assert Theme.style_for(theme, "string").attrs == [:italic]
      assert Theme.style_for(theme, "title").attrs == [:bold]
    end

    test "the import matches the bundled native port for shared captures" do
      {:ok, imported} = Zed.import_file(@fixture)
      native = Geex.Fixtures.birds()

      for capture <- ~w(keyword comment string number function operator string.escape) do
        assert Theme.style_for(imported, capture) == Theme.style_for(native, capture),
               "Zed import and native port disagree on #{capture}"
      end
    end
  end

  describe "import_map/1 — shape handling" do
    test "accepts a bare single theme object (no themes[] wrapper)" do
      single = %{
        "name" => "X",
        "appearance" => "dark",
        "style" => %{
          "editor.background" => "#000000",
          "editor.foreground" => "#ffffff",
          "syntax" => %{"keyword" => %{"color" => "#ff0000"}}
        }
      }

      assert {:ok, theme} = Zed.import_map(single)
      assert Theme.style_for(theme, "keyword").fg == {:rgb, 255, 0, 0}
    end

    test "rejects a non-Zed map" do
      assert {:error, :not_a_zed_theme} = Zed.import_map(%{"hello" => "world"})
    end
  end
end
