defmodule Geex.Edit.GitMerge do
  @moduledoc """
  The merge for a buffer that is behind its file (ADR-0034 §2): `git merge-file`, so the
  result, conflicts included, reads exactly as git writes it.

  `base` is the disk text the buffer last synced, `ours` the buffer, `theirs` the disk now.
  A clean merge has every change from both sides. A conflict is git's block, labelled so you
  can tell the sides apart:

      <<<<<<< buffer
      your lines
      =======
      the disk's lines
      >>>>>>> disk

  Not pure: the three texts go in a private (`0700`) temp directory, removed afterwards, and
  git runs on them. Works outside any repository. The caller records the result as ordinary
  hunk commands, so replay never runs git (invariant 3). Without git, or on a git error (a
  binary file), it returns `{:error, _}` and the caller falls back to `Geex.Edit.Merge`.
  """

  @begin "<<<<<<< buffer"
  @finish ">>>>>>> disk"

  @doc """
  Merge `theirs` into `ours` over `base`: `{:ok, merged, conflicts}` (the number of conflict
  blocks git wrote), or `{:error, reason}`.
  """
  @spec merge(String.t(), String.t(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def merge(base, ours, theirs) when is_binary(base) and is_binary(ours) and is_binary(theirs) do
    # `:git_executable` (app env) only so a test can see the no-git fallback.
    case System.find_executable(Application.get_env(:geex, :git_executable, "git")) do
      nil -> {:error, :no_git}
      git -> in_private_dir(&run(git, &1, base, ours, theirs))
    end
  end

  # `git merge-file` exits with the number of conflicts (capped at 127), or 255 on an error.
  # It runs under `sh` only to send git's stderr to /dev/null: in the TUI the terminal belongs
  # to the renderer (invariant 4). The paths are arguments, never part of the script.
  defp run(git, dir, base, ours, theirs) do
    [o, b, t] =
      for {name, text} <- [ours: ours, base: base, theirs: theirs], do: put(dir, name, text)

    script = ~s|exec "$0" merge-file -p -L buffer -L base -L disk "$1" "$2" "$3" 2>/dev/null|

    case System.cmd("sh", ["-c", script, git, o, b, t]) do
      {merged, status} when status in 0..127 -> {:ok, merged, status}
      {_output, status} -> {:error, {:git_merge_file, status}}
    end
  end

  defp put(dir, name, text) do
    path = Path.join(dir, Atom.to_string(name))
    File.write!(path, text)
    path
  end

  defp in_private_dir(fun) do
    # The OS pid as well: a unique integer is unique only within this VM, and another geex may
    # be merging in the same temp directory now.
    dir =
      Path.join(
        System.tmp_dir!(),
        "geex-merge-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      try do
        fun.(dir)
      after
        File.rm_rf(dir)
      end
    end
  rescue
    error in File.Error -> {:error, error.reason}
  end

  @doc """
  The line (0-based) of the first conflict block a merge left in `text` that is still there:
  a `<<<<<<< buffer` line with a `>>>>>>> disk` line after it. `nil` when there is none. A
  CRLF file's marker lines end in `"\\r"`, which is ignored. Pure.

      iex> Geex.Edit.GitMerge.unresolved("a\\n<<<<<<< buffer\\nx\\n=======\\ny\\n>>>>>>> disk\\n")
      1
      iex> Geex.Edit.GitMerge.unresolved("a\\n<<<<<<< buffer\\nx\\n")
      nil
  """
  @spec unresolved(String.t()) :: non_neg_integer() | nil
  def unresolved(text) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))

    with at when is_integer(at) <- Enum.find_index(lines, &(&1 == @begin)),
         true <- @finish in Enum.drop(lines, at + 1) do
      at
    else
      _ -> nil
    end
  end
end
