defmodule Geex.Loop.TreeLinksTest do
  # BUG-24 and BUG-25 through the loop's own handle_info/2: a symlinked folder shows as a folder
  # marked ↗, is listed when it is opened (in a process of its own), and is listed again after a
  # reload while open; a dot folder is in the tree. The global Session and Renderer, so not async.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Geex.{Loop, Screen, Session}

  setup do
    base = Path.join(System.tmp_dir!(), "geex_tree_links_#{Geex.Fixtures.uniq()}")
    root = Path.join(base, "root")
    elsewhere = Path.join(base, "elsewhere")
    File.mkdir_p!(Path.join(root, ".config"))
    File.mkdir_p!(elsewhere)
    File.write!(Path.join(root, "a.txt"), "a\n")
    File.write!(Path.join(root, ".config/app.toml"), "x = 1\n")
    File.write!(Path.join(elsewhere, "inside.txt"), "i\n")
    File.mkdir_p!(Path.join(elsewhere, "sub"))
    File.write!(Path.join(elsewhere, "sub/deep.txt"), "d\n")
    File.ln_s!(elsewhere, Path.join(root, "linked"))
    Session.set_start(root)

    on_exit(fn ->
      Session.set_active_buffer(nil)
      File.rm_rf(base)
    end)

    %{root: root, elsewhere: elsewhere}
  end

  defp key(state, event) do
    {:noreply, state} = Loop.handle_info({:geex_io, event}, state)
    state
  end

  defp tree_read(state) do
    assert_receive {:geex_tree, _pid, _answer} = msg, 5_000
    {:noreply, state} = Loop.handle_info(msg, state)
    state
  end

  defp link_listed(state, path \\ "linked") do
    assert_receive {:geex_tree_link, _pid, ^path, _level} = msg, 5_000
    {:noreply, state} = Loop.handle_info(msg, state)
    state
  end

  defp selected(state), do: Enum.at(state.tree.rows, state.tree.sel).path

  defp in_tree do
    state = %{Loop.new_state(120, 30) | focus: :tree}
    {:noreply, state} = Loop.handle_info({:geex_tree_changed, nil}, put_in(state.tree.index, %{}))
    tree_read(state)
  end

  defp paths(state), do: Enum.map(state.tree.rows, & &1.path)

  defp select(state, path) do
    i = Enum.find_index(state.tree.rows, &(&1.path == path))
    put_in(state.tree.sel, i)
  end

  test "a dot folder is in the tree; a linked folder is a folder, listed only once opened" do
    state = in_tree()
    assert ".config" in paths(state)

    assert %{dir?: true, link?: true, open?: false} =
             Enum.find(state.tree.rows, &(&1.path == "linked"))

    # Nothing under it is listed yet.
    refute Enum.any?(paths(state), &String.starts_with?(&1, "linked/"))

    state = state |> select("linked") |> key({:key, :enter})
    # Open, and its listing on the way: no rows under it until the answer.
    assert map_size(state.tree.links) == 1
    state = link_listed(state)
    assert "linked/inside.txt" in paths(state)
    assert state.tree.links == %{}
    # Listed, it is still marked a link.
    assert %{link?: true, open?: true} = Enum.find(state.tree.rows, &(&1.path == "linked"))
    # Closed and opened again, it is listed again (what it holds may have changed: review N1),
    # its rows on screen meanwhile.
    state = state |> key({:key, :enter}) |> key({:key, :enter})
    assert map_size(state.tree.links) == 1
    assert "linked/inside.txt" in paths(state)
    state = link_listed(state)
    assert "linked/inside.txt" in paths(state)
  end

  test "a reload while it's open lists it again", %{root: root} do
    state = in_tree() |> select("linked") |> key({:key, :enter}) |> link_listed()
    assert "linked/inside.txt" in paths(state)

    {:noreply, state} = Loop.handle_info({:geex_tree_changed, root}, state)
    state = state |> tree_read() |> link_listed()
    assert "linked/inside.txt" in paths(state)
  end

  test "the painted tree marks a linked folder with ↗" do
    state = in_tree()
    {:noreply, _} = Loop.handle_info(:repaint, state)
    screen = Geex.Renderer.current()

    rows =
      for y <- 0..(screen.h - 1),
          do: Enum.map_join(0..(screen.w - 1), &Screen.get_cell(screen, &1, y).char)

    assert Enum.any?(rows, &(&1 =~ "linked/ ↗"))
    assert Enum.any?(rows, &(&1 =~ ".config/"))
  end

  # The maintainer's choice after the review: a linked folder is listed one level at a time.
  test "one level at a time: a folder inside a link is listed when it is opened" do
    state = in_tree() |> select("linked") |> key({:key, :enter}) |> link_listed()
    assert "linked/sub" in paths(state)
    refute "linked/sub/deep.txt" in paths(state)
    assert %{dir?: true, link?: false} = Enum.find(state.tree.rows, &(&1.path == "linked/sub"))

    state = state |> select("linked/sub") |> key({:key, :enter}) |> link_listed("linked/sub")
    assert "linked/sub/deep.txt" in paths(state)
  end

  # Review F1: a folder made inside a linked folder broke every later read of the tree.
  test "a folder made inside a linked folder, then a reload: the tree still reads", ctx do
    state = in_tree()
    File.mkdir_p!(Path.join(ctx.elsewhere, "newdir"))
    state = put_in(state.tree.made, MapSet.new(["linked/newdir", "linked/a/b"]))
    {:noreply, state} = Loop.handle_info({:geex_tree_changed, ctx.root}, state)
    File.write!(Path.join(ctx.root, "c.txt"), "c\n")
    state = tree_read(state)
    assert "c.txt" in paths(state)
    refute (state.notice || "") =~ "couldn't"
  end

  # Review F2: a reload kept neither the open link's rows nor the highlight on them.
  test "a reload keeps an open linked folder's rows and the highlight, then lists it again",
       ctx do
    state =
      in_tree()
      |> select("linked")
      |> key({:key, :enter})
      |> link_listed()
      |> select("linked/inside.txt")

    File.write!(Path.join(ctx.root, "b.txt"), "b\n")
    {:noreply, state} = Loop.handle_info({:geex_tree_changed, ctx.root}, state)
    state = tree_read(state)
    # Before the new listing lands: still there, still highlighted.
    assert "linked/inside.txt" in paths(state)
    assert selected(state) == "linked/inside.txt"
    state = link_listed(state)
    assert selected(state) == "linked/inside.txt"
    assert "b.txt" in paths(state)
  end

  test "a file made inside an open linked folder is highlighted once it shows", ctx do
    state = in_tree() |> select("linked") |> key({:key, :enter}) |> link_listed()
    File.write!(Path.join(ctx.elsewhere, "fresh.txt"), "f\n")
    state = put_in(state.tree.want, "linked/fresh.txt")
    {:noreply, state} = Loop.handle_info({:geex_tree_changed, ctx.root}, state)
    state = state |> tree_read() |> link_listed()
    assert selected(state) == "linked/fresh.txt"
    assert state.tree.want == nil
  end

  # Review N1: a closed linked folder, reopened after a reload, showed what it held before.
  test "reopening a closed linked folder lists it again", ctx do
    state = in_tree() |> select("linked") |> key({:key, :enter}) |> link_listed()
    state = state |> select("linked") |> key({:key, :enter})
    File.write!(Path.join(ctx.elsewhere, "added_later.txt"), "a\n")
    File.write!(Path.join(ctx.root, "b.txt"), "b\n")
    {:noreply, state} = Loop.handle_info({:geex_tree_changed, ctx.root}, state)
    state = state |> tree_read() |> select("linked") |> key({:key, :enter}) |> link_listed()
    assert "linked/added_later.txt" in paths(state)
  end

  # Review note: a folder made inside an open linked folder waited for some other reload.
  test "a file operation inside an open linked folder shows at once", ctx do
    state = in_tree() |> select("linked") |> key({:key, :enter}) |> link_listed()
    solo = Path.join(ctx.elsewhere, "solo")
    File.mkdir_p!(solo)
    op = spawn(fn -> :ok end)
    state = %{state | file_ops: Map.put(state.file_ops, op, make_ref())}

    {:noreply, state} =
      Loop.handle_info(
        {:geex_file_op, op, {:made_dir, Path.join(ctx.root, "linked/solo"), "made"}},
        state
      )

    state = link_listed(state)
    assert "linked/solo" in paths(state)
  end
end
