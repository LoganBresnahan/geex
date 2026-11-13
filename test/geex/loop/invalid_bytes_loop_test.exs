defmodule Geex.Loop.InvalidBytesLoopTest do
  # BUG-15 through the loop's own handle_info/2: random keys, typing, clicks and undo on a file
  # holding bytes that aren't UTF-8, an emoji often right before one (where OTP's segmentation
  # raises), a frame drawn after each. Nothing raises: an invalid byte is a grapheme of its own
  # everywhere the editor addresses or draws text. Uses the global Session, so not async.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Geex.{Loop, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_invalid_loop_#{Geex.Fixtures.uniq()}")
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

  defp bad, do: member_of([<<0xE9>>, <<0xFF>>, <<0xC3>>, <<0x80>>, <<0xFE, 0xFF>>])

  defp piece do
    frequency([
      {3, member_of(["a", "bc", " ", "(", ")", "[x]", "é", "日", "\t", "é", "// c"])},
      {2, bad()},
      # An extended pictographic right before an invalid byte: © ™ ☀ ↔, an emoji.
      {2, map({member_of(["©", "™", "☀", "↔", "👍", "👍🏽"]), bad()}, fn {e, b} -> e <> b end)}
    ])
  end

  defp text do
    gen all(
          lines <-
            list_of(map(list_of(piece(), max_length: 8), &Enum.join/1),
              min_length: 1,
              max_length: 4
            )
        ) do
      Enum.join(lines, "\n") <> "\n"
    end
  end

  defp event do
    one_of([
      member_of(
        for(c <- ~c"ijkluoh;78923\\/zZIJKLUOH:sa", do: {:alt, c}) ++
          [
            {:alt, ?\\},
            {:key, :backspace},
            {:key, :delete},
            {:key, :enter},
            {:key, :tab},
            {:key, :shift_tab},
            {:key, :home},
            {:key, :end},
            {:key, :esc}
          ]
      ),
      map(member_of(["x", "(", "\"", "é", "👍", " "]), &{:char, &1}),
      map({integer(0..60), integer(0..6)}, fn {x, y} ->
        {:mouse, %{action: :press, button: :left, x: x, y: y, mods: []}}
      end)
    ])
  end

  defp frame(state) do
    {:noreply, state} = Loop.handle_info(:repaint, state)
    state
  end

  # Each run opens a buffer and draws a frame per event: a deep run (GEEX_PROPERTY_RUNS=10000)
  # takes a few minutes, past ExUnit's 60 s default.
  @tag timeout: 900_000
  property "keys, typing, clicks and undo on text with invalid bytes never raise", %{dir: dir} do
    check all(
            text <- text(),
            events <- list_of(event(), min_length: 1, max_length: 25)
          ) do
      path = Path.join(dir, "f#{System.unique_integer([:positive])}.txt")
      File.write!(path, text)
      {:ok, pid} = Session.open_file(path)
      state = %{Loop.new_state(60, 8) | tree_shown: false, edits_shown: false}
      {:noreply, state} = Loop.handle_info({:geex_active_buffer, pid}, state)
      state = frame(state)

      Enum.reduce(events, state, fn event, state ->
        {:noreply, state} = Loop.handle_info({:geex_io, event}, %{state | click: nil})
        frame(state)
      end)

      DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
    end
  end
end
