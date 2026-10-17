defmodule Geex.BuffersTest do
  # More than one buffer (ADR-0034 build step 2): the recent list, a cursor per buffer,
  # `close_active/0`, and the verbs. Drives the application-global Geex.Session.
  use ExUnit.Case, async: false

  alias Geex.{Buffer, Command, Session}
  alias Geex.Command.{Catalog, Meta}
  alias Geex.Commands.Insert
  alias Geex.Loop.Verbs

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_buffers_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Session.set_active_buffer(nil)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp file(ctx, name, text) do
    path = Path.join(ctx.dir, name)
    File.write!(path, text)
    path
  end

  defp open!(path) do
    {:ok, pid} = Session.open_file(path)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
    end)

    pid
  end

  # The recent list, limited to these buffers (other tests' buffers may still be listed).
  defp recent(pids), do: for(%{pid: pid} <- Session.buffers(), pid in pids, do: pid)

  test "the recent list leads with the active buffer and follows each switch", ctx do
    a = open!(file(ctx, "a.txt", "a\n"))
    b = open!(file(ctx, "b.txt", "b\n"))
    assert recent([a, b]) == [b, a]

    Session.set_active_buffer(a)
    assert recent([a, b]) == [a, b]
    assert [%{pid: ^a, path: path, dirty: false} | _] = Session.buffers()
    assert path == Path.join(ctx.dir, "a.txt")
  end

  test "each buffer keeps its own cursor across switches", ctx do
    a = open!(file(ctx, "a.txt", "one\ntwo\nthree\n"))
    Session.set_cursor({2, 3})
    b = open!(file(ctx, "b.txt", "x\n"))
    assert {:ok, %{cursor: {0, 0}}} = Session.snapshot()

    Session.set_cursor({0, 1})
    Session.set_active_buffer(a)
    assert {:ok, %{cursor: {2, 3}}} = Session.snapshot()
    Session.set_active_buffer(b)
    assert {:ok, %{cursor: {0, 1}}} = Session.snapshot()
  end

  test "close_active/0 refuses unsaved edits, then goes back to the previous buffer", ctx do
    a = open!(file(ctx, "a.txt", "a\n"))
    b = open!(file(ctx, "b.txt", "b\n"))
    {:ok, cmd} = Insert.parse(%{line: 0, col: 0, text: "x"})
    {:ok, _} = Buffer.dispatch(b, Command.put_meta(cmd, Meta.human()))

    assert Session.close_active() == {:error, :dirty}
    assert Session.active_buffer() == {:ok, b}

    {:ok, _} = Buffer.save(b)
    assert {:ok, label} = Session.close_active()
    assert label == Path.join(ctx.dir, "b.txt")
    refute Process.alive?(b)
    assert Session.active_buffer() == {:ok, a}
    assert recent([a, b]) == [a]
  end

  test "closing the last buffer leaves an empty scratch buffer, not nothing", ctx do
    Session.set_active_buffer(nil)
    a = open!(file(ctx, "only.txt", "a\n"))

    # close everything else this session knows of first, so `a` is the last
    for %{pid: pid} <- Session.buffers(), pid != a do
      DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
    end

    :sys.get_state(Session)
    assert {:ok, _} = Session.close_active()
    assert {:ok, scratch} = Session.active_buffer()
    refute scratch == a
    assert %{path: nil, text: ""} = Buffer.snapshot(scratch)
    DynamicSupervisor.terminate_child(Geex.BufferSupervisor, scratch)
  end

  test "a buffer that ends drops out of the list", ctx do
    a = open!(file(ctx, "a.txt", "a\n"))
    b = open!(file(ctx, "b.txt", "b\n"))
    DynamicSupervisor.terminate_child(Geex.BufferSupervisor, a)
    :sys.get_state(Session)
    assert recent([a, b]) == [b]
  end

  test "set_start/1: the directory named, or a file's; its git top level as the root", ctx do
    nested = Path.join(ctx.dir, "sub")
    File.mkdir_p!(nested)
    assert %{dir: ^nested, root: ^nested} = Session.set_start(nested)
    assert Session.start() == %{dir: nested, root: nested}

    # inside this checkout: the root is its top level
    me = Path.expand("../..", __DIR__)
    assert %{dir: dir, root: ^me} = Session.set_start(Path.join(me, "lib/geex.ex"))
    assert dir == Path.join(me, "lib")
  end

  describe "the verbs" do
    test "`open PATH` keeps the path's case; `buffers`, `close`" do
      assert Verbs.parse("open lib/Geex/Foo.ex") == {:open, "lib/Geex/Foo.ex"}
      assert Verbs.parse("  OPEN   ~/My File.txt ") == {:open, "~/My File.txt"}
      # `open` alone and `find` are the file finder (Alt+O, ADR-0037)
      assert Verbs.parse("open") == {:action, :find_file}
      assert Verbs.parse("find") == {:action, :find_file}
      assert Verbs.parse("buffers") == {:action, :buffers}
      assert Verbs.parse("close") == {:action, :close}
      assert Verbs.parse("edits") == {:action, :toggle_edits}
      # not swallowed by the `open` rule
      assert Verbs.parse("line 3") == {:line, 3}
    end

    test "the palette lists them" do
      by_name = Map.new(Catalog.all(), &{&1.name, &1.invoke})
      assert by_name["open"] == {:action, :find_file}
      assert by_name["buffers"] == {:action, :buffers}
      assert by_name["close"] == {:action, :close}
      assert by_name["edits"] == {:action, :toggle_edits}
    end
  end
end
