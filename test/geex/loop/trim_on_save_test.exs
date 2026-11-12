defmodule Geex.Loop.TrimOnSaveTest do
  # ADR-0054 through the loop's own handle_info/2: a save trims trailing whitespace, a setting on
  # by default; Markdown, diffs and patches keep theirs; one recorded step with the final newline.
  # Uses the global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_trim_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    state = %{Loop.new_state(100, 24) | tree_shown: false, edits_shown: false}
    %{dir: dir, state: state}
  end

  defp open_file(state, dir, name, text) do
    path = Path.join(dir, name)
    File.write!(path, text)
    {:ok, pid} = Session.open_file(path)
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid, path}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp save(state), do: key(state, {:ctrl, ?o})
  defp cursor, do: elem(Session.snapshot(), 1).cursor

  test "on by default: every line's trailing spaces and tabs go; one Alt+Z brings them back", %{
    state: state,
    dir: dir
  } do
    assert state.trim_whitespace
    text = "a  \nb\t\n   \nc \t \nd\n"
    {state, buf, path} = open_file(state, dir, "a.txt", text)
    state = save(state)

    assert File.read!(path) == "a\nb\n\nc\nd\n"
    refute Buffer.status(buf).dirty
    # One replace, however many lines it trims (ADR-0054 §4).
    assert length(Buffer.history(buf)) == 1
    assert Enum.all?(Buffer.history(buf), &(&1.meta.actor == :human))

    state = key(state, {:alt, ?z})
    assert Buffer.get_text(buf) == text
    assert state.notice == nil
  end

  test "blame marks only the lines trimmed, not the ones between (ADR-0032's amendment)", %{
    state: state,
    dir: dir
  } do
    {state, buf, _path} = open_file(state, dir, "b.txt", "trim  \nkeep\nkeep\ntrim \nkeep\n")
    _ = save(state)
    blame = :sys.get_state(buf).history.blame
    assert Enum.map(blame, &(&1 != nil)) == [true, false, false, true, false, false]
  end

  # mod-verify's review: a space a Prepend character joins to is one grapheme with it, not
  # trailing whitespace; the old per-line trim recorded an empty replace on every save.
  test "a space joined to a Prepend character stays, and no edit is recorded", %{
    state: state,
    dir: dir
  } do
    text = "x\u0600 \ny\u0D4E \n"
    {state, buf, path} = open_file(state, dir, "p.txt", text)
    state = save(state)
    _ = save(state)
    assert File.read!(path) == text
    assert Buffer.history(buf) == []
  end

  test "a CRLF line keeps its \\r; a form feed and a no-break space are text", %{
    state: state,
    dir: dir
  } do
    {state, _buf, path} = open_file(state, dir, "w.txt", "a  \r\nb\f\nc \n \t\r\n")
    _ = save(state)
    assert File.read!(path) == "a\r\nb\f\nc \n\r\n"
  end

  test "Markdown, diffs and patches keep their trailing whitespace", %{state: state, dir: dir} do
    for name <- ["n.md", "n.markdown", "n.mdx", "fix.diff", "fix.patch"] do
      {state, _buf, path} = open_file(state, dir, name, "hard break  \nnext\n")
      _ = save(state)
      assert File.read!(path) == "hard break  \nnext\n", name
    end
  end

  test "with the final newline on, both are one step", %{state: state, dir: dir} do
    {state, buf, path} = open_file(%{state | final_newline: true}, dir, "f.txt", "x  \ny ")
    state = save(state)
    assert File.read!(path) == "x\ny\n"

    _ = key(state, {:alt, ?z})
    assert Buffer.get_text(buf) == "x  \ny "
  end

  test "nothing to trim makes no edit", %{state: state, dir: dir} do
    {state, buf, path} = open_file(state, dir, "c.txt", "clean\n")
    _ = save(state)
    assert File.read!(path) == "clean\n"
    assert Buffer.history(buf) == []
  end

  test "a cursor past a trimmed line's end goes to that end", %{state: state, dir: dir} do
    {state, _buf, _path} = open_file(state, dir, "e.txt", "ab    \nz\n")
    Session.set_cursor({0, 6})
    _ = save(state)
    assert cursor() == {0, 2}
  end

  test "a save that fails leaves no edit behind", %{state: state, dir: dir} do
    {state, buf, path} = open_file(state, dir, "r.txt", "abc  \n")
    File.chmod!(path, 0o444)
    on_exit(fn -> File.chmod(path, 0o644) end)
    _ = save(state)

    assert Buffer.get_text(buf) == "abc  \n"
    assert File.read!(path) == "abc  \n"
    assert Buffer.history(buf) == []
  end

  test "off, a save writes the text as it is", %{state: state, dir: dir} do
    {state, _buf, path} = open_file(%{state | trim_whitespace: false}, dir, "o.txt", "a  \n")
    _ = save(state)
    assert File.read!(path) == "a  \n"
  end

  test "settings.json's trim_trailing_whitespace: false turns it off; it is on without" do
    refute Loop.apply_settings(Loop.new_state(80, 24), %{"trim_trailing_whitespace" => false}).trim_whitespace

    assert Loop.apply_settings(Loop.new_state(80, 24), %{}).trim_whitespace
  end
end
