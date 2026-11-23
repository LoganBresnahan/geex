defmodule Geex.Tree do
  @moduledoc """
  The file tree's content ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md) §5): the files
  under the root, an index of them by directory, and the rows to show for the directories
  you've opened.

  `list_all/1` asks git where it can: inside a work tree, `git ls-files --cached --others
  --exclude-standard` (tracked files, plus untracked ones that aren't ignored), less any deleted
  from disk. Outside a repository it walks the directory. A dot folder is listed like any other,
  but a version control one (`.git`, `.hg`, `.svn`) never is (BUG-25).

  **A symlink** to a file is a file. **A symlink to a folder** is a folder whose contents aren't
  listed with the rest (BUG-24): it can point anywhere, somewhere huge or slow (`/mnt/c` under
  WSL), or back at an ancestor. It is `:link` in the index until it is opened, and then listed
  **one level at a time** (the maintainer's choice): `list_level/2` lists what is directly in it,
  each folder there `:dir` (a real folder, not listed yet) or `:link` again, and `put_listed/3`
  puts that level in. So nothing is followed on its own, a loop can't run away, and opening costs
  one directory, wherever the link points. A link that names nothing is left out. A level listed
  this way holds the key `:listed` (an atom, never a name), and a listed link `:link` too, so it
  still reads as a link; `carry/2` keeps such levels across a reload.

  There is no cap: a huge root is slow to list, not cut short, so the loop reads it in a process
  of its own. Both the walk and `index/1` spread their work over processes. `rows/2` is pure and
  visits only the open directories.
  """

  @type row :: %{
          path: String.t(),
          name: String.t(),
          depth: non_neg_integer(),
          dir?: boolean(),
          open?: boolean(),
          link?: boolean()
        }

  @typedoc """
  Each name under a directory: `:file`, the directory's own index, `:link` for a symlinked folder
  not listed yet, or `:dir` for a real folder inside one, not listed yet either. A level listed
  when opened holds the atom keys `:listed` and, for a link, `:link`.
  """
  @type index :: %{(String.t() | :listed | :link) => :file | :link | :dir | index() | true}

  @typedoc "What one folder holds, by name: what `list_level/2` gives and `put_listed/3` takes."
  @type level :: %{String.t() => :file | :link | :dir}

  # Never listed, wherever they are: version control's own folders.
  @vcs ~w(.git .hg .svn)

  @doc "The files under `root`, as paths relative to it, sorted (`list_all/1` without the links)."
  @spec list(String.t()) :: [String.t()]
  def list(root), do: root |> list_all() |> elem(0)

  @doc """
  The files under `root` and the symlinked folders among them (not listed), both as paths
  relative to `root`, sorted.
  """
  @spec list_all(String.t()) :: {[String.t()], [String.t()]}
  def list_all(root) do
    {files, links} =
      case git_files(root) do
        {:ok, files, links} -> {files, links}
        :error -> walk(root, [""])
      end

    {Enum.sort(files), Enum.sort(links)}
  end

  @doc """
  What folder `rel` (relative to `root`) holds directly, when it is opened inside a symlinked
  folder: each name `:file` (a link to a file too), `:link` (a symlinked folder) or `:dir` (a real
  folder, listed when it is opened). Read from the disk, git or not (git doesn't see past a link);
  never a version control folder; nothing below this one level.
  """
  @spec list_level(String.t(), String.t()) :: level()
  def list_level(root, rel) do
    {files, links, dirs} = entries(root, rel)
    named = fn paths, kind -> Map.new(paths, &{Path.basename(&1), kind}) end
    named.(files, :file) |> Map.merge(named.(links, :link)) |> Map.merge(named.(dirs, :dir))
  end

  @doc """
  `index` with each of `links` (relative paths) as a symlinked folder not listed yet. A path the
  index already holds is left alone.

      iex> Geex.Tree.index(["a.txt"]) |> Geex.Tree.put_links(["docs", "a.txt"])
      %{"a.txt" => :file, "docs" => :link}
  """
  @spec put_links(index(), [String.t()]) :: index()
  def put_links(index, links), do: Enum.reduce(links, index, &put_link(Path.split(&1), &2))

  defp put_link([name], index), do: Map.put_new(index, name, :link)

  defp put_link([dir | rest], index) do
    case Map.get(index, dir, %{}) do
      sub when is_map(sub) -> Map.put(index, dir, put_link(rest, sub))
      _file_or_link -> index
    end
  end

  @doc """
  Whether `rel` is a folder not listed yet: a symlinked one (`:link`), or a real one inside one
  (`:dir`).

      iex> index = Geex.Tree.index(["a.txt"]) |> Geex.Tree.put_links(["docs"])
      iex> {Geex.Tree.unlisted?(index, "docs"), Geex.Tree.unlisted?(index, "a.txt")}
      {true, false}
  """
  @spec unlisted?(index(), String.t()) :: boolean()
  def unlisted?(index, rel), do: node_at(index, Path.split(rel)) in [:link, :dir]

  @doc """
  Whether `rel` is a level listed when it was opened (inside a symlinked folder): what a reload
  lists again to stay current.
  """
  @spec listed_level?(index(), String.t()) :: boolean()
  def listed_level?(index, rel), do: match?(%{listed: true}, node_at(index, Path.split(rel)))

  @doc """
  `index` with folder `rel`'s `level` (`list_level/2`) put in: in place of its `:link` or `:dir`,
  or, listed again after a reload, over its last listing, keeping what was listed below a folder
  still there (so the open folders inside it stay listed). A folder not there, or not listed this
  way, is left alone.

      iex> index = Geex.Tree.index(["a.txt"]) |> Geex.Tree.put_links(["docs"])
      iex> index = Geex.Tree.put_listed(index, "docs", %{"x.md" => :file, "sub" => :dir})
      iex> index["docs"]
      %{:link => true, :listed => true, "x.md" => :file, "sub" => :dir}
      iex> index = Geex.Tree.put_listed(index, "docs/sub", %{"y.md" => :file})
      iex> Geex.Tree.put_listed(index, "docs", %{"sub" => :dir, "z.md" => :file})["docs"]
      %{:link => true, :listed => true, "sub" => %{:listed => true, "y.md" => :file}, "z.md" => :file}
  """
  @spec put_listed(index(), String.t(), level()) :: index()
  def put_listed(index, rel, level) do
    keys = Path.split(rel)

    case node_at(index, keys) do
      unlisted when unlisted in [:link, :dir] ->
        listed = Map.put(level, :listed, true)
        listed = if unlisted == :link, do: Map.put(listed, :link, true), else: listed
        put_in(index, Enum.map(keys, &Access.key(&1, %{})), listed)

      %{listed: true} = old ->
        kept =
          Map.new(level, fn {name, kind} -> {name, kept(Map.get(old, name), kind)} end)

        listed = old |> Map.take([:listed, :link]) |> Map.merge(kept)
        put_in(index, Enum.map(keys, &Access.key(&1, %{})), listed)

      _ ->
        index
    end
  end

  # What was listed below a folder still there, kept when it is still the same kind (a folder
  # that became a link on disk, or a link that became a folder, starts again unlisted).
  defp kept(%{link: true} = listed, :link), do: listed
  defp kept(%{listed: true} = listed, :dir) when not is_map_key(listed, :link), do: listed
  defp kept(_old, kind), do: kind

  @doc """
  A fresh `index` (a reload's) with the open folders' listed levels carried over from the `old`
  one, where the fresh one has that folder not listed yet: what is open inside a symlinked folder
  stays on screen, its rows and the highlight with them, until it is listed again. Only along
  `open` (a few paths), never the whole index: a reload costs what is open, not the tree's size
  (geex-verifier's review, N2). A closed level goes back to not listed (N1).

      iex> old = Geex.Tree.index(["a.txt"]) |> Geex.Tree.put_links(["docs", "more"])
      ...> |> Geex.Tree.put_listed("docs", %{"x.md" => :file})
      ...> |> Geex.Tree.put_listed("more", %{"y.md" => :file})
      iex> fresh = Geex.Tree.index(["a.txt", "b.txt"]) |> Geex.Tree.put_links(["docs", "more"])
      iex> Geex.Tree.carry(fresh, old, MapSet.new(["docs"]))
      %{"a.txt" => :file, "b.txt" => :file, "docs" => %{:link => true, :listed => true, "x.md" => :file}, "more" => :link}
  """
  @spec carry(index(), index(), MapSet.t()) :: index()
  def carry(fresh, old, open) do
    open
    |> Enum.sort_by(&length(Path.split(&1)))
    |> Enum.reduce(fresh, fn path, index ->
      keys = Path.split(path)

      with unlisted when unlisted in [:link, :dir] <- node_at(index, keys),
           %{listed: true} = level <- node_at(old, keys) do
        put_in(index, Enum.map(keys, &Access.key(&1, %{})), level)
      else
        _ -> index
      end
    end)
  end

  @doc """
  The files by directory. Each top-level directory is indexed in a process of its own.

      iex> Geex.Tree.index(["README.md", "lib/a.ex", "lib/b/c.ex"])
      %{"README.md" => :file, "lib" => %{"a.ex" => :file, "b" => %{"c.ex" => :file}}}
  """
  @spec index([String.t()]) :: index()
  def index(files) do
    files
    |> Enum.group_by(&top/1, &rest/1)
    |> Task.async_stream(
      fn
        {name, [nil]} -> {name, :file}
        {name, rests} -> {name, Enum.reduce(rests, %{}, &put_file/2)}
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, entry} -> entry end)
  end

  @doc """
  `index` with each of `dirs` (relative paths) in it as a directory, empty unless files are
  already there: a directory just made shows before anything is in it (ADR-0019's 2026-10-19
  amendment). A path a file already holds is left alone.

      iex> Geex.Tree.index(["lib/a.ex"]) |> Geex.Tree.put_dirs(["lib/new", "doc"])
      %{"doc" => %{}, "lib" => %{"a.ex" => :file, "new" => %{}}}
  """
  @spec put_dirs(index(), [String.t()]) :: index()
  def put_dirs(index, dirs), do: Enum.reduce(dirs, index, &put_dir(Path.split(&1), &2))

  defp put_dir([], index), do: index

  # A file, or a folder not listed yet (`:link`, `:dir`), stops it: what is under one isn't
  # listed, and it shows once the folder is opened (BUG-24's review, F1).
  defp put_dir([name | rest], index) do
    case Map.get(index, name, %{}) do
      sub when is_map(sub) -> Map.put(index, name, put_dir(rest, sub))
      _file_or_unlisted -> index
    end
  end

  defp top(path), do: path |> :binary.split("/") |> hd()

  defp rest(path) do
    case :binary.split(path, "/") do
      [_] -> nil
      [_, rest] -> rest
    end
  end

  defp put_file(path, index), do: put_in(index, keys(Path.split(path)), :file)

  defp keys([name]), do: [Access.key(name, :file)]
  defp keys([dir | rest]), do: [Access.key(dir, %{}) | keys(rest)]

  @doc """
  The rows to show: every top-level entry, and the contents of each directory in `open` (a set
  of directory paths). Directories come before files, each alphabetical.

      iex> Geex.Tree.index(["README.md", "lib/a.ex", "lib/b/c.ex"])
      ...> |> Geex.Tree.rows(MapSet.new(["lib"]))
      ...> |> Enum.map(&{&1.path, &1.depth, &1.dir?, &1.open?})
      [{"lib", 0, true, true}, {"lib/b", 1, true, false}, {"lib/a.ex", 1, false, false},
       {"README.md", 0, false, false}]
  """
  @spec rows(index(), MapSet.t()) :: [row()]
  def rows(index, open), do: rows(index, "", 0, open)

  defp rows(index, prefix, depth, open) do
    {dirs, files} =
      index
      |> Enum.reject(fn {name, _v} -> is_atom(name) end)
      |> Enum.split_with(fn {_name, v} -> v != :file end)

    Enum.flat_map(Enum.sort(dirs), fn {name, sub} ->
      path = Path.join(prefix, name)
      open? = MapSet.member?(open, path)
      # A symlinked folder: a folder, its rows once listed (`put_listed/3`), a link either way.
      link? = sub == :link or (is_map(sub) and Map.has_key?(sub, :link))
      row = %{path: path, name: name, depth: depth, dir?: true, open?: open?, link?: link?}
      if open? and is_map(sub), do: [row | rows(sub, path, depth + 1, open)], else: [row]
    end) ++
      Enum.map(Enum.sort(files), fn {name, :file} ->
        path = Path.join(prefix, name)
        %{path: path, name: name, depth: depth, dir?: false, open?: false, link?: false}
      end)
  end

  # git's stderr is dropped: in the TUI the terminal belongs to the renderer. The deleted files
  # are dropped in batches, in parallel.
  defp git_files(root) do
    with git when is_binary(git) <- System.find_executable("git"),
         script =
           ~s|exec "$0" -C "$1" ls-files --cached --others --exclude-standard -z 2>/dev/null|,
         {out, 0} <- System.cmd("sh", ["-c", script, git, root]) do
      # A file (a link to one included: `regular?` follows it), or a link to a folder, which git
      # lists as one entry (BUG-24); anything else (deleted, a link naming nothing) is dropped.
      {files, links} =
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.chunk_every(500)
        |> Task.async_stream(fn batch -> Enum.map(batch, &kind(root, &1)) end,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, batch} -> batch end)
        |> Enum.reduce({[], []}, fn
          {:file, path}, {files, links} -> {[path | files], links}
          {:link, path}, {files, links} -> {files, [path | links]}
          :skip, acc -> acc
        end)

      {:ok, files, links}
    else
      _ -> :error
    end
  end

  # The entry at `keys` (path segments), or nil: a file on the way has nothing under it.
  defp node_at(entry, []), do: entry
  defp node_at(index, [key | rest]) when is_map(index), do: node_at(Map.get(index, key), rest)
  defp node_at(_entry, _keys), do: nil

  # What git listed at `path`: a file (a link to one too), a link to a folder, or nothing to show.
  defp kind(root, path) do
    full = Path.join(root, path)

    cond do
      Geex.Disk.regular?(full) -> {:file, path}
      link?(full) and Geex.Disk.dir?(full) -> {:link, path}
      true -> :skip
    end
  end

  defp link?(full), do: match?({:ok, %{type: :symlink}}, Geex.Disk.lstat(full))

  # Breadth-first from `dirs`, a level of directories at a time, each listed in a process of its
  # own (the file calls run in parallel on the VM's dirty IO schedulers): the files and the
  # symlinked folders found, neither followed. Skips version control folders. The root's walk
  # only; a linked folder is listed a level at a time (`list_level/2`).
  defp walk(root, dirs), do: walk(root, dirs, {[], []})

  defp walk(_root, [], acc), do: acc

  defp walk(root, dirs, {files, links}) do
    {files, links, subdirs} =
      dirs
      |> Task.async_stream(&entries(root, &1), ordered: false, timeout: :infinity)
      |> Enum.reduce({files, links, []}, fn {:ok, {found, linked, sub}}, {files, links, subdirs} ->
        {found ++ files, linked ++ links, sub ++ subdirs}
      end)

    walk(root, subdirs, {files, links})
  end

  # One directory's files, symlinked folders and subdirectories.
  defp entries(root, rel) do
    case Geex.Disk.ls(Path.join(root, rel)) do
      {:ok, names} ->
        Enum.reduce(names, {[], [], []}, fn name, {files, links, dirs} ->
          path = if rel == "", do: name, else: Path.join(rel, name)
          full = Path.join(root, path)

          case Geex.Disk.lstat(full) do
            {:ok, %{type: :directory}} ->
              if name in @vcs, do: {files, links, dirs}, else: {files, links, [path | dirs]}

            {:ok, %{type: :regular}} ->
              {[path | files], links, dirs}

            {:ok, %{type: :symlink}} ->
              cond do
                Geex.Disk.regular?(full) -> {[path | files], links, dirs}
                Geex.Disk.dir?(full) and name not in @vcs -> {files, [path | links], dirs}
                true -> {files, links, dirs}
              end

            _ ->
              {files, links, dirs}
          end
        end)

      {:error, _} ->
        {[], [], []}
    end
  end
end
