defmodule Geex.Tree do
  @moduledoc """
  The file tree's content ([ADR-0034](../../doc/adr/0034-panes-tree-edits-hold.md) §5): the files
  under the root, and the rows to show for the directories you've opened.

  `list/1` asks git where it can: inside a work tree, `git ls-files --cached --others
  --exclude-standard` (tracked files, plus untracked ones that aren't ignored), less any deleted
  from disk. Outside a repository it walks the directory, skipping dot-directories. Both stop
  at 10,000 files. `rows/2` is pure.
  """

  @cap 10_000

  @type row :: %{
          path: String.t(),
          name: String.t(),
          depth: non_neg_integer(),
          dir?: boolean(),
          open?: boolean()
        }

  @doc "The files under `root`, as paths relative to it, sorted."
  @spec list(String.t()) :: [String.t()]
  def list(root) do
    files =
      case git_files(root) do
        {:ok, files} -> files
        :error -> walk(root, "", @cap)
      end

    files |> Enum.take(@cap) |> Enum.sort()
  end

  @doc """
  The rows to show: every top-level entry, and the contents of each directory in `open` (a set
  of directory paths). Directories come before files, each alphabetical.

      iex> Geex.Tree.rows(["README.md", "lib/a.ex", "lib/b/c.ex"], MapSet.new(["lib"]))
      ...> |> Enum.map(&{&1.path, &1.depth, &1.dir?, &1.open?})
      [{"lib", 0, true, true}, {"lib/b", 1, true, false}, {"lib/a.ex", 1, false, false},
       {"README.md", 0, false, false}]
  """
  @spec rows([String.t()], MapSet.t()) :: [row()]
  def rows(files, open) do
    files
    |> Enum.reduce(%{}, fn path, tree -> put_in(tree, keys(Path.split(path)), :file) end)
    |> rows("", 0, open)
  end

  defp keys([name]), do: [Access.key(name, :file)]
  defp keys([dir | rest]), do: [Access.key(dir, %{}) | keys(rest)]

  defp rows(tree, prefix, depth, open) do
    {dirs, files} = tree |> Enum.split_with(fn {_name, v} -> is_map(v) end)

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

  # git's stderr is dropped: in the TUI the terminal belongs to the renderer.
  defp git_files(root) do
    with git when is_binary(git) <- System.find_executable("git"),
         script =
           ~s|exec "$0" -C "$1" ls-files --cached --others --exclude-standard -z 2>/dev/null|,
         {out, 0} <- System.cmd("sh", ["-c", script, git, root]) do
      files =
        out
        |> String.split(<<0>>, trim: true)
        |> Stream.filter(&File.regular?(Path.join(root, &1)))
        |> Enum.take(@cap)

      {:ok, files}
    else
      _ -> :error
    end
  end

  # Depth-first, skipping dot-directories and symlinks (no loops), until `left` files are found.
  defp walk(_root, _rel, left) when left <= 0, do: []

  defp walk(root, rel, left) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({[], left}, fn name, {acc, left} ->
          path = if rel == "", do: name, else: Path.join(rel, name)

          found =
            case File.lstat(Path.join(root, path)) do
              {:ok, %{type: :directory}} ->
                if String.starts_with?(name, "."), do: [], else: walk(root, path, left)

              {:ok, %{type: :regular}} ->
                [path]

              _ ->
                []
            end

          # Built newest first, reversed once at the end.
          acc = Enum.reverse(found, acc)
          left = left - length(found)
          if left <= 0, do: {:halt, {acc, 0}}, else: {:cont, {acc, left}}
        end)
        |> elem(0)
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end
end
