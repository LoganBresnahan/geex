defmodule Geex.Loop.LongLineLoopTest do
  # BUG-12 and BUG-13 through the loop's own handle_info/2: on a file with one 2 MB line, with
  # the cursor near its end, a key, a typed character and the repaint after each cost what a
  # short line's do. Before, a repaint took about 2.3 s and a typed character about 1 s. Uses the
  # global Session, so not async.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Loop, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_long_line_loop_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    Session.set_start(dir)

    on_exit(fn ->
      for %{pid: pid} <- Session.buffers(),
          do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)

      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp open(dir, line) do
    path = Path.join(dir, "big.txt")
    File.write!(path, "x(\n" <> line <> "\n)\n")
    {:ok, pid} = Session.open_file(path)
    state = %{Loop.new_state(100, 30) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    {state, pid}
  end

  # The fastest of three runs of `event` from the cursor at `at`, then the repaint after it.
  defp fast(state, at, event) do
    runs =
      for _ <- 1..3 do
        Session.set_cursor(at)

        {key_us, {:noreply, after_key}} =
          :timer.tc(fn -> Loop.handle_info({:geex_io, event}, state) end)

        {paint_us, _} = :timer.tc(fn -> Loop.handle_info(:repaint, after_key) end)
        {key_us, paint_us}
      end

    {key, paint} =
      {runs |> Enum.map(&elem(&1, 0)) |> Enum.min(), runs |> Enum.map(&elem(&1, 1)) |> Enum.min()}

    {div(key, 1000), div(paint, 1000)}
  end

  test "keys, typing and the repaint near the end of a 2 MB line", %{dir: dir} do
    line = String.duplicate("ab, cd ", 300_000)
    {state, _buf} = open(dir, line)
    at = {1, String.length(line) - 10}
    Session.set_cursor(at)
    {:noreply, state} = Loop.handle_info(:repaint, state)

    for event <- [
          {:alt, ?o},
          {:alt, ?u},
          {:alt, ?8},
          {:alt, ?\\},
          {:alt, ?l},
          {:char, "x"},
          {:char, "("},
          {:key, :enter},
          {:key, :backspace}
        ] do
      {key, paint} = fast(state, at, event)
      # Alt+\\ may read its whole 200,000-character budget (ADR-0052 §4): ~30 ms here, 60 ms on
      # CI's runner, 0.9 s before BUG-12's fix. Every other key reads a window.
      bound = if event == {:alt, ?\\}, do: 250, else: 50
      assert key < bound, "#{inspect(event)}: key #{key} ms"
      assert paint < 100, "#{inspect(event)}: repaint #{paint} ms"
    end
  end

  test "a quote typed near the end of a 2 MB line full of strings", %{dir: dir} do
    # A minified line: strings everywhere, so deciding whether a quote opens one reads them all.
    line = String.duplicate(~s|{"k":"v\\"w",'x':1} |, 100_000)
    {state, buf} = open(dir, line)
    at = {1, String.length(line)}
    {key, _paint} = fast(state, at, {:char, "\""})
    assert key < 50, "#{key} ms"
    # Outside any string at the line's end: the quote got its closer.
    assert Buffer.get_text(buf) |> String.split("\n") |> Enum.at(1) |> String.ends_with?(~s|""|)
  end

  # A frame and a typed key and its frame, the best of five, on a 1,000-line file of `line`.
  defp file_cost(dir, name, line) do
    path = Path.join(dir, name)
    File.write!(path, Enum.map_join(1..1000, "\n", &"#{&1} #{line}") <> "\n")
    {:ok, pid} = Session.open_file(path)
    state = %{Loop.new_state(100, 30) | tree_shown: false, edits_shown: false}
    {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
    Session.set_cursor({500, 20})
    {:noreply, state} = Loop.handle_info(:repaint, state)
    best = fn f -> for(_ <- 1..5, do: elem(:timer.tc(f), 0)) |> Enum.min() |> div(1000) end
    frame = best.(fn -> Loop.handle_info(:repaint, state) end)

    key =
      best.(fn ->
        Session.set_cursor({500, 20})
        {:noreply, after_key} = Loop.handle_info({:geex_io, {:char, "x"}}, state)
        Loop.handle_info(:repaint, after_key)
      end)

    {frame, key}
  end

  test "non-ASCII files cost what an ASCII one does: French, Japanese", %{dir: dir} do
    # mod-verify's review of the first cut: a frame of a French or Japanese 1,000-line file took
    # 0.5–0.7 s (a byte pattern compiled on every call, twice a character).
    {ascii_frame, ascii_key} =
      file_cost(dir, "a.txt", "the quick brown fox jumps over the lazy dog again and again")

    for {name, line} <- [
          {"fr.txt", "Le cœur a ses raisons que la raison ne connaît point, déjà vu"},
          {"ja.txt", "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。"}
        ] do
      {frame, key} = file_cost(dir, name, line)
      assert frame < max(30, 5 * ascii_frame), "#{name}: frame #{frame} ms (ASCII #{ascii_frame})"
      assert key < max(30, 5 * ascii_key), "#{name}: key #{key} ms (ASCII #{ascii_key})"
    end
  end

  test "a long non-ASCII line is measured in well under a second" do
    for line <- [String.duplicate("aé", 500_000), String.duplicate("日", 600_000)] do
      {us, _} = :timer.tc(fn -> Geex.Width.line(line, 2) end)
      assert div(us, 1000) < 1000, "#{byte_size(line)} bytes: #{div(us, 1000)} ms"
    end
  end
end
