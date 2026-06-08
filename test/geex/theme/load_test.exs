defmodule Geex.Theme.LoadTest do
  use ExUnit.Case, async: true

  alias Geex.Theme

  describe "bundled / default" do
    test "default/0 loads Birds of Paradise from priv/themes (data, not code)" do
      theme = Theme.default()
      assert theme.name == "Birds of Paradise"
      assert theme.appearance == :dark
      assert theme.palette.bg == {:rgb, 55, 39, 37}
      assert %{fg: {:rgb, 239, 93, 50}} = Theme.style_for(theme, "keyword")
      assert Theme.style_for(theme, "comment").attrs == [:italic]
    end

    test "bundled/1 errors cleanly for an unknown theme" do
      assert {:error, {:read, :enoent}} = Theme.bundled("does-not-exist")
    end
  end

  describe "from_json/1 — validating parser" do
    @ok %{
      "name" => "T",
      "appearance" => "light",
      "palette" => %{"bg" => "#000000", "fg" => "#ffffff"},
      "syntax" => %{
        "keyword" => "#ff0000",
        "string" => %{"fg" => "#00ff00", "italic" => true, "bold" => true}
      }
    }

    test "builds a theme; bare hex = fg-only, object adds attrs" do
      assert {:ok, theme} = Theme.from_json(@ok)
      assert theme.appearance == :light
      assert Theme.style_for(theme, "keyword") == %Theme.Style{fg: {:rgb, 255, 0, 0}}
      string = Theme.style_for(theme, "string")
      assert string.fg == {:rgb, 0, 255, 0}
      assert Enum.sort(string.attrs) == [:bold, :italic]
    end

    test "flattens #RRGGBBAA palette colours against the background" do
      data = put_in(@ok, ["palette", "selection"], "#ffffff00")
      assert {:ok, theme} = Theme.from_json(data)
      # alpha 00 over black bg -> the background
      assert theme.palette.selection == {:rgb, 0, 0, 0}
    end

    test "missing name / palette / palette.bg are tagged errors" do
      assert {:error, {:missing, "name"}} = Theme.from_json(Map.delete(@ok, "name"))
      assert {:error, {:missing, "palette"}} = Theme.from_json(Map.delete(@ok, "palette"))
      assert {:error, {:missing, "bg"}} = Theme.from_json(%{@ok | "palette" => %{"fg" => "#fff000"}})
    end

    test "a bad colour / appearance is a tagged error, not a crash" do
      assert {:error, {:bad_color, "keyword", "nothex"}} =
               Theme.from_json(put_in(@ok, ["syntax", "keyword"], "nothex"))

      assert {:error, {:bad_appearance, "mauve"}} =
               Theme.from_json(Map.put(@ok, "appearance", "mauve"))
    end

    test "a non-object is rejected" do
      assert {:error, :not_a_theme_object} = Theme.from_json("nope")
    end
  end

  describe "load/1 — file" do
    test "reports an unreadable file and bad JSON as tagged errors" do
      assert {:error, {:read, :enoent}} = Theme.load("/no/such/theme.json")

      path = Path.join(System.tmp_dir!(), "geex_bad_theme_#{System.unique_integer([:positive])}.json")
      File.write!(path, "{not json")
      on_exit(fn -> File.rm(path) end)
      assert {:error, {:bad_json, _}} = Theme.load(path)
    end
  end
end
