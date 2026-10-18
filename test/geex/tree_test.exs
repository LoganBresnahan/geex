defmodule Geex.TreeTest do
  # The file tree's content (ADR-0034 build step 4): what git lists, a walk outside a
  # repository, and the rows for the open directories.
  use ExUnit.Case, async: true
  doctest Geex.Tree

  alias Geex.Tree

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_tree_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp put(dir, path, text \\ "x\n") do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, text)
  end

  defp git(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  test "outside a repository: a walk that skips dot-directories", %{dir: dir} do
    put(dir, "b.txt")
    put(dir, "lib/a.ex")
    put(dir, ".hidden/secret")
    put(dir, ".env")

    assert Tree.list(dir) == [".env", "b.txt", "lib/a.ex"]
  end

  test "in a work tree: what git lists — tracked, untracked, not ignored, not deleted",
       %{dir: dir} do
    git(dir, ["init", "-q"])
    put(dir, ".gitignore", "build/\n")
    put(dir, "tracked.ex")
    put(dir, "gone.ex")
    git(dir, ["add", "."])
    git(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "t"])
    put(dir, "new.ex")
    put(dir, "build/out.bin")
    File.rm!(Path.join(dir, "gone.ex"))

    assert Tree.list(dir) == [".gitignore", "new.ex", "tracked.ex"]
  end

  # Writes 10,000 files and runs git over them: on a heavily loaded machine that took past
  # ExUnit's 60 s limit for a test.
  @tag timeout: 300_000
  test "no cap: past 10,000 files, the walk and git list them all", %{dir: dir} do
    # Found live by the coordinator: the old cap cut the list without saying so (untracked files
    # first, since git lists them last). Logan's call (2026-10-16): no cap at all.
    for d <- 1..11 do
      File.mkdir_p!(Path.join(dir, "d#{d}"))
      for f <- 1..1000, do: File.write!(Path.join(dir, "d#{d}/f#{f}"), "")
    end

    assert length(Tree.list(dir)) == 11_000
    git(dir, ["init", "-q"])
    files = Tree.list(dir)
    assert length(files) == 11_000

    index = Tree.index(files)
    assert map_size(index) == 11 and map_size(index["d7"]) == 1000
  end

  test "rows: directories first, alphabetical, opened ones expanded, depth for indent" do
    index = Tree.index(["z.txt", "a/x.ex", "a/b/y.ex", "c/w.ex"])

    assert Tree.rows(index, MapSet.new()) |> Enum.map(& &1.path) == ["a", "c", "z.txt"]

    rows = Tree.rows(index, MapSet.new(["a", "a/b"]))

    assert Enum.map(rows, &{&1.path, &1.depth}) ==
             [{"a", 0}, {"a/b", 1}, {"a/b/y.ex", 2}, {"a/x.ex", 1}, {"c", 0}, {"z.txt", 0}]

    # an open directory under a closed one stays hidden
    assert Tree.rows(index, MapSet.new(["a/b"])) |> Enum.map(& &1.path) == ["a", "c", "z.txt"]
  end

  test "the layout's tree column: a quarter of the width, 20 to 36, none below 60 columns" do
    assert Geex.Layout.resolve(200, 30, %{tree: true}).tree.w == 36
    assert Geex.Layout.resolve(70, 30, %{tree: true}).tree.w == 20
    assert Geex.Layout.resolve(59, 30, %{tree: true}).tree == nil
    assert %{x: 0, w: 80} = Geex.Layout.resolve(80, 30, %{}).editor
  end

  test "Screen.translate_x moves cells right, dropping what falls off" do
    s = Geex.Screen.new(5, 1) |> Geex.Screen.draw_text(0, 0, "abcde")
    moved = Geex.Screen.translate_x(s, 2)
    assert Geex.Screen.get_cell(moved, 2, 0).char == "a"
    assert Geex.Screen.get_cell(moved, 4, 0).char == "c"
  end

  test "the `tree` verb and palette entry" do
    assert Geex.Loop.Verbs.parse("tree") == {:action, :toggle_tree}

    assert %{invoke: {:action, :toggle_tree}} =
             Enum.find(Geex.Command.Catalog.all(), &(&1.name == "tree"))
  end
end
