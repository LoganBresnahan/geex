defmodule Geex.Loop.FileOps do
  @moduledoc """
  Creating, deleting and renaming files and directories from the TUI (ADR-0019's 2026-10-19
  amendment): the typed verbs `new`, `mkdir`, `delete` and `rename` (`Geex.Loop.Verbs`) and the
  tree's `a`, `d` and `r` keys. Both go through the same `Geex.Session` functions the MCP tools
  use.

  `resolve/2` is pure: where a typed path points. A relative path is from the project root and
  must stay inside it; an absolute one (`/…`, `~`, `~/…`) goes where it says.

  `step/2` does one step of an operation and says what comes next. It touches the disk, so the
  loop runs it in a process of its own (ADR-0035) and acts on the answer:

    * `{:done, notice}` — finished, or refused, with what to say;
    * `{:confirm, question, op}` — ask y/n, and run `op` on a yes. Nothing is deleted, and no
      missing directory is made, without one;
    * `{:open, path, notice}` — a file was made: open it;
    * `{:made_dir, path, notice}` — a directory was made;
    * `{:renamed, from, to, notice}` — a file or directory moved.
  """

  alias Geex.Session

  @type op ::
          {:new, String.t()}
          | {:new_parents, String.t()}
          | {:mkdir, String.t()}
          | {:delete, String.t()}
          | {:rm, String.t()}
          | {:rmdir, String.t()}
          | {:rename, String.t(), String.t()}

  @type answer ::
          {:done, String.t()}
          | {:confirm, String.t(), op()}
          | {:open, String.t(), String.t()}
          | {:made_dir, String.t(), String.t()}
          | {:renamed, String.t(), String.t(), String.t()}

  @doc """
  The absolute path a typed `path` names: from `root` when relative (`{:error, :outside_root}`
  when that leaves it), as given when absolute or under `~`. Pure.

      iex> Geex.Loop.FileOps.resolve("lib/a.ex", "/r")
      {:ok, "/r/lib/a.ex"}
      iex> Geex.Loop.FileOps.resolve("../etc/passwd", "/r")
      {:error, :outside_root}
      iex> Geex.Loop.FileOps.resolve("/tmp/x", "/r")
      {:ok, "/tmp/x"}
  """
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, :outside_root}
  def resolve("~", _root), do: {:ok, Path.expand("~")}
  def resolve("~/" <> _ = path, _root), do: {:ok, Path.expand(path)}
  def resolve("/" <> _ = path, _root), do: {:ok, Path.expand(path)}

  def resolve(path, root) do
    full = Path.expand(path, root)
    if inside?(full, root), do: {:ok, full}, else: {:error, :outside_root}
  end

  @doc """
  How a path is named in a message: from the root when it is inside, else in full. Pure.

      iex> Geex.Loop.FileOps.name("/r/lib/a.ex", "/r")
      "lib/a.ex"
      iex> Geex.Loop.FileOps.name("/tmp/x", "/r")
      "/tmp/x"
  """
  @spec name(String.t(), String.t() | nil) :: String.t()
  def name(full, root) do
    if root && full != root && inside?(full, root), do: Path.relative_to(full, root), else: full
  end

  defp inside?(full, root), do: full == root or String.starts_with?(full, root <> "/")

  @doc "Do one step of `op`, from `root` (for the messages). Touches the disk: off the loop."
  @spec step(op(), String.t() | nil) :: answer()
  def step({:new, full}, root) do
    parent = Path.dirname(full)

    cond do
      taken?(full) ->
        {:done, "not created: #{name(full, root)} already exists"}

      not File.exists?(parent) ->
        {:confirm, "#{name(parent, root)}/ doesn't exist; create it? (y/n) ",
         {:new_parents, full}}

      not File.dir?(parent) ->
        {:done, "not created: #{name(parent, root)} isn't a directory"}

      true ->
        create(full, root)
    end
  end

  def step({:new_parents, full}, root) do
    case Session.make_dir(Path.dirname(full)) do
      {:ok, _} ->
        create(full, root)

      {:error, :eexist} ->
        create(full, root)

      {:error, reason} ->
        {:done, "not created: #{name(Path.dirname(full), root)}: #{why(reason)}"}
    end
  end

  def step({:mkdir, full}, root) do
    case Session.make_dir(full) do
      {:ok, full} -> {:made_dir, full, "created #{name(full, root)}/"}
      {:error, :eexist} -> {:done, "not created: #{name(full, root)} already exists"}
      {:error, reason} -> {:done, "not created: #{name(full, root)}/: #{why(reason)}"}
    end
  end

  # Before deleting: what's there, and what to ask.
  def step({:delete, full}, root) do
    shown = name(full, root)

    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        case File.ls(full) do
          {:ok, []} -> {:confirm, "delete #{shown}/? (y/n) ", {:rmdir, full}}
          {:ok, _} -> {:done, "not deleted: #{shown}/ isn't empty"}
          {:error, reason} -> {:done, "not deleted: #{shown}/: #{why(reason)}"}
        end

      {:ok, _file} ->
        question =
          if dirty?(full),
            do: "delete #{shown}? Its unsaved edits go with it. (y/n) ",
            else: "delete #{shown}? (y/n) "

        {:confirm, question, {:rm, full}}

      {:error, :enoent} ->
        {:done, "not deleted: #{shown} isn't on disk" <> unsaved_hint(full)}

      {:error, reason} ->
        {:done, "not deleted: #{shown}: #{why(reason)}"}
    end
  end

  def step({:rm, full}, root) do
    case Session.delete_file(full) do
      {:ok, {_, true}} -> {:done, "deleted #{name(full, root)}, and its unsaved edits"}
      {:ok, {_, false}} -> {:done, "deleted #{name(full, root)}"}
      {:error, reason} -> {:done, "not deleted: #{name(full, root)}: #{why(reason)}"}
    end
  end

  def step({:rmdir, full}, root) do
    case Session.remove_dir(full) do
      {:ok, _} ->
        {:done, "deleted #{name(full, root)}/"}

      {:error, r} when r in [:eexist, :enotempty] ->
        {:done, "not deleted: #{name(full, root)}/ isn't empty"}

      {:error, reason} ->
        {:done, "not deleted: #{name(full, root)}/: #{why(reason)}"}
    end
  end

  def step({:rename, from, to}, root) do
    case Session.rename_file(from, to) do
      {:ok, {from, to}} ->
        {:renamed, from, to, "renamed #{name(from, root)} to #{name(to, root)}"}

      {:error, :destination_exists} ->
        {:done, "not renamed: #{name(to, root)} already exists"}

      {:error, :same_path} ->
        {:done, "not renamed: that's its name already"}

      {:error, reason} ->
        {:done, "not renamed: #{name(from, root)} to #{name(to, root)}: #{why(reason)}"}
    end
  end

  defp create(full, root) do
    case Session.create_file(full) do
      {:ok, full} -> {:open, full, "created #{name(full, root)}"}
      {:error, :eexist} -> {:done, "not created: #{name(full, root)} already exists"}
      {:error, reason} -> {:done, "not created: #{name(full, root)}: #{why(reason)}"}
    end
  end

  # A posix reason in words ("permission denied"); anything else as it is.
  defp why(reason) when is_atom(reason) do
    case to_string(:file.format_error(reason)) do
      "unknown POSIX error" <> _ -> inspect(reason)
      words -> words
    end
  end

  defp why(reason), do: inspect(reason)

  # On disk, or open in a buffer not saved yet.
  defp taken?(full), do: File.exists?(full) or Geex.BufferSupervisor.whereis(full) != :error

  defp dirty?(full) do
    case Geex.BufferSupervisor.whereis(full) do
      {:ok, pid} -> match?(%{dirty: true}, Geex.Buffer.status(pid))
      :error -> false
    end
  catch
    :exit, _ -> false
  end

  defp unsaved_hint(full) do
    if Geex.BufferSupervisor.whereis(full) != :error,
      do: " (it was never saved: close it with Alt+K)",
      else: ""
  end
end
