defmodule Geex.Loop.ThemeTest do
  # The built-in terminal theme in the loop (ADR-0040 §1): the `theme` verb, the terminal's
  # background answer (OSC 11), and the reverse-video fallback when there is none. Through the
  # loop's own handle_info/2 and the global Renderer, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Loop, Screen, Session, Theme}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_theme_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    for f <- ["a.txt", "b.txt"], do: File.write!(Path.join(dir, f), "#{f}\n")
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    {:ok, pid} = Session.open_file(Path.join(dir, "a.txt"))
    state = %{Loop.new_state(120, 30) | edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    %{state: state}
  end

  defp send_io(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp type(state, text) do
    state = send_io(state, {:alt, ?m})
    state = Enum.reduce(String.graphemes(text), state, &send_io(&2, {:char, &1}))
    send_io(state, {:key, :enter})
  end

  defp frame(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    {state, Geex.Renderer.current()}
  end

  test "`theme terminal` switches; `theme` lists; an unknown name says so", %{state: state} do
    # The default, geex shipping no theme (ADR-0040); the fixture Birds of Paradise is installed.
    assert {state.theme_id, state.theme.name} == {"terminal", "terminal"}
    state = type(state, "theme birds-of-paradise")
    assert state.theme.name == "Birds of Paradise"
    state = type(state, "theme terminal")
    assert {state.theme_id, state.theme.name} == {"terminal", "terminal"}
    assert state.theme.palette.bg == :default

    state = type(state, "theme")
    assert state.notice =~ "terminal *"
    assert state.notice =~ "birds-of-paradise"

    state = type(state, "theme nope")
    assert state.notice =~ "no theme nope"
    assert state.theme_id == "terminal"

    state = type(state, "theme birds-of-paradise")
    assert state.theme.name == "Birds of Paradise"
  end

  test "the terminal's background tints the terminal theme; another theme only keeps it",
       %{state: state} do
    answer = {:osc, "11", "rgb:0000/0000/0000"}
    state = type(state, "theme birds-of-paradise")
    state = send_io(state, answer)
    assert state.terminal_bg == {:rgb, 0, 0, 0}
    assert state.theme.name == "Birds of Paradise"

    state = type(state, "theme terminal")
    assert state.theme.palette.active_line_bg == {:rgb, 18, 18, 18}
    assert state.theme.palette.mark == []

    # A later answer re-tints; a bad one or another OSC changes nothing, and no key is typed.
    state = send_io(state, {:osc, "11", "rgb:ffff/ffff/ffff"})
    assert state.theme.appearance == :light
    same = send_io(state, {:osc, "11", "nonsense"})
    assert same.theme == state.theme
    assert send_io(state, {:osc, "10", "rgb:ff/ff/ff"}).theme == state.theme
    assert {:ok, %{text: "a.txt\n"}} = Session.snapshot()
  end

  test "with no answer, a picked tree row and the selection are drawn in reverse video",
       %{state: state} do
    state = type(state, "theme terminal")
    assert state.theme.palette.mark == [:reverse]

    # Into the tree (Alt+P from the editor goes to the edits pane first when shown; it's hidden).
    state = send_io(state, {:alt, ?p})
    assert state.focus == :tree
    assert_receive {:geex_tree, _pid, _files} = read, 5_000
    {:noreply, state} = Loop.handle_info(read, state)
    {state, screen} = frame(state)
    # The tree's first row is row 1; its highlighted row is reversed, the next one isn't.
    assert :reverse in Screen.get_cell(screen, 2, 1).attrs
    refute :reverse in Screen.get_cell(screen, 2, 2).attrs

    # Back to the editor, select all: the text is reversed.
    state = send_io(state, {:key, :esc}) |> send_io({:alt, ?b})
    {_state, screen} = frame(state)
    gutter = Loop.gutter_width("a.txt\n")
    assert :reverse in Screen.get_cell(screen, 30 + gutter, 1).attrs
  end

  test "the status line is a reversed bar under the terminal theme too", %{state: state} do
    state = type(state, "theme terminal")
    {state, screen} = frame(state)
    assert :reverse in Screen.get_cell(screen, 0, state.h - 1).attrs
  end

  test "Birds of Paradise draws exactly as before: no mark" do
    assert Geex.Fixtures.birds().palette.mark == []
    assert Theme.default().palette.mark == [:reverse]
  end
end
