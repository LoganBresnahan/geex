defmodule Geex.Tree do
  @moduledoc """
  The file tree's content ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md) §5): the files
  under the root, an index of them by directory, and the rows to show for the directories
  you've opened.

  `list/1` asks git where it can: inside a work tree, `git ls-files --cached --others
  --exclude-standard` (tracked files, plus untracked ones that aren't ignored), less any deleted
  from disk. Outside a repository it walks the directory, skipping dot-directories. There is no
  cap: a huge root is slow to list, not cut short, so the loop reads it in a process of its own.
  Both the walk and `index/1` spread their work over processes. `rows/2` is pure and visits
  only the open directories.
  """

  @type row :: %{
          path: String.t(),
          name: String.t(),
          depth: non_neg_integer(),
          dir?: boolean(),
          open?: boolean()
        }

  @typedoc "Each name under a directory: `:file`, or the directory's own index."
  @type index :: %{String.t() => :file | index()}

  @doc "The files under `root`, as paths relative to it, sorted."
  @spec list(String.t()) :: [String.t()]
  def list(root) do
    files =
      case git_files(root) do
        {:ok, files} -> files
        :error -> walk(root)
      end

    Enum.sort(files)
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
    {dirs, files} = index |> Enum.split_with(fn {_name, v} -> is_map(v) end)

    Enum.flat_map(Enum.sort(dirs), fn {name, sub} ->
      path = Path.join(prefix, name)
      open? = MapSet.member?(open, path)
      row = %{path: path, name: name, depth: depth, dir?: true, open?: open?}
      if open?, do: [row | rows(sub, path, depth + 1, open)], else: [row]
    end) ++
      Enum.map(Enum.sort(files), fn {name, :file} ->
        %{path: Path.join(prefix, name), name: name, depth: depth, dir?: false, open?: false}
      end)
  end

  # git's stderr is dropped: in the TUI the terminal belongs to the renderer. The deleted files
  # are dropped in batches, in parallel.
  defp git_files(root) do
    with git when is_binary(git) <- System.find_executable("git"),
         script =
           ~s|exec "$0" -C "$1" ls-files --cached --others --exclude-standard -z 2>/dev/null|,
         {out, 0} <- System.cmd("sh", ["-c", script, git, root]) do
      files =
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.chunk_every(500)
        |> Task.async_stream(
          &Enum.filter(&1, fn path -> File.regular?(Path.join(root, path)) end),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, batch} -> batch end)

      {:ok, files}
    else
      _ -> :error
    end
  end

  # Breadth-first, a level of directories at a time, each listed in a process of its own (the
  # file calls run in parallel on the VM's dirty IO schedulers). Skips dot-directories and
  # symlinks (no loops).
  defp walk(root), do: walk(root, [""], [])

  defp walk(_root, [], files), do: files

  defp walk(root, dirs, files) do
    {files, subdirs} =
      dirs
      |> Task.async_stream(&entries(root, &1), ordered: false, timeout: :infinity)
      |> Enum.reduce({files, []}, fn {:ok, {found, sub}}, {files, subdirs} ->
        {found ++ files, sub ++ subdirs}
      end)

    walk(root, subdirs, files)
  end

  # One directory's files and subdirectories.
  defp entries(root, rel) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        Enum.reduce(names, {[], []}, fn name, {files, dirs} ->
          path = if rel == "", do: name, else: Path.join(rel, name)

          case File.lstat(Path.join(root, path)) do
            {:ok, %{type: :directory}} ->
              if String.starts_with?(name, "."), do: {files, dirs}, else: {files, [path | dirs]}

            {:ok, %{type: :regular}} ->
              {[path | files], dirs}

            _ ->
              {files, dirs}
          end
        end)

      {:error, _} ->
        {[], []}
    end
  end
end
