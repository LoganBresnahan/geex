defmodule Geex.Buffer.SyncedTest do
  # The buffer's one new message for the markdown preview (ADR-0043 §2): wherever its synced
  # baseline moves, subscribers get `{:geex_buffer_synced, buffer, sha256}`, and `status/1`
  # reports the synced text's hash.
  use ExUnit.Case, async: true

  alias Geex.Buffer

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_synced_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "a.md")
    File.write!(path, "a\n")
    buf = start_supervised!({Buffer, path: path})
    {:ok, _} = Buffer.subscribe(buf, self())
    %{buf: buf, path: path}
  end

  defp sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp insert(line, col, text) do
    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: line, col: col, text: text})
    Geex.Command.put_meta(cmd, Geex.Command.Meta.human())
  end

  defp replace_all(old, new) do
    lines = String.split(old, "\n")

    {:ok, cmd} =
      Geex.Commands.Replace.parse(%{
        start_line: 0,
        start_col: 0,
        end_line: length(lines) - 1,
        end_col: String.length(List.last(lines)),
        text: new
      })

    Geex.Command.put_meta(cmd, Geex.Command.Meta.new(:external, []))
  end

  test "status/1 gives the synced text's sha256", %{buf: buf} do
    assert Buffer.status(buf).synced == sha("a\n")
    {:ok, _} = Buffer.dispatch(buf, insert(0, 1, "b"))
    assert Buffer.status(buf).synced == sha("a\n")
  end

  test "a save says so, with the hash of what it wrote", %{buf: buf} do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 1, "b"))
    {:ok, _} = Buffer.save(buf)
    assert_receive {:geex_buffer_synced, ^buf, sha}
    assert sha == sha("ab\n")
    assert Buffer.status(buf).synced == sha
  end

  test "mark_synced/1 says so", %{buf: buf} do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 1, "c"))
    Buffer.mark_synced(buf)
    assert_receive {:geex_buffer_synced, ^buf, sha}
    assert sha == sha("ac\n")
  end

  test "F15: a fast-forward says so, even one the watcher never reported", %{buf: buf, path: path} do
    # An agent writes the file and a fast-forward takes it in before any disk_changed.
    File.write!(path, "agent\n")
    {:ok, _} = Buffer.dispatch_group(buf, [replace_all("a\n", "agent\n")], baseline: "agent\n")
    assert_receive {:geex_buffer_synced, ^buf, sha}
    assert sha == sha("agent\n")

    # A fast-forward with nothing to take in (the disk is what the buffer holds) moves the
    # baseline too.
    {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "x"))
    File.write!(path, "xagent\n")
    {:ok, _} = Buffer.dispatch_group(buf, [], baseline: "xagent\n")
    assert_receive {:geex_buffer_synced, ^buf, sha}
    assert sha == sha("xagent\n")
  end

  test "an edit, an undo or the disk moving ahead sends none", %{buf: buf} do
    {:ok, _} = Buffer.dispatch(buf, insert(0, 1, "b"))
    {:ok, _, _} = Buffer.undo(buf)
    Buffer.disk_changed(buf, "other\n")
    assert_receive {:geex_buffer_behind, ^buf, %{}}
    refute_received {:geex_buffer_synced, _, _}
  end
end
