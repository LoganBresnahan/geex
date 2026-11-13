defmodule Geex.Search.ProjectTest do
  # The project search's pure half (ADR-0053 §6): the commands, the quoting, the refusals and
  # reading a result line back. The commands themselves run against real repositories in
  # Geex.Loop.ProjectSearchTest.
  use ExUnit.Case, async: true

  alias Geex.Search.Project

  doctest Geex.Search.Project

  test "the quoting survives every character sh treats specially (R15)" do
    for q <- [
          ~S|it's|,
          ~S|$HOME|,
          ~S|`id`|,
          ~S|a\b|,
          ~S|"x"|,
          "tab\there",
          "é 👍",
          ~S|';rm -rf /;'|
        ] do
      {out, 0} = System.cmd("sh", ["-c", "printf '%s' " <> Project.shell_quote(q)])
      assert out == q, inspect(q)
    end
  end

  test "smart case: -i only for a query with no capital" do
    assert Project.command("abc", :project, true) =~ " -i "
    refute Project.command("Abc", :project, true) =~ " -i "
    refute Project.command("abÉ", :all, false) =~ " -i "
  end

  test "search project leaves the common directories out; search all doesn't" do
    for dir <- Project.excluded() do
      assert Project.command("x", :project, true) =~ "**/#{dir}/**"
      assert Project.command("x", :project, false) =~ "--exclude-dir='#{dir}'"
      refute Project.command("x", :all, true) =~ dir
      refute Project.command("x", :all, false) =~ "exclude"
    end

    assert Project.command("x", :all, true) =~ "--no-exclude-standard"
    assert Project.command("x", :project, true) =~ "--untracked"
  end

  test "the plan: a NUL byte refused; outside git, home, above it and / refused" do
    assert {:error, "can't search for a NUL byte"} = Project.plan("a" <> <<0>>, "/p", true, "/h")
    assert {:error, "not searching the whole disk" <> _} = Project.plan("x", "/", false, "/h")
    assert {:error, "not searching your whole" <> _} = Project.plan("x", "/h/", false, "/h")
    assert {:error, "not searching above" <> _} = Project.plan("x", "/h", false, "/h/me")
    assert Project.plan("x", "/h/proj", false, "/h") == {:ok, []}
    assert Project.plan("x", "/hx", false, "/h") == {:ok, []}
    assert Project.plan("x", "/p", true, "/h") == {:ok, []}
  end

  test "a home directory kept in git: searched, its tracked files only" do
    assert {:ok, opts} = Project.plan("x", "/h", true, "/h")
    refute opts[:untracked]
    assert opts[:note] =~ "tracked files only"
    refute Project.command("x", :project, true, opts) =~ "--untracked"
    assert Project.command("x", :project, true) =~ "--untracked"
  end

  test "real_path/1 follows a symlink, so a link to home is home", %{} do
    dir = Path.join(System.tmp_dir!(), "geex_real_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "home/me"))
    File.ln_s!(Path.join(dir, "home/me"), Path.join(dir, "link"))

    try do
      assert Project.real_path(Path.join(dir, "link")) ==
               Project.real_path(Path.join(dir, "home/me"))

      assert Project.real_path(Path.join(dir, "link/sub")) =~ "home/me/sub"
    after
      File.rm_rf(dir)
    end
  end

  test "real_path/1 takes a directory name that isn't UTF-8, and a link to one" do
    # A Latin-1 directory name raised UnicodeConversionError in the loop (mod-verify's review).
    dir = Path.join(System.tmp_dir!(), "geex_real_#{System.unique_integer([:positive])}")
    latin = Path.join(dir, "caf" <> <<0xE9>> <> "/proj")
    File.mkdir_p!(latin)
    File.ln_s!(latin, Path.join(dir, "link" <> <<0xE9>>))

    try do
      # The temp dir itself may sit behind a link (macOS: /var is /private/var), so the expected
      # paths are built from its own real path.
      real = Path.join(Project.real_path(dir), "caf" <> <<0xE9>> <> "/proj")
      assert Project.real_path(latin) == real
      assert Project.real_path(Path.join(dir, "link" <> <<0xE9>>)) == real
      assert Project.real_path(Path.join(dir, "link" <> <<0xE9>> <> "/sub")) == real <> "/sub"
      assert {:ok, _opts} = Project.plan("needle", latin, true, dir <> "/elsewhere")
    after
      File.rm_rf(dir)
    end
  end

  test "a query that isn't UTF-8 has no -i (git refuses it), and grep runs in the C locale" do
    q = "caf" <> <<0xE9>>
    refute Project.command(q, :project, true) =~ " -i "
    refute Project.command(q, :project, false) =~ " -i "
    assert Project.command("x", :project, false) =~ ~r/^LC_ALL=C grep /
    assert Project.command("x", :all, false) =~ ~r/^LC_ALL=C grep /
    refute Project.command("x", :project, true) =~ "LC_ALL"
  end

  test "result lines: spaces, non-ASCII, ./ from grep, a colon in the text" do
    assert Project.locations("sub dir/café notes.txt:12:needle: here") ==
             [{"sub dir/café notes.txt", 12}]

    assert Project.locations("./lib/a.ex:3:x") == [{"./lib/a.ex", 3}]
    assert {"notes:12", 7} in Project.locations("notes:12:7:text")
    assert Project.locations("Binary file a matches") == []

    assert Project.locations("weird" <> <<0xE9>> <> ".txt:4:x") ==
             [{"weird" <> <<0xE9>> <> ".txt", 4}]
  end
end
