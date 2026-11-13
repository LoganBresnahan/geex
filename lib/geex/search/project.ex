defmodule Geex.Search.Project do
  @moduledoc """
  The project search's pure half ([ADR-0053](../../../doc/adr/0053-search.md) §6–§7 and its
  2026-11-13 amendment): the command `Alt+Shift+Q` runs, the result lines it reads back, and
  whether a root is one to refuse. The loop runs the command through `Geex.Shell` into the output
  pane, as `!` runs one (ADR-0042).

  - **`search-project`**: in a git work tree, `git grep` over the tracked files and the untracked
    ones git doesn't ignore (Q11), the common generated directories left out; outside one, `grep -r`
    leaving the same directories out.
  - **`search-all`**: everything: in git, ignored files too; outside, every file.
  - Plain text (`-F`), binary files skipped (`-I`), line numbers (`-n`); smart case as the file's
    search has it (`-i` when the query has no capital, `Geex.Search.capital?/1`). git's paths come
    unquoted (`core.quotePath=false`), so a name with a space or an `é` reads as it is (R13).
  - Case folding with `-i` follows the system's locale (Q15): under the bare `C` locale only A–Z
    fold. It isn't forced.
  """

  @excluded ~w(.git _build deps node_modules target dist .venv)

  @doc "The directories `search-project` leaves out."
  @spec excluded() :: [String.t()]
  def excluded, do: @excluded

  @doc """
  The shell command for searching `root` for `query`: `mode` `:project` or `:all`, `git?` whether
  `root` is a git work tree.

      iex> Geex.Search.Project.command("it's", :all, true)
      "git -c core.quotePath=false grep -n -I -F -i --untracked --no-exclude-standard -e 'it'\\\\''s' -- ."
      iex> Geex.Search.Project.command("Foo", :all, false)
      "LC_ALL=C grep -rnI -F -e 'Foo' ."
  """
  @spec command(String.t(), :project | :all, boolean(), keyword()) :: String.t()
  def command(query, mode, git?, opts \\ []) do
    # Smart case, but never -i for a query that isn't UTF-8: git refuses such a pattern under -i
    # ("UTF-8 error"), and an invalid byte matches only itself, as in the file's search.
    case_flag =
      if Geex.Search.capital?(query) or not String.valid?(query), do: [], else: ["-i"]

    # `--untracked` but where told not to (a home directory kept in git: its tracked files only).
    untracked = if Keyword.get(opts, :untracked, true), do: ["--untracked"], else: []

    words =
      case {git?, mode} do
        {true, :project} ->
          ["git", "-c", "core.quotePath=false", "grep", "-n", "-I", "-F"] ++
            case_flag ++
            untracked ++
            ["-e", shell_quote(query), "--", "."] ++
            Enum.map(@excluded, &shell_quote(":(exclude,glob)**/" <> &1 <> "/**"))

        {true, :all} ->
          ["git", "-c", "core.quotePath=false", "grep", "-n", "-I", "-F"] ++
            case_flag ++
            untracked ++ ["--no-exclude-standard", "-e", shell_quote(query), "--", "."]

        # Outside git, grep in the C locale: under a UTF-8 one GNU grep takes a file holding a
        # byte that isn't UTF-8 for binary, and -I skips it, so a Latin-1 file was never searched.
        # The cost: -i folds A–Z only there (ADR-0053's as-built notes, beside Q15).
        {false, :project} ->
          ["LC_ALL=C", "grep", "-rnI", "-F"] ++
            case_flag ++
            Enum.map(@excluded, &("--exclude-dir=" <> shell_quote(&1))) ++
            ["-e", shell_quote(query), "."]

        {false, :all} ->
          ["LC_ALL=C", "grep", "-rnI", "-F"] ++ case_flag ++ ["-e", shell_quote(query), "."]
      end

    Enum.join(words, " ")
  end

  @doc """
  `s` quoted for `sh`: inside single quotes, each `'` as `'\\''` (R15).

      iex> Geex.Search.Project.shell_quote(~S|a 'b' $c `d` \\e|)
      ~S|'a '\\''b'\\'' $c `d` \\e'|
  """
  @spec shell_quote(String.t()) :: String.t()
  def shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  @doc """
  Whether and how to search for `query` from `root` (`git?` whether it is a git work tree, `home`
  the home directory): `{:error, why}`, or `{:ok, opts}` for `command/4` with a `note` to show.
  Refused: a query holding a NUL byte (the shell would cut it there, R15); outside git, the home
  directory, any directory above it, or `/`, which would read every file under them (Q16). A home
  directory kept in git (a dotfiles repository) is searched, its tracked files only: untracked
  files there are everything else in the home directory. `root` and `home` are compared as given;
  the caller resolves symlinks (`real_path/1`).

      iex> Geex.Search.Project.plan("x", "/home/me", false, "/home/me")
      {:error, "not searching your whole home directory: start geex in a project"}
      iex> Geex.Search.Project.plan("x", "/home", false, "/home/me")
      {:error, "not searching above your home directory: start geex in a project"}
      iex> Geex.Search.Project.plan("x", "/home/me", true, "/home/me")
      {:ok, [untracked: false, note: "your home directory is a git work tree: its tracked files only"]}
      iex> Geex.Search.Project.plan("x", "/home/me/p", false, "/home/me")
      {:ok, []}
  """
  @spec plan(String.t(), String.t(), boolean(), String.t() | nil) ::
          {:ok, keyword()} | {:error, String.t()}
  def plan(query, root, git?, home) do
    root = Path.expand(root)
    home = home && Path.expand(home)

    at_home? =
      home != nil and
        (root == home or String.starts_with?(home, String.trim_trailing(root, "/") <> "/"))

    cond do
      String.contains?(query, <<0>>) ->
        {:error, "can't search for a NUL byte"}

      git? and at_home? ->
        note =
          if root == home,
            do: "your home directory is a git work tree: its tracked files only",
            else: "a git work tree above your home directory: its tracked files only"

        {:ok, [untracked: false, note: note]}

      git? ->
        {:ok, []}

      root == "/" ->
        {:error, "not searching the whole disk: start geex in a project"}

      root == home ->
        {:error, "not searching your whole home directory: start geex in a project"}

      at_home? ->
        {:error, "not searching above your home directory: start geex in a project"}

      true ->
        {:ok, []}
    end
  end

  @doc """
  `path` with every symlink in it followed (a link to the home directory is the home directory),
  as far as the filesystem says; `path` expanded when it can't be read. Reads the filesystem.
  """
  @spec real_path(String.t()) :: String.t()
  def real_path(path), do: path |> Path.expand() |> Path.split() |> follow([], 0)

  defp follow(_rest, acc, 40), do: Path.join(Enum.reverse(acc))
  defp follow([], acc, _n), do: Path.join(Enum.reverse(acc))

  defp follow([part | rest], acc, n) do
    here = Path.join(Enum.reverse([part | acc]))

    # The name goes to Erlang as the binary it is: a path holding a byte that isn't UTF-8 (a
    # Latin-1 directory name) can't become a charlist, and raised in the loop (mod-verify's
    # review). Given a binary, Erlang answers with the target's raw bytes as a binary too.
    case :file.read_link_all(here) do
      {:ok, target} ->
        base = Path.join(Enum.reverse(acc))
        target = if is_binary(target), do: target, else: :erlang.list_to_binary(target)
        to = Path.expand(target, base)
        follow(Path.split(to) ++ rest, [], n + 1)

      _ ->
        follow(rest, [part | acc], n)
    end
  end

  @doc """
  Where a result line points: every `{path, line}` it could name, leftmost first. A result reads
  `path:line:text`; a path may hold a colon, or `text` a `:12:`, so the caller takes the first
  that names a file (R13). `git grep`'s `--column` is never used: its column counts bytes.

      iex> Geex.Search.Project.locations("my notes.txt:7:x = 1")
      [{"my notes.txt", 7}]
      iex> Geex.Search.Project.locations("a:b.txt:3:at 4:5: here")
      [{"a:b.txt", 3}, {"a:b.txt:3:at 4", 5}]
      iex> Geex.Search.Project.locations("notes:12:7:text")
      [{"notes", 12}, {"notes:12", 7}]
      iex> Geex.Search.Project.locations("Binary file x matches")
      []
  """
  @spec locations(String.t()) :: [{String.t(), pos_integer()}]
  def locations(line) do
    # A lookahead for the second colon, so `notes:12:7:x` reads both `notes` at 12 and
    # `notes:12` at 7.
    ~r/:(\d+)(?=:)/
    |> Regex.scan(line, return: :index)
    |> Enum.flat_map(fn [{at, _len}, {n_at, n_len}] ->
      path = binary_part(line, 0, at)
      n = String.to_integer(binary_part(line, n_at, n_len))
      if path != "" and n > 0, do: [{path, n}], else: []
    end)
  end
end
