defmodule Geex.Disk do
  @moduledoc """
  The user's files, read, written and looked at without OTP's file server (BUG-22, ADR-0035's
  2026-11-18 amendment).

  Elixir's `File` calls that aren't `:raw` all go through one process, `file_server_2`, which
  makes each call itself: one that never returns (a read of a FIFO put in place of a file, any
  call on a network disk that stalled) holds it, and every other such call in the VM waits
  behind it with no time limit, on any file. Geex's key loop makes some (`open` asks whether the
  file is there), so one bad file could leave no key working. Every call here runs in the caller
  instead (`:raw`, or `:prim_file`, which the file server itself calls, where `:file` has no raw
  form): a call that hangs holds only the process that made it.

  And a FIFO, a device or a socket is never opened: `read/1` and `write/2` answer
  `{:error, :not_regular}` at once, where opening one would wait for a writer or a reader that may
  never come (opening a buffer already left them empty). A directory reads as `File.read/1`
  says, `{:error, :eisdir}`. The look and the open aren't one step (OTP has no open that doesn't
  wait): a FIFO put in the file's place between them holds the caller, never the file server.

  "Holds only the caller" lasts until ten calls hang: each keeps one of the VM's dirty I/O
  schedulers (10 by default) until it returns, and with all ten held every other file call
  waits, the terminal's writes among them (mod-verify's probe).

  Geex's own files (the ledger, settings, the log, the last session, under `$XDG_STATE_HOME` and
  `$XDG_CONFIG_HOME`) stay on `File`: no file of the user's can hold the file server now.
  """

  @doc """
  The file's bytes, as `File.read/1` gives them, or `{:error, :not_regular}` for a FIFO, a device
  or a socket (a link to one too), which is never opened.
  """
  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix() | :not_regular}
  def read(path) do
    path = IO.chardata_to_string(path)

    with :ok <- openable(path), do: :file.read_file(path, [:raw])
  end

  @doc """
  Write `data` to the file as `File.write/2` does (made if it isn't there), or
  `{:error, :not_regular}` when a FIFO, a device or a socket is there, which is never opened.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix() | :not_regular}
  def write(path, data) do
    path = IO.chardata_to_string(path)

    case openable(path) do
      {:error, :enoent} -> :file.write_file(path, data, [:raw])
      :ok -> :file.write_file(path, data, [:raw])
      error -> error
    end
  end

  # A FIFO waits on open for the other end, a device or a socket as it pleases: only a regular
  # file (or a directory, which fails at once as it always did) is opened.
  defp openable(path) do
    case :file.read_file_info(path, [:raw]) do
      {:ok, info} when elem(info, 2) in [:regular, :directory] -> :ok
      {:ok, _fifo_device_or_socket} -> {:error, :not_regular}
      error -> error
    end
  end

  @doc "`File.exists?/1`, without the file server."
  @spec exists?(Path.t()) :: boolean()
  def exists?(path), do: File.exists?(path, [:raw])

  @doc "`File.regular?/1`, without the file server."
  @spec regular?(Path.t()) :: boolean()
  def regular?(path), do: File.regular?(path, [:raw])

  @doc "`File.dir?/1`, without the file server."
  @spec dir?(Path.t()) :: boolean()
  def dir?(path), do: File.dir?(path, [:raw])

  @doc "`File.stat/1`, without the file server (times in UTC, as `File.stat/1`'s)."
  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path), do: info(:read_file_info, path)

  @doc "`File.lstat/1`, without the file server: a link is the link, not what it names."
  @spec lstat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def lstat(path), do: info(:read_link_info, path)

  defp info(fun, path) do
    case apply(:file, fun, [IO.chardata_to_string(path), [:raw, time: :universal]]) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      error -> error
    end
  end

  @doc "`File.ls/1`, without the file server."
  @spec ls(Path.t()) :: {:ok, [String.t()]} | {:error, File.posix()}
  def ls(path) do
    case :prim_file.list_dir(IO.chardata_to_string(path)) do
      {:ok, names} -> {:ok, Enum.map(names, &IO.chardata_to_string/1)}
      error -> error
    end
  end

  @doc "`File.rename/2`, without the file server."
  @spec rename(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  def rename(from, to),
    do: :prim_file.rename(IO.chardata_to_string(from), IO.chardata_to_string(to))

  @doc "`File.rm/1`, without the file server."
  @spec rm(Path.t()) :: :ok | {:error, File.posix()}
  def rm(path), do: :file.delete(IO.chardata_to_string(path), [:raw])

  @doc "`File.rmdir/1`, without the file server."
  @spec rmdir(Path.t()) :: :ok | {:error, File.posix()}
  def rmdir(path), do: :prim_file.del_dir(IO.chardata_to_string(path))

  @doc "`File.mkdir_p/1`, without the file server."
  @spec mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(path), do: path |> IO.chardata_to_string() |> make_dirs()

  defp make_dirs(path) do
    parent = Path.dirname(path)

    cond do
      dir?(path) ->
        :ok

      # `/`, or `.` for a relative path: nothing above it to make.
      parent == path ->
        :ok

      true ->
        _ = make_dirs(parent)

        case :prim_file.make_dir(path) do
          {:error, :eexist} = error -> if dir?(path), do: :ok, else: error
          other -> other
        end
    end
  end

  @doc """
  `:file.read_link_all/1`, without the file server: a link's target, a charlist (or a binary
  for a name that isn't valid in the file name encoding), or `{:error, posix}` (`:einval` for
  something that isn't a link).
  """
  @spec read_link_all(Path.t()) :: {:ok, charlist() | binary()} | {:error, File.posix()}
  def read_link_all(path), do: :prim_file.read_link_all(path)
end
