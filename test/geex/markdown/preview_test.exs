defmodule Geex.Markdown.PreviewTest do
  # The markdown preview's process (ADR-0043 §2, §3), with no UI: one per buffer, rendering the
  # file on disk off the key loop. Each `describe` is one of the review's failure cases
  # (doc/research/adr-0043-review.md, F11–F17, F19).
  use ExUnit.Case, async: true

  alias Geex.Buffer
  alias Geex.Markdown.Preview

  doctest Preview

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_preview_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "a.md")
    File.write!(path, "# One\n\nfirst\n")
    buf = start_supervised!({Buffer, path: path})
    %{buf: buf, path: path, dir: dir}
  end

  defp insert(line, col, text) do
    {:ok, cmd} = Geex.Commands.Insert.parse(%{line: line, col: col, text: text})
    Geex.Command.put_meta(cmd, Geex.Command.Meta.human())
  end

  defp texts(%{rows: rows}), do: Enum.map(rows, &text/1)
  defp text(row), do: row.runs |> Enum.map_join(fn {t, _} -> t end) |> String.trim_trailing()

  # The next render message for `buf`, with rows at `width`.
  defp render(buf, width) do
    assert_receive {:geex_preview, ^buf, %{rows: %{^width => _}} = r}, 2_000
    r
  end

  defp open(buf, width, opts \\ []) do
    {:ok, pid} = start_preview(buf, opts)
    :ok = Preview.subscribe(pid, self())
    Preview.widths(pid, [width])
    {pid, render(buf, width)}
  end

  defp start_preview(buf, opts),
    do: start_supervised({Preview, Keyword.merge([buffer: buf], opts)}, id: make_ref())

  test "it renders the file at each width it is asked for, with each row's source line", ctx do
    {pid, r} = open(ctx.buf, 40)
    assert hd(texts(r.rows[40])) == "One"
    assert r.status == :ok
    assert r.rows[40].lines == Geex.Markdown.Place.lines(r.rows[40].rows, "# One\n\nfirst\n")

    Preview.widths(pid, [40, 12])
    r = render(ctx.buf, 12)
    assert Enum.all?(r.rows[12].rows, &(Geex.Markdown.Layout.runs_width(&1.runs) <= 12))
  end

  describe "F12: owned by a supervisor, registered per buffer, gone with its buffer or subscribers" do
    test "attach/2 starts one under PreviewSupervisor, idempotently", ctx do
      {:ok, pid} = Preview.attach(ctx.buf, self())
      assert {:ok, ^pid} = Preview.attach(ctx.buf, self())
      assert {:ok, ^pid} = Preview.lookup(ctx.buf)

      assert pid in for(
               {_, p, _, _} <- DynamicSupervisor.which_children(Geex.Markdown.PreviewSupervisor),
               do: p
             )

      ref = Process.monitor(pid)
      Preview.unsubscribe(pid, self())
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Preview.lookup(ctx.buf) == :error
    end

    test "it unregisters and stops when its last subscriber dies", ctx do
      sub = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, pid} = Preview.attach(ctx.buf, sub)
      ref = Process.monitor(pid)
      send(sub, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Preview.lookup(ctx.buf) == :error
    end

    test "it unregisters and stops when its buffer ends", ctx do
      {:ok, pid} = Preview.attach(ctx.buf, self())
      ref = Process.monitor(pid)
      stop_supervised!(Buffer)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Preview.lookup(ctx.buf) == :error
    end

    test "a render under way stops with the preview: no orphan worker", ctx do
      test = self()

      read = fn path ->
        send(test, {:reading, self()})
        receive do: (:go -> File.read(path))
      end

      {:ok, pid} = start_preview(ctx.buf, read: read)
      :ok = Preview.subscribe(pid, self())
      Preview.widths(pid, [30])
      assert_receive {:reading, worker}
      wref = Process.monitor(worker)
      Preview.unsubscribe(pid, self())
      assert_receive {:DOWN, ^wref, :process, ^worker, _}
    end

    test "and when its supervisor shuts it down", ctx do
      test = self()

      read = fn path ->
        send(test, {:reading, self()})
        receive do: (:go -> File.read(path))
      end

      {:ok, _pid} =
        start_supervised({Preview, buffer: ctx.buf, read: read}, id: :shut_down_preview)

      {:ok, pid} = Preview.lookup(ctx.buf)
      :ok = Preview.subscribe(pid, self())
      Preview.widths(pid, [30])
      assert_receive {:reading, worker}
      wref = Process.monitor(worker)
      stop_supervised!(:shut_down_preview)
      assert_receive {:DOWN, ^wref, :process, ^worker, _}
    end

    test "its init reads nothing, and a crashed render costs a frame, not the process", ctx do
      test = self()
      read = fn path -> send(test, {:read, path}) && File.read(path) end
      {:ok, pid} = start_preview(ctx.buf, read: read)
      refute_receive {:read, _}, 100

      :ok = Preview.subscribe(pid, self())
      Preview.widths(pid, [30])
      assert_receive {:read, _}
      _ = render(ctx.buf, 30)

      boom = fn _path -> raise "boom" end
      :sys.replace_state(pid, &%{&1 | read: boom})
      Preview.reread(pid)
      assert_receive {:geex_preview, buf, %{status: {:failed, _}, rows: rows}}
      assert buf == ctx.buf and rows == %{}
      assert Process.alive?(pid)
    end
  end

  describe "F13: pending work merges; a width change never replaces a pending re-read" do
    test "a re-read and a new width that arrive mid-render both run", ctx do
      test = self()

      # A read takes the file's bytes, then waits: the render is still running when the save and
      # the width arrive.
      read = fn path ->
        bytes = File.read(path)
        send(test, {:reading, self()})
        receive do: (:go -> bytes)
      end

      {:ok, pid} = start_preview(ctx.buf, read: read)
      :ok = Preview.subscribe(pid, self())
      Preview.widths(pid, [40])
      assert_receive {:reading, worker}

      # While the first render reads, the file is saved with new text, and a width arrives.
      {:ok, _} = Buffer.dispatch(ctx.buf, insert(2, 5, " more"))
      {:ok, _} = Buffer.save(ctx.buf)
      Preview.widths(pid, [40, 20])
      send(worker, :go)
      first = render(ctx.buf, 40)
      assert "first" in texts(first.rows[40])

      assert_receive {:reading, worker2}
      send(worker2, :go)
      r = render(ctx.buf, 20)
      assert "first more" in texts(r.rows[40])
      assert Map.has_key?(r.rows, 20)
    end
  end

  describe "F11: a file that isn't on disk" do
    test "draws no rows and says why; the next synced message reads again", ctx do
      path = Path.join(ctx.dir, "new.md")
      buf = start_supervised!({Buffer, path: path}, id: :new_buf)
      {_pid, r} = open(buf, 30)
      assert r.status == {:read, :enoent}
      assert r.rows[30].rows == []
      assert Preview.describe(r.status) == "not on disk"

      {:ok, _} = Buffer.dispatch(buf, insert(0, 0, "# Saved\n"))
      {:ok, _} = Buffer.save(buf)
      r = render(buf, 30)
      assert r.status == :ok
      assert hd(texts(r.rows[30])) == "Saved"
    end
  end

  describe "F15/F16: what triggers a read, and a read caught mid-write" do
    test "the disk moving ahead renders the agent's version before it is taken in", ctx do
      {_pid, _r} = open(ctx.buf, 30)
      File.write!(ctx.path, "# Agent\n")
      Buffer.disk_changed(ctx.buf, "# Agent\n")
      r = render(ctx.buf, 30)
      assert hd(texts(r.rows[30])) == "Agent"
    end

    test "a read whose hash isn't the buffer's is read again, and drawn as changing after three",
         ctx do
      test = self()
      # Every read returns bytes the buffer never gave a hash for.
      read = fn _path -> send(test, :read) && {:ok, "# Half writ"} end
      {_pid, r} = open(ctx.buf, 30, read: read, settle_ms: 5)
      assert_received :read
      assert_received :read
      assert_received :read
      assert r.status == :changing
      assert hd(texts(r.rows[30])) == "Half writ"
      assert Preview.describe(:changing) == "changing"
    end

    test "a synced message for the text it last rendered reads, but renders nothing new", ctx do
      {pid, _r} = open(ctx.buf, 30)
      send(pid, {:geex_buffer_synced, ctx.buf, Buffer.status(ctx.buf).synced})
      refute_receive {:geex_preview, _, _}, 200
      # Every keystroke's change message is ignored.
      {:ok, _} = Buffer.dispatch(ctx.buf, insert(0, 0, "x"))
      refute_receive {:geex_preview, _, _}, 200
    end
  end

  describe "the slice-4 review" do
    test "refresh/1 parses again with the same bytes (an install of a grammar it uses)", ctx do
      {pid, r} = open(ctx.buf, 30)
      Preview.reread(pid)
      refute_receive {:geex_preview, _, _}, 200
      Preview.refresh(pid)
      r2 = render(ctx.buf, 30)
      assert r2.render > r.render
      assert r2.hash == r.hash
    end

    test "a width with no parse to lay out reads again, rather than crashing", ctx do
      path = Path.join(ctx.dir, "missing.md")
      buf = start_supervised!({Buffer, path: path}, id: :missing_buf)
      {pid, r} = open(buf, 30)
      assert r.status == {:read, :enoent}
      Preview.widths(pid, [30, 20])
      r = render(buf, 20)
      assert r.status == {:read, :enoent}
    end

    test "changing clears once the buffer's hash catches up with the bytes drawn", ctx do
      read = fn _path -> {:ok, "# Half writ"} end
      {_pid, r} = open(ctx.buf, 30, read: read, settle_ms: 5)
      assert r.status == :changing

      # The buffer now holds those bytes and calls them synced: the same read is fine now.
      text = Buffer.get_text(ctx.buf)
      lines = String.split(text, "\n")

      {:ok, cmd} =
        Geex.Commands.Replace.parse(%{
          start_line: 0,
          start_col: 0,
          end_line: length(lines) - 1,
          end_col: String.length(List.last(lines)),
          text: "# Half writ"
        })

      {:ok, _} = Buffer.dispatch(ctx.buf, Geex.Command.put_meta(cmd, Geex.Command.Meta.human()))
      Buffer.mark_synced(ctx.buf)
      assert_receive {:geex_preview, buf, %{status: :ok, rows: rows}}, 2_000
      assert buf == ctx.buf and rows == %{}
    end

    test "slice 5 review 1: a width change keeps the status it had (changing)", ctx do
      read = fn _path -> {:ok, "# Half writ"} end
      {pid, r} = open(ctx.buf, 30, read: read, settle_ms: 5)
      assert r.status == :changing
      Preview.widths(pid, [30, 20])
      r = render(ctx.buf, 20)
      assert r.status == :changing
    end

    test "each render says which text it is and which its line map starts from", ctx do
      {_pid, r} = open(ctx.buf, 30)
      assert r.hash == Buffer.status(ctx.buf).synced
      assert r.from == nil
      {:ok, _} = Buffer.dispatch(ctx.buf, insert(0, 0, "intro\n\n"))
      {:ok, _} = Buffer.save(ctx.buf)
      r2 = render(ctx.buf, 30)
      assert r2.from == r.hash and r2.hash == Buffer.status(ctx.buf).synced
    end
  end

  describe "F17: the user's save scrolls to their cursor line" do
    test "the anchor the loop sends rides on the next render", ctx do
      {pid, r} = open(ctx.buf, 30)
      assert r.anchor == nil
      {:ok, _} = Buffer.dispatch(ctx.buf, insert(2, 5, "!"))
      {:ok, _} = Buffer.save(ctx.buf)
      Preview.saved(pid, 2)
      # The save's own render may come first; the anchor rides on a render started after it.
      r =
        Stream.repeatedly(fn -> render(ctx.buf, 30) end)
        |> Enum.find(&(&1.anchor != nil))

      assert r.anchor == 2
    end
  end

  describe "F19 and the remap: renames, and edits above the reader" do
    test "after a rename it reads the new path", ctx do
      {pid, _r} = open(ctx.buf, 30)
      new_path = Path.join(ctx.dir, "b.md")
      File.write!(new_path, "# Renamed\n")
      :ok = Buffer.rename(ctx.buf, new_path)
      Buffer.mark_synced(ctx.buf)
      Preview.reread(pid)

      r =
        Stream.repeatedly(fn -> render(ctx.buf, 30) end)
        |> Enum.find(&(hd(texts(&1.rows[30])) == "Renamed"))

      assert r.status in [:ok, :changing]
    end

    test "a re-render carries the old→new line map", ctx do
      {_pid, _r} = open(ctx.buf, 30)
      {:ok, _} = Buffer.dispatch(ctx.buf, insert(0, 0, "intro\n\n"))
      {:ok, _} = Buffer.save(ctx.buf)
      r = render(ctx.buf, 30)
      # "# One" was line 0 and is line 2 now; "first" was 2 and is 4.
      assert elem(r.remap, 0) == 2 and elem(r.remap, 2) == 4
    end
  end
end
