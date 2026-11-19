defmodule Geex.Loop.RevertPreviewTest do
  # ADR-0033's 2026-11-18 amendment: every revert shows what it takes back first. Alt+R and
  # Alt+Shift+R mark the lines the revert would change and ask y/n; y makes it exactly as
  # planned, n or Esc changes nothing, a refusal is said at once, and a buffer that changed while
  # the question was up refuses it. Through the loop's own handle_info/2 and the global Session,
  # so not async.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Geex.{Buffer, Loop, Minibuffer, Reconcile, Screen, Session}
  alias Geex.Ledger.Restore

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_revert_preview_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "f.txt")
    File.write!(path, "one\ntwo\nthree\nfour\n")
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    {:ok, pid} = Session.open_file(path)
    # An agent's Bash call changed lines 2 and 4, credited "while" (ADR-0032's amendment).
    {:reconciled, _} = Reconcile.reconcile(pid, "one\nTWO\nthree\nFOUR\n")

    :attested =
      Buffer.attest(pid, %{
        path: path,
        before: Restore.sha256("one\ntwo\nthree\nfour\n"),
        sha256: Restore.sha256("one\nTWO\nthree\nFOUR\n"),
        harness: "claude-code",
        session: "7ccbf3d1-aaaa",
        turn: nil,
        tool_use: "u1",
        user_modified: false,
        during: "Bash",
        program: "sed"
      })

    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, Loop.new_state(120, 30))
    Session.set_cursor({1, 0})
    %{pid: pid, state: state}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  test "Alt+Shift+R marks every line it would change and asks; nothing changes yet", ctx do
    state = key(ctx.state, {:alt, ?R})

    assert Minibuffer.prompt(state.minibuffer) ==
             "revert 2 hunks (changed while claude-code/7ccbf3d1 ran sed)? (y/n)"

    assert {:revert, _pid, %{lines: [{1, 1}, {3, 3}]}, _info} = state.asking
    assert Buffer.get_text(ctx.pid) == "one\nTWO\nthree\nFOUR\n"
  end

  test "y makes it, as planned, and says so", ctx do
    state = ctx.state |> key({:alt, ?R}) |> key({:char, "y"})

    assert Buffer.get_text(ctx.pid) == "one\ntwo\nthree\nfour\n"
    assert state.notice == "reverted the change made while claude-code/7ccbf3d1 ran sed (2 hunks)"
    assert state.asking == nil
    refute Minibuffer.active?(state.minibuffer)
  end

  test "n and Esc change nothing and drop the marks", ctx do
    for answer <- [{:char, "n"}, {:key, :esc}] do
      state = ctx.state |> key({:alt, ?R}) |> key(answer)
      assert Buffer.get_text(ctx.pid) == "one\nTWO\nthree\nFOUR\n"
      assert state.notice == "nothing done"
      assert state.asking == nil
    end
  end

  test "Alt+R takes back only the hunk under the cursor, after asking", ctx do
    state = key(ctx.state, {:alt, ?r})

    assert Minibuffer.prompt(state.minibuffer) ==
             "revert 1 hunk (changed while claude-code/7ccbf3d1 ran sed)? (y/n)"

    assert {:revert, _pid, %{lines: [{1, 1}]}, _info} = state.asking
    key(state, {:char, "y"})
    assert Buffer.get_text(ctx.pid) == "one\ntwo\nthree\nFOUR\n"
  end

  test "a buffer that changed while the question was up refuses it", ctx do
    state = key(ctx.state, {:alt, ?R})
    {:reconciled, _} = Reconcile.reconcile(ctx.pid, "zero\none\nTWO\nthree\nFOUR\n")
    state = key(state, {:char, "y"})

    assert state.notice == "not reverted: the file changed while you were deciding"
    assert Buffer.get_text(ctx.pid) == "zero\none\nTWO\nthree\nFOUR\n"
  end

  test "a refusal is said at once, with no question", ctx do
    Session.set_cursor({0, 0})
    state = key(ctx.state, {:alt, ?R})

    assert state.notice == "nothing to revert: no agent or outside change last wrote this line"
    refute Minibuffer.active?(state.minibuffer)
    assert state.asking == nil
  end

  test "revert_marks/7 tints the text of the rows in range, not the gutter, not other rows" do
    theme = Geex.Fixtures.birds()
    {screen, _cursor, _h} = Loop.frame("a\nb\nc\nd", [], theme, {0, 0}, 20, 4, 0)
    gw = Loop.gutter_width("a\nb\nc\nd")
    marked = Loop.revert_marks(screen, [{1, 2}], 0, 4, gw, 20, theme)

    for row <- [1, 2] do
      assert Screen.get_cell(marked, gw, row).bg == theme.palette.selection
      assert Screen.get_cell(marked, 19, row).bg == theme.palette.selection
      assert Screen.get_cell(marked, 0, row) == Screen.get_cell(screen, 0, row)
    end

    for row <- [0, 3],
        x <- 0..19,
        do: assert(Screen.get_cell(marked, x, row) == Screen.get_cell(screen, x, row))

    assert Loop.revert_marks(screen, [], 0, 4, gw, 20, theme) == screen

    # The cursor's line carries the current-line tint, and is always one a revert changes.
    {on_cursor, _cursor, _h} = Loop.frame("a\nb\nc\nd", [], theme, {1, 0}, 20, 4, 0)
    assert Screen.get_cell(on_cursor, gw, 1).bg == theme.palette.active_line_bg
    marked = Loop.revert_marks(on_cursor, [{1, 1}], 0, 4, gw, 20, theme)
    assert Screen.get_cell(marked, gw, 1).bg == theme.palette.selection
  end
end
