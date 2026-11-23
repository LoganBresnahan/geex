defmodule Geex.TreeTest do
  # The file tree's content (ADR-0034 build step 4): what git lists, a walk outside a
  # repository, and the rows for the open directories.
  use ExUnit.Case, async: true
  doctest Geex.Tree

  alias Geex.Tree

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_tree_#{Geex.Fixtures.uniq()}")
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

  # BUG-25: a dot folder is listed like any other; version control's own folders never are.
  test "outside a repository: dot folders listed, but never .git, .hg or .svn", %{dir: dir} do
    put(dir, "b.txt")
    put(dir, "lib/a.ex")
    put(dir, ".hidden/secret")
    put(dir, ".config/app/x.toml")
    put(dir, ".env")
    for vcs <- ~w(.git .hg .svn), do: put(dir, vcs <> "/inner")

    assert Tree.list(dir) == [".config/app/x.toml", ".env", ".hidden/secret", "b.txt", "lib/a.ex"]
  end

  # BUG-24: a link to a file is a file; a link to a folder is a folder not listed until opened;
  # a link that names nothing is left out. Inside a work tree and outside one alike.
  for mode <- [:walk, :git] do
    test "#{mode}: symlinks — a file, a folder (inside the root and outside it), a dangling one",
         %{dir: dir} do
      outside = Path.join(Path.dirname(dir), "outside_#{Geex.Fixtures.uniq()}")
      put(outside, "o.txt")
      on_exit(fn -> File.rm_rf(outside) end)
      put(dir, "a.txt")
      put(dir, "real/r.txt")
      File.ln_s!(Path.join(dir, "a.txt"), Path.join(dir, "link_file.txt"))
      File.ln_s!(Path.join(dir, "real"), Path.join(dir, "link_dir"))
      File.ln_s!(outside, Path.join(dir, ".aws"))
      File.ln_s!(Path.join(dir, "nowhere"), Path.join(dir, "dangling"))

      if unquote(mode) == :git do
        git(dir, ["init", "-q"])
        git(dir, ["add", "."])
        git(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "t"])
      end

      assert Tree.list_all(dir) ==
               {["a.txt", "link_file.txt", "real/r.txt"], [".aws", "link_dir"]}

      # Opened, a linked folder is listed one level: a folder in it is :dir (listed when opened),
      # a link in it a link again (never followed), a version control folder never.
      File.ln_s!(dir, Path.join(outside, "back_to_root"))
      File.mkdir_p!(Path.join(outside, "sub/deeper"))
      File.write!(Path.join(outside, "sub/deeper/far.txt"), "f")
      File.mkdir_p!(Path.join(outside, ".git"))

      assert Tree.list_level(dir, ".aws") ==
               %{"o.txt" => :file, "back_to_root" => :link, "sub" => :dir}

      assert Tree.list_level(dir, ".aws/sub") == %{"deeper" => :dir}
    end
  end

  test "the index and rows: a linked folder is a folder, its rows a level at a time", %{dir: _dir} do
    index = Tree.index(["a.txt"]) |> Tree.put_links(["docs"])
    rows = Tree.rows(index, MapSet.new(["docs"]))

    assert [%{path: "docs", dir?: true, open?: true, link?: true}, %{path: "a.txt", link?: false}] =
             rows

    assert Tree.unlisted?(index, "docs")
    listed = Tree.put_listed(index, "docs", %{"x.md" => :file, "more" => :link, "sub" => :dir})
    refute Tree.unlisted?(listed, "docs")
    assert Tree.listed_level?(listed, "docs")
    assert Tree.unlisted?(listed, "docs/sub")
    rows = Tree.rows(listed, MapSet.new(["docs", "docs/sub"]))

    assert Enum.map(rows, &{&1.path, &1.dir?, &1.link?}) ==
             [
               {"docs", true, true},
               {"docs/more", true, true},
               {"docs/sub", true, false},
               {"docs/x.md", false, false},
               {"a.txt", false, false}
             ]

    # A path not listed this way is left alone.
    assert Tree.put_listed(listed, "a.txt", %{"y" => :file}) == listed
    assert Tree.put_listed(listed, "a.txt/x", %{"y" => :file}) == listed
    assert Tree.put_listed(listed, "nowhere", %{"y" => :file}) == listed
  end

  # verifier's review, F1: a folder made inside a folder not listed yet stops there, and reads.
  test "put_dirs stops at a folder not listed yet (a link, or a folder in one)" do
    index = Tree.index(["a.txt"]) |> Tree.put_links(["linked"])
    assert Tree.put_dirs(index, ["linked/newdir", "linked/a/b"]) == index

    listed = Tree.put_listed(index, "linked", %{"sub" => :dir})
    assert Tree.put_dirs(listed, ["linked/sub/new"]) == listed
    # Inside a listed level, a made folder is put in as usual.
    assert Tree.put_dirs(listed, ["linked/made"])["linked"]["made"] == %{}
  end

  # verifier's review, F2, then N1/N2: a reload's fresh index keeps the OPEN listed levels only.
  test "carry keeps the open listed levels, along the open paths only" do
    old =
      Tree.index(["a.txt"])
      |> Tree.put_links(["linked", "closed"])
      |> Tree.put_listed("linked", %{"sub" => :dir, "f.txt" => :file})
      |> Tree.put_listed("linked/sub", %{"g.txt" => :file})
      |> Tree.put_listed("closed", %{"c.txt" => :file})

    fresh = Tree.index(["a.txt", "new.txt"]) |> Tree.put_links(["linked", "closed"])
    carried = Tree.carry(fresh, old, MapSet.new(["linked", "linked/sub"]))
    assert carried["linked"] == old["linked"]
    assert carried["new.txt"] == :file
    # Closed: back to not listed, so opening it lists it fresh (N1).
    assert carried["closed"] == :link

    # Nothing open: the fresh index itself comes back, not a copy (N2: no work in proportion to
    # the tree's size on a reload).
    big = Tree.index(for i <- 1..2_000, do: "d#{rem(i, 40)}/f#{i}.txt")
    assert :erts_debug.same(Tree.carry(big, old, MapSet.new()), big)
    # A link gone, or a plain folder now, isn't carried.
    assert Tree.carry(Tree.index(["a.txt"]), old, MapSet.new(["linked"])) == Tree.index(["a.txt"])
    plain = Tree.index(["linked/real.txt"])
    assert Tree.carry(plain, old, MapSet.new(["linked"])) == plain
  end

  # verifier's review, Q11: a child whose kind changed on disk starts again unlisted.
  test "re-listing drops what was listed below a folder that became a link, or a link that became a folder" do
    index =
      Tree.index(["a.txt"])
      |> Tree.put_links(["linked"])
      |> Tree.put_listed("linked", %{"sub" => :dir, "ln" => :link})
      |> Tree.put_listed("linked/sub", %{"x" => :file})
      |> Tree.put_listed("linked/ln", %{"y" => :file})

    relisted = Tree.put_listed(index, "linked", %{"sub" => :link, "ln" => :dir})
    assert relisted["linked"]["sub"] == :link
    assert relisted["linked"]["ln"] == :dir
    # Unchanged kinds keep their listings.
    same = Tree.put_listed(index, "linked", %{"sub" => :dir, "ln" => :link})
    assert same["linked"]["sub"] == index["linked"]["sub"]
    assert same["linked"]["ln"] == index["linked"]["ln"]
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
