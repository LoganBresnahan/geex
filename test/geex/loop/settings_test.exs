defmodule Geex.Loop.SettingsTest do
  # The settings view, Alt+Y (ADR-0040 §7): the view itself (pure), and the loop's side (the
  # theme, the mouse, installs, what's kept in settings.json, the hint on opening a file).
  # Uses the global Session and Renderer, and its own data and settings files: not async.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Geex.{Installed, Loop, Screen, Session}
  alias Geex.Loop.{KeyHelp, Settings}

  doctest KeyHelp

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_settings_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    old = {Application.get_env(:geex, :data_dir), Application.get_env(:geex, :settings_path)}
    Application.put_env(:geex, :data_dir, Path.join(dir, "data"))
    Application.put_env(:geex, :settings_path, Path.join(dir, "settings.json"))
    # Elixir, JSON and Birds of Paradise installed locally, as the suite has them.
    Geex.Fixtures.install(Path.join(dir, "data"))
    Installed.refresh()
    for f <- ["a.txt", "b.js"], do: File.write!(Path.join(dir, f), "x\n")
    Session.set_start(dir)

    on_exit(fn ->
      Application.put_env(:geex, :data_dir, elem(old, 0))
      Application.put_env(:geex, :settings_path, elem(old, 1))
      Installed.refresh()
      System.delete_env("GEEX_CATALOG_URL")

      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    {:ok, pid} = Session.open_file(Path.join(dir, "a.txt"))
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, Loop.new_state(120, 30))
    %{dir: dir, state: state}
  end

  defp send_io(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp click(state, x, y),
    do: send_io(state, {:mouse, %{action: :press, button: :left, x: x, y: y, mods: []}})

  defp frame(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    {state, Geex.Renderer.current()}
  end

  defp row_text(screen, y),
    do: Enum.map_join(0..(screen.w - 1), &Screen.get_cell(screen, &1, y).char) |> String.trim()

  describe "the view" do
    test "Languages lists the catalog with sizes and status; Enter installs what's available" do
      view = Settings.open()
      rows = Settings.rows(view, %{})
      assert length(rows) == length(Geex.Catalog.grammars())

      assert %{name: "rust", cells: ["Rust", _kb, "available"]} =
               Enum.find(rows, &(&1.name == "rust"))

      assert %{cells: [_, _, "installed"]} = Enum.find(rows, &(&1.name == "elixir"))

      rust = Enum.find_index(rows, &(&1.name == "rust"))
      assert {_, {:install, "rust"}} = Settings.key(%{view | sel: rust}, {:key, :enter}, rows, 30)
      elixir = Enum.find_index(rows, &(&1.name == "elixir"))
      assert {_, :none} = Settings.key(%{view | sel: elixir}, {:key, :enter}, rows, 30)
    end

    test "Alt+A and Alt+D change tabs, and never type into the Keys search" do
      view = Settings.open()
      {view, :none} = Settings.key(view, {:alt, ?d}, [], 30)
      assert view.tab == :themes
      {view, :none} = Settings.key(view, {:alt, ?A}, [], 30)
      {view, :none} = Settings.key(view, {:alt, ?a}, [], 30)
      assert view.tab == :general
      {view, :none} = Settings.key(view, {:alt, ?a}, [], 30)
      assert {view.tab, view.query} == {:keys, ""}
      {view, :none} = Settings.key(view, {:alt, ?D}, [], 30)
      assert {view.tab, view.query} == {:general, ""}
      assert Enum.any?(Geex.Loop.KeyHelp.search("alt+a"), &(elem(&1, 0) == "Settings"))
    end

    test "tabs, moving, closing; Keys filters as you type" do
      view = Settings.open()
      {view, :none} = Settings.key(view, {:key, :tab}, [], 30)
      assert view.tab == :themes
      {view, :none} = Settings.key(view, {:key, :left}, [], 30)
      {view, :none} = Settings.key(view, {:key, :left}, [], 30)
      assert view.tab == :general
      {view, :none} = Settings.key(view, {:key, :left}, [], 30)
      assert view.tab == :keys

      view =
        Enum.reduce(String.graphemes("redo"), view, fn g, v ->
          elem(Settings.key(v, {:char, g}, [], 30), 0)
        end)

      assert [%{cells: ["Alt+Z  Alt+Shift+Z", _, _]}] = Settings.rows(view, %{})
      {view, :none} = Settings.key(view, {:key, :backspace}, [], 30)
      assert view.query == "red"

      for key <- [{:key, :esc}, {:alt, ?y}],
          do: assert({_, :close} = Settings.key(view, key, [], 30))

      assert {_, :quit} = Settings.key(view, {:ctrl, ?x}, [], 30)
    end

    test "installed rows draw in the palette's accent, highlighted or not" do
      pal = %{Geex.Fixtures.birds().palette | accent: {:rgb, 1, 2, 3}}
      fg_at = fn screen, y -> Screen.get_cell(screen, 1, y).fg end

      # Languages: Elixir is installed, Rust isn't. Rows start at screen row 2.
      view = Settings.open()
      rows = Settings.rows(view, %{})
      elixir = Enum.find_index(rows, &(&1.name == "elixir"))
      rust = Enum.find_index(rows, &(&1.name == "rust"))
      assert {Enum.at(rows, elixir).installed, Enum.at(rows, rust).installed} == {true, false}

      screen = Settings.draw(%{view | sel: rust}, rows, pal, {120, 40})
      assert fg_at.(screen, 2 + elixir) == {:rgb, 1, 2, 3}
      assert fg_at.(screen, 2 + rust) == pal.fg

      # Highlighted, it keeps the colour, on the highlight's background.
      screen = Settings.draw(%{view | sel: elixir}, rows, pal, {120, 40})
      assert %{fg: {:rgb, 1, 2, 3}, bg: bg} = Screen.get_cell(screen, 1, 2 + elixir)
      assert bg == pal.active_line_bg

      # Themes: an installed one, and the one in use even when it is built in.
      view = Settings.open(:themes, %{theme_id: "terminal"})
      rows = Settings.rows(view, %{theme_id: "terminal"})

      assert Enum.map(rows, &{&1.name, &1.installed}) |> Enum.take(2) ==
               [{"terminal", true}, {"birds-of-paradise", true}]

      rows = Settings.rows(view, %{theme_id: "birds-of-paradise"})
      assert %{installed: false} = Enum.find(rows, &(&1.name == "terminal"))
    end

    test "Themes previews as you move and chooses on Enter; the one in use is marked" do
      view = Settings.open(:themes, %{theme_id: "birds-of-paradise"})
      rows = Settings.rows(view, %{theme_id: "birds-of-paradise"})

      assert %{name: "terminal", cells: ["terminal", "built in: your terminal's colours", ""]} =
               hd(rows)

      assert Enum.at(rows, view.sel).name == "birds-of-paradise"

      {view, action} = Settings.key(%{view | sel: 1}, {:key, :up}, rows, 30)
      assert {view.sel, action} == {0, {:preview_theme, "terminal"}}
      assert {_, {:choose_theme, "terminal"}} = Settings.key(view, {:key, :enter}, rows, 30)
    end

    test "the mouse: a tab, a row (acting as Enter), the wheel" do
      view = Settings.open()
      rows = Settings.rows(view, %{})
      # " Languages " is columns 1-11, " Themes " 13-20.
      {view, :none} =
        Settings.mouse(view, %{action: :press, button: :left, x: 15, y: 0}, rows, {120, 30})

      assert view.tab == :themes

      view = Settings.open()
      rust = Enum.find_index(rows, &(&1.name == "rust"))
      press = %{action: :press, button: :left, x: 5, y: 2 + rust}
      assert {%{sel: ^rust}, {:install, "rust"}} = Settings.mouse(view, press, rows, {120, 30})

      {view, _} =
        Settings.mouse(view, %{action: :wheel, button: :down, x: 5, y: 5}, rows, {120, 30})

      assert view.sel == 3
    end
  end

  describe "in the editor" do
    test "Alt+Y opens it full screen and Esc or Alt+Y closes it", %{state: state} do
      state = send_io(state, {:alt, ?y})
      assert %Settings{tab: :languages} = state.settings
      {state, screen} = frame(state)
      assert row_text(screen, 0) =~ "Languages   Themes   Keys   General"
      assert :reverse in Screen.get_cell(screen, 2, 0).attrs
      assert row_text(screen, 2) =~ "Bash"

      # Keys go to the view, not the buffer.
      state = send_io(state, {:char, "z"})
      assert {:ok, %{text: "x\n"}} = Session.snapshot()

      assert send_io(state, {:key, :esc}).settings == nil
      assert send_io(state, {:alt, ?Y}).settings == nil
    end

    test "a previewed theme is put back on Esc; a chosen one is kept, and loads next start",
         %{state: state, dir: dir} do
      # The terminal theme is in use (the default); Birds of Paradise is the next row.
      state = state |> send_io({:alt, ?y}) |> send_io({:key, :tab})
      state = send_io(state, {:key, :down})
      assert state.theme_id == "birds-of-paradise"
      state = send_io(state, {:key, :esc})
      assert state.theme_id == "terminal"

      state = state |> send_io({:alt, ?y}) |> send_io({:key, :tab}) |> send_io({:key, :down})
      state = send_io(state, {:key, :enter})
      assert state.settings.message == "theme birds-of-paradise kept"
      state = send_io(state, {:key, :esc})
      assert state.theme_id == "birds-of-paradise"

      assert JSON.decode!(File.read!(Path.join(dir, "settings.json"))) ==
               %{"theme" => "birds-of-paradise"}

      fresh = Loop.apply_settings(Loop.new_state(80, 24), Geex.Settings.load())
      assert {fresh.theme_id, fresh.theme.name} == {"birds-of-paradise", "Birds of Paradise"}
    end

    test "General: the mouse and the panes at start are kept", %{state: state, dir: dir} do
      state = state |> send_io({:alt, ?y}) |> send_io({:key, :left})
      assert state.settings.tab == :general
      state = send_io(state, {:key, :enter})
      assert state.mouse == false
      state = state |> send_io({:key, :down}) |> send_io({:key, :enter})
      assert state.tree_shown == false

      assert JSON.decode!(File.read!(Path.join(dir, "settings.json"))) ==
               %{"mouse" => false, "tree" => false}

      fresh = Loop.apply_settings(Loop.new_state(120, 30), Geex.Settings.load())
      assert {fresh.mouse, fresh.tree_shown} == {false, false}
      assert Loop.apply_settings(Loop.new_state(120, 30), %{"mouse" => "nonsense"}).mouse == true
    end

    # The maintainer's report: Enter on Themes' "update available" row only chose the theme
    # again ("theme kept"), as if it were up to date. It updates now, then chooses it.
    test "Enter on a theme with an update installs the update and shows it", %{
      state: state,
      dir: dir
    } do
      # Birds of Paradise as v0.1.0 installed it: a catalog install of the old package.
      data = Path.join(dir, "data")
      installed = Path.join([data, "themes", "birds-of-paradise", "installed.json"])
      File.write!(installed, ~s({"source":"catalog","sha256":"#{String.duplicate("0", 64)}"}))
      Installed.refresh()

      # The catalog's package, rebuilt from the recipe: the bytes the catalog pins.
      {themes, _} = Code.eval_file("catalog/themes.exs")
      {_manifest, zip} = Mix.Tasks.Geex.Catalog.theme_zip(hd(themes))
      entry = Geex.Catalog.theme("birds-of-paradise")
      assert Base.encode16(:crypto.hash(:sha256, zip), case: :lower) == entry["sha256"]
      File.write!(Path.join(dir, entry["asset"]), zip)
      System.put_env("GEEX_CATALOG_URL", "file://" <> dir)

      state = state |> send_io({:alt, ?y}) |> send_io({:alt, ?d})
      rows = Settings.rows(state.settings, %{theme_id: state.theme_id})
      birds = Enum.find_index(rows, &(&1.name == "birds-of-paradise"))
      assert Enum.at(rows, birds).status == "update available"

      state = send_io(%{state | settings: %{state.settings | sel: birds}}, {:key, :enter})
      assert Map.has_key?(state.installing, "birds-of-paradise")
      assert_receive {:geex_install_done, _pid, "birds-of-paradise", {:ok, _}} = done, 5_000
      {:noreply, state} = Loop.handle_info(done, state)

      assert File.read!(installed) =~ entry["sha256"]
      assert state.settings.message == "updated Birds of Paradise"
      rows = Settings.rows(state.settings, %{theme_id: state.theme_id})
      assert %{status: "installed", current: true} = Enum.at(rows, birds)
      assert state.theme.palette.accent == {:rgb, 0x86, 0xB4, 0xBB}

      # The view draws it in the new accent.
      {_state, screen} = frame(state)
      assert Screen.get_cell(screen, 1, 2 + birds).fg == {:rgb, 0x86, 0xB4, 0xBB}
    end

    test "an install from the view runs off the loop and says how it went", %{
      state: state,
      dir: dir
    } do
      # The catalog's rust asset, served from a directory holding the wrong bytes.
      entry = Geex.Catalog.grammar("rust")
      File.write!(Path.join(dir, entry["asset"]), "not it")
      System.put_env("GEEX_CATALOG_URL", "file://" <> dir)

      state = send_io(state, {:alt, ?y})
      rows = Settings.rows(state.settings, %{})
      rust = Enum.find_index(rows, &(&1.name == "rust"))
      state = click(state, 5, 2 + rust)
      assert Map.has_key?(state.installing, "rust")
      assert state.settings.message == "installing rust…"

      assert Enum.at(Settings.rows(state.settings, %{installing: MapSet.new(["rust"])}), rust).status ==
               "installing…"

      assert_receive {:geex_install_done, _pid, "rust", {:error, {:sha256_mismatch, _}}} = done,
                     5_000

      {:noreply, state} = Loop.handle_info(done, state)
      assert state.installing == %{}
      assert state.settings.message =~ "rust: the download doesn't match"
    end

    test "opening a file the catalog can highlight says so once; Alt+Y opens on its language",
         %{state: state, dir: dir} do
      {:ok, js} = Session.open_file(Path.join(dir, "b.js"))
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, js}, state)
      assert state.notice == "JavaScript highlighting available: Alt+Y"

      state = send_io(state, {:alt, ?y})
      rows = Settings.rows(state.settings, %{})
      assert Enum.at(rows, state.settings.sel).name == "javascript"
    end
  end

  # The step 6 review's findings, and the coordinator's note on General's paths.
  describe "review fixes" do
    test "an install still running doesn't choose its theme after the user chose another",
         %{state: state, dir: dir} do
      state = send_io(state, {:alt, ?y})
      pending = %{pid: self(), ref: make_ref(), then: {:choose_theme, "birds-of-paradise"}}
      state = %{state | installing: %{"birds-of-paradise" => pending}}

      # Themes highlights the theme in use, terminal; Enter keeps it.
      state = state |> send_io({:key, :tab}) |> send_io({:key, :enter})
      assert state.settings.message == "theme terminal kept"
      state = send_io(state, {:key, :esc})

      done = %{kind: :theme, name: "birds-of-paradise", display: "Birds", sha256: "x"}

      {:noreply, state} =
        Loop.handle_info({:geex_install_done, self(), "birds-of-paradise", {:ok, done}}, state)

      assert state.theme_id == "terminal"
      assert JSON.decode!(File.read!(Path.join(dir, "settings.json"))) == %{"theme" => "terminal"}
    end

    test "moving to Themes highlights the theme in use", %{state: state} do
      state = Loop.apply_settings(state, %{"theme" => "birds-of-paradise"})
      state = state |> send_io({:alt, ?y}) |> send_io({:key, :tab})
      rows = Settings.rows(state.settings, %{theme_id: state.theme_id})
      assert Enum.at(rows, state.settings.sel).name == "birds-of-paradise"
    end

    test "General shows and turns over what geex starts with, not this session's state",
         %{state: state, dir: dir} do
      File.write!(Path.join(dir, "settings.json"), ~s({"tree": true}))
      state = %{state | tree_shown: false}
      state = state |> send_io({:alt, ?y}) |> send_io({:key, :left})
      rows = Settings.rows(state.settings, %{saved: state.settings_saved})
      assert %{cells: ["File tree", "on", _]} = Enum.at(rows, 1)
      assert %{cells: ["Mouse", "on", _]} = Enum.at(rows, 0)

      state = state |> send_io({:key, :down}) |> send_io({:key, :enter})
      assert state.tree_shown == false
      assert JSON.decode!(File.read!(Path.join(dir, "settings.json"))) == %{"tree" => false}
    end

    test "a settings.json that isn't JSON is left alone, and the view says so",
         %{state: state, dir: dir} do
      file = Path.join(dir, "settings.json")
      File.write!(file, ~s({"theme": "x", oops}))
      assert Geex.Settings.put("mouse", false) == {:error, :unreadable}
      state = state |> send_io({:alt, ?y}) |> send_io({:key, :left}) |> send_io({:key, :enter})
      assert state.settings.message =~ "isn't valid JSON, left alone"
      assert File.read!(file) == ~s({"theme": "x", oops})
    end

    test "a file opening while the view is open keeps its hint for later",
         %{state: state, dir: dir} do
      state = send_io(state, {:alt, ?y})
      {:ok, js} = Session.open_file(Path.join(dir, "b.js"))
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, js}, state)
      assert state.hinted == []
    end

    test "on a screen too short for a list, a click on the help line acts on nothing" do
      view = Settings.open()
      rows = Settings.rows(view, %{})
      press = %{action: :press, button: :left, x: 3, y: 2}
      assert {_, :none} = Settings.mouse(view, press, rows, {80, 3})
      %Screen{} = Settings.draw(view, rows, Geex.Theme.default().palette, {10, 2})
    end

    test "General's paths show ~ and keep their file name, cut from the left", %{state: state} do
      state = %{state | w: 40} |> send_io({:alt, ?y}) |> send_io({:key, :left})
      {_state, screen} = frame(state)
      settings_row = row_text(screen, 5)
      assert String.starts_with?(settings_row, "Settings")
      assert String.ends_with?(settings_row, "settings.json")
      assert settings_row =~ "…"
    end

    test "geex install --force alone, or with --list, is the listing" do
      import ExUnit.CaptureIO
      assert capture_io(fn -> assert Geex.CLI.install(["--force"]) == 0 end) =~ "rust"
      assert capture_io(fn -> assert Geex.CLI.install(["--list", "--force"]) == 0 end) =~ "rust"
    end
  end

  test "a catalog install already up to date fetches nothing; --force would" do
    entry = Geex.Catalog.grammar("rust")
    dir = Installed.dir(:grammar, "rust")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      JSON.encode!(%{"kind" => "grammar", "name" => "rust", "display" => "Rust", "abi" => 15})
    )

    File.write!(
      Path.join(dir, "installed.json"),
      JSON.encode!(%{"source" => "catalog", "sha256" => entry["sha256"]})
    )

    Installed.refresh()
    System.put_env("GEEX_CATALOG_URL", "file:///nonexistent")

    assert {:ok, %{unchanged: true, display: "Rust"}} = Geex.Install.install("rust")
    assert {:error, {:read, :enoent}} = Geex.Install.install("rust", force: true)
  end
end
