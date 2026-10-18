defmodule Geex.Edits.Log do
  @moduledoc """
  The edits list's file ([ADR-0034](../../../doc/adr/0034-panes-tree-edits-hold.md) §6,
  amended 2026-10-18), so the list survives a restart.

  **Where.** `$XDG_STATE_HOME/geex/edits.jsonl` (default `~/.local/state/geex/edits.jsonl`),
  `0600` in a `0700` directory, beside the ledgers. One line per row: the file's path, who, when,
  the content's sha256 and the tool call. No file contents.

  **Appending.** Each row added, or upgraded (`outside` becoming an agent's), is one line, written
  by opening the file in append mode, one `write`, and closing it. Several geex instances append
  to the same file: an append-mode write of one short line lands whole, and no instance holds
  the file open between writes. Each write starts with a newline too, so a row never joins a
  torn line left by an earlier failed write.

  **Bounded by rotation.** Past 512 KB (about 2,500 rows) the file is renamed to
  `edits.1.jsonl`, replacing the one before, and the next row starts a new file. `load/1` reads
  both, so the list keeps the newest one to two generations. A rename can't lose a line another
  instance is appending: that line lands in the file under its new name, which is still read.

  **Loading** skips what it can't use and carries on: a last line with no newline (a torn write,
  or one another instance is making now), and any line that isn't a row.
  """

  @rotate_bytes 512 * 1024

  @doc "`$XDG_STATE_HOME/geex/edits.jsonl`, else `~/.local/state/geex/edits.jsonl`."
  @spec default_file() :: Path.t()
  def default_file do
    case System.get_env("XDG_STATE_HOME") do
      state when is_binary(state) and state != "" -> Path.join([state, "geex", "edits.jsonl"])
      _ -> Path.join([System.user_home!(), ".local", "state", "geex", "edits.jsonl"])
    end
  end

  @doc "The previous generation of `file`: `edits.1.jsonl` beside `edits.jsonl`."
  @spec previous(Path.t()) :: Path.t()
  def previous(file), do: String.replace_suffix(file, ".jsonl", ".1.jsonl")

  @doc """
  Append `row` to `file` as one line, then rotate the file if it has grown past `rotate_bytes`.
  """
  @spec append(Path.t(), map(), pos_integer()) :: :ok | {:error, term()}
  def append(file, row, rotate_bytes \\ @rotate_bytes) do
    dir = Path.dirname(file)

    # The line starts with a newline of its own: after a torn write (a full disk, a crash) the
    # file ends mid-line, and a row appended there would join that fragment and be lost with it.
    # Still one write; loading skips the empty lines this leaves.
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, fd} <- :file.open(file, [:append, :binary, :raw]),
         written = :file.write(fd, ["\n", encode(row)]),
         :ok <- :file.close(fd),
         :ok <- written,
         :ok <- File.chmod(file, 0o600) do
      rotate(file, rotate_bytes)
    end
  end

  # Another instance may cross the bound at the same moment: the size is read again just before
  # the rename, so only the one that still finds the file big renames it. A window stays: two
  # instances both read the big size, one renames, a third appends a new small file, and the
  # second renames that over the generation just kept. Unlikely with a few instances; it costs
  # one generation's rows (ADR-0034's amendment).
  defp rotate(file, rotate_bytes) do
    case File.stat(file) do
      {:ok, %{size: size}} when size > rotate_bytes ->
        case File.rename(file, previous(file)) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          error -> error
        end

      _ ->
        :ok
    end
  end

  @doc """
  The rows in `file`'s two generations, oldest first, and how many lines were skipped as
  unusable. A missing file has none.
  """
  @spec load(Path.t()) :: {[map()], non_neg_integer()}
  def load(file) do
    lines = Enum.flat_map([previous(file), file], &complete_lines/1)

    Enum.reduce(lines, {[], 0}, fn line, {rows, bad} ->
      case decode(line) do
        {:ok, row} -> {[row | rows], bad}
        :error -> {rows, bad + 1}
      end
    end)
    |> then(fn {rows, bad} -> {Enum.reverse(rows), bad} end)
  end

  # The lines that end in a newline: a last line without one is still being written, or was torn.
  defp complete_lines(path) do
    case File.read(path) do
      {:ok, bytes} ->
        bytes |> String.split("\n") |> Enum.drop(-1) |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  @doc """
  A row as its line.

      iex> row = %{path: "/r/a.ex", who: :you, at: ~N[2026-10-18 14:46:00], sha256: nil, tool_use: nil}
      iex> line = Geex.Edits.Log.encode(row)
      iex> Geex.Edits.Log.decode(String.trim_trailing(line)) == {:ok, row}
      true
  """
  @spec encode(map()) :: String.t()
  def encode(row) do
    JSON.encode!(%{
      v: 1,
      path: row.path,
      who: encode_who(row.who),
      at: NaiveDateTime.to_iso8601(row.at),
      sha256: row.sha256,
      tool_use: row.tool_use
    }) <> "\n"
  end

  defp encode_who({:agent, who}), do: %{agent: who}
  defp encode_who(who) when who in [:you, :outside], do: Atom.to_string(who)

  @doc """
  A line as its row, or `:error` when it isn't one.

      iex> Geex.Edits.Log.decode(~s|{"v":1,"path":"/a","who":{"agent":{"harness":"claude-code","session":"s1","turn":null,"tool_use":"t1"}},"at":"2026-10-18T14:46:00","sha256":"ab","tool_use":"t1"}|)
      {:ok, %{path: "/a", who: {:agent, %{harness: "claude-code", session: "s1", turn: nil, tool_use: "t1"}}, at: ~N[2026-10-18 14:46:00], sha256: "ab", tool_use: "t1"}}
      iex> Geex.Edits.Log.decode(~s|{"v":1,"path":"/a"|)
      :error
      iex> Geex.Edits.Log.decode(~s|[1, 2]|)
      :error
  """
  @spec decode(String.t()) :: {:ok, map()} | :error
  def decode(line) do
    with {:ok, %{"v" => 1, "path" => path, "who" => who, "at" => at} = m}
         when is_binary(path) and is_binary(at) <- JSON.decode(line),
         {:ok, who} <- decode_who(who),
         {:ok, at} <- NaiveDateTime.from_iso8601(at),
         sha256 when is_nil(sha256) or is_binary(sha256) <- m["sha256"],
         tool_use when is_nil(tool_use) or is_binary(tool_use) <- m["tool_use"] do
      {:ok, %{path: path, who: who, at: at, sha256: sha256, tool_use: tool_use}}
    else
      _ -> :error
    end
  end

  defp decode_who("you"), do: {:ok, :you}
  defp decode_who("outside"), do: {:ok, :outside}

  defp decode_who(%{"agent" => %{"harness" => harness, "session" => session} = a})
       when is_binary(harness) and is_binary(session) do
    who = %{harness: harness, session: session, turn: a["turn"], tool_use: a["tool_use"]}
    who = if a["user_modified"] == true, do: Map.put(who, :user_modified, true), else: who
    {:ok, {:agent, who}}
  end

  defp decode_who(_), do: :error
end
