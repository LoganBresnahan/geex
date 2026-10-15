defmodule Geex.Ledger do
  @moduledoc """
  The durable ledger's file side (ADR-0033): one append-only JSONL file per buffer path, so
  a buffer's history, blame and unsaved edits survive quitting or a crash.

  **Where.** `<dir>/<key>.jsonl`, where `<dir>` is `$XDG_STATE_HOME/geex/ledger` (default
  `~/.local/state/geex/ledger`), created `0700`, and `<key>` is the first 16 hex characters of
  the sha256 of the absolute path. Files are `0600`: a ledger holds file contents, including
  text you deleted.

  **Lazily created.** Nothing is written for a buffer that never changes. The first transition
  opens the file (writing the `open` entry with the base text when it's new).

  **One writer.** The first buffer to write takes `<key>.lock` (its OS pid and Erlang pid). A
  second geex on the same file gets `{:error, {:locked, owner}}`, and its edits go unlogged,
  as the buffer then says. A lock whose owner is gone is stale and taken over.

  **Crash safety.** Each entry is one `write` of one line on a raw file in append mode, so it
  survives a geex crash. `sync/1` fsyncs; the buffer calls it at most once a second while
  entries are pending, and on save and close.

  **Loading** (`load/2`): a final line without its newline is a torn write, dropped and cut off
  the file. An entry replay can't use stops it (`Geex.Ledger.Restore`); the original file is
  kept as `<key>.jsonl.corrupt-<unix time>` and the ledger is cut back to the usable prefix.
  """

  alias Geex.{EditorState, History}
  alias Geex.Ledger.{Codec, Restore}

  require Logger

  defstruct [:dir, :path, :fd, state: :closed, locked: false, unsynced: false]

  @type t :: %__MODULE__{
          dir: Path.t(),
          path: String.t(),
          fd: term() | nil,
          state: :closed | :open | :off,
          locked: boolean(),
          unsynced: boolean()
        }

  @doc "`$XDG_STATE_HOME/geex/ledger`, else `~/.local/state/geex/ledger`."
  @spec default_dir() :: Path.t()
  def default_dir do
    case System.get_env("XDG_STATE_HOME") do
      state when is_binary(state) and state != "" -> Path.join([state, "geex", "ledger"])
      _ -> Path.join([System.user_home!(), ".local", "state", "geex", "ledger"])
    end
  end

  @doc "The ledger file for `path` in `dir`."
  @spec file(Path.t(), String.t()) :: Path.t()
  def file(dir, path), do: Path.join(dir, key(path) <> ".jsonl")

  defp key(path), do: path |> Path.expand() |> Restore.sha256() |> binary_part(0, 16)

  defp lock(dir, path), do: Path.join(dir, key(path) <> ".lock")

  @doc "A ledger handle for `path`; nothing touches disk until the first `append/3`."
  @spec new(Path.t(), String.t()) :: t()
  def new(dir, path), do: %__MODULE__{dir: dir, path: Path.expand(path)}

  @doc """
  Read and replay this ledger's file. `:none` when there isn't one, or when it is unusable from
  its first line (then it is set aside, never deleted). Otherwise the restored result, with
  `stopped` naming why replay ended early, if it did; the file has then been cut back.

  Only the lock holder repairs the file (cutting a torn line, setting a corrupt one aside).
  Without the lock another geex may be mid-write, so the file is only read.
  """
  @spec load(t()) :: :none | {:ok, Restore.result()}
  def load(%__MODULE__{} = ledger) do
    file = file(ledger.dir, ledger.path)

    case File.read(file) do
      {:ok, bytes} -> replay(file, bytes, ledger.locked)
      {:error, :enoent} -> :none
      {:error, reason} -> unusable(file, "unreadable: #{inspect(reason)}", false)
    end
  end

  defp replay(file, bytes, repair?) do
    {lines, complete_bytes} = split_lines(bytes)

    if repair? and complete_bytes < byte_size(bytes) do
      Logger.warning("geex ledger: dropped a torn final line in #{file}")
      truncate(file, complete_bytes)
    end

    case Restore.restore(lines) do
      {:ok, %{stopped: nil} = result} ->
        {:ok, result}

      {:ok, %{stopped: reason, valid_bytes: valid} = result} when repair? ->
        aside = set_aside(file, :copy)
        truncate(file, valid)

        Logger.warning(
          "geex ledger: replay of #{file} stopped (#{reason}); kept the original as #{aside}"
        )

        {:ok, result}

      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        unusable(file, reason, repair?)
    end
  end

  defp unusable(file, reason, exists?) do
    aside = if exists?, do: set_aside(file, :move)
    Logger.warning("geex ledger: #{file} is unusable (#{reason}); set aside as #{aside}")
    :none
  end

  # Complete lines with the byte offset just past each newline, and how many bytes they span.
  defp split_lines(bytes) do
    {lines, offset} =
      bytes
      |> :binary.split("\n", [:global])
      |> Enum.drop(-1)
      |> Enum.map_reduce(0, fn line, offset ->
        next = offset + byte_size(line) + 1
        {{line, next}, next}
      end)

    {lines, offset}
  end

  defp truncate(file, bytes) do
    with {:ok, fd} <- :file.open(file, [:read, :write, :binary, :raw]) do
      :file.position(fd, bytes)
      :file.truncate(fd)
      :file.close(fd)
    end
  end

  defp set_aside(file, how) do
    aside = "#{file}.corrupt-#{System.os_time(:second)}"
    if how == :copy, do: File.cp(file, aside), else: File.rename(file, aside)
    aside
  end

  @doc """
  Append one transition. Opens the file (and takes the lock) on first use; `history` supplies
  the base text for a new file's `open` entry. A ledger that can't be opened turns `:off`, and
  stays off for this buffer.
  """
  @spec append(t(), Codec.entry(), History.t()) :: t()
  def append(%__MODULE__{state: :off} = ledger, _entry, _history), do: ledger

  def append(%__MODULE__{state: :closed} = ledger, entry, history) do
    case open(ledger, history) do
      {:ok, ledger} -> append(ledger, entry, history)
      {:error, reason} -> off(ledger, reason)
    end
  end

  def append(%__MODULE__{state: :open, fd: fd} = ledger, entry, _history) do
    case :file.write(fd, Codec.encode(entry, DateTime.utc_now())) do
      :ok -> %{ledger | unsynced: true}
      {:error, reason} -> off(ledger, {:write, reason})
    end
  end

  @doc "Whether the ledger can't record (another geex holds it, or it couldn't be opened)."
  @spec off?(t()) :: boolean()
  def off?(%__MODULE__{state: state}), do: state == :off

  @doc """
  Take the path's lock now, before loading, so this buffer may repair and append to the file.
  `{:error, {:locked, owner}}` when another live geex holds it: the ledger is then `:off`.
  """
  @spec claim(t()) :: {:ok, t()} | {:error, term(), t()}
  def claim(%__MODULE__{} = ledger) do
    with :ok <- ensure_dir(ledger.dir), :ok <- take_lock(lock(ledger.dir, ledger.path)) do
      {:ok, %{ledger | locked: true}}
    else
      {:error, reason} -> {:error, reason, %{ledger | state: :off}}
    end
  end

  @doc "fsync any pending entries."
  @spec sync(t()) :: t()
  def sync(%__MODULE__{state: :open, fd: fd, unsynced: true} = ledger) do
    :file.sync(fd)
    %{ledger | unsynced: false}
  end

  def sync(ledger), do: ledger

  @doc "A clean close: write the `close` entry (if the file is open), fsync, release the lock."
  @spec close(t(), History.t()) :: t()
  def close(%__MODULE__{} = ledger, history) do
    ledger =
      if ledger.state == :open do
        entry =
          {:close,
           %{
             text_sha256: Restore.sha256(History.text(history)),
             synced_sha256: Restore.sha256(history.synced)
           }}

        ledger = ledger |> append(entry, history) |> sync()
        :file.close(ledger.fd)
        %{ledger | fd: nil, state: :closed}
      else
        ledger
      end

    release(ledger)
  end

  defp release(%__MODULE__{locked: true} = ledger) do
    File.rm(lock(ledger.dir, ledger.path))
    %{ledger | locked: false}
  end

  defp release(ledger), do: ledger

  @doc """
  The buffer moved to `new_path`: record it, then move the ledger (and its lock) to the new
  path's key. An existing ledger already at that key is set aside first.
  """
  @spec rename(t(), String.t(), History.t()) :: t()
  def rename(%__MODULE__{state: :off} = ledger, new_path, _history),
    do: %{ledger | path: Path.expand(new_path)}

  def rename(%__MODULE__{} = ledger, new_path, history) do
    new_path = Path.expand(new_path)
    from = file(ledger.dir, ledger.path)
    to = file(ledger.dir, new_path)

    ledger =
      if ledger.state == :open do
        ledger = ledger |> append({:rename, new_path}, history) |> sync()
        :file.close(ledger.fd)
        %{ledger | fd: nil, state: :closed}
      else
        ledger
      end

    ledger = release(ledger)

    if File.exists?(from) do
      if File.exists?(to), do: set_aside(to, :move)
      File.rename(from, to)
    end

    %{ledger | path: new_path}
  end

  defp open(ledger, history) do
    file = file(ledger.dir, ledger.path)

    with {:ok, ledger} <- if(ledger.locked, do: {:ok, ledger}, else: claim_quietly(ledger)),
         new? = not File.exists?(file),
         {:ok, fd} <- :file.open(file, [:append, :binary, :raw]),
         :ok <- File.chmod(file, 0o600) do
      ledger = %{ledger | fd: fd, state: :open}

      if new? do
        geex = :geex |> Application.spec(:vsn) |> to_string()
        base = EditorState.text(history.base)
        {:ok, append(ledger, {:open, %{path: ledger.path, base: base, geex: geex}}, history)}
      else
        {:ok, ledger}
      end
    end
  end

  defp claim_quietly(ledger) do
    case claim(ledger) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason, _off} -> {:error, reason}
    end
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp off(ledger, reason) do
    Logger.warning("geex ledger: not recording #{ledger.path}: #{inspect(reason)}")
    if ledger.fd, do: :file.close(ledger.fd)
    release(%{ledger | fd: nil, state: :off})
  end

  # The lock holds "<os pid> <erlang pid>". It is stale when its owner is gone: for this OS
  # process, when that Erlang process is dead; for another, when that OS process is.
  defp take_lock(lock) do
    owner = "#{System.pid()} #{:erlang.pid_to_list(self())}"

    case File.write(lock, owner, [:exclusive]) do
      :ok ->
        File.chmod(lock, 0o600)

      {:error, :eexist} ->
        case File.read(lock) do
          {:ok, ^owner} ->
            :ok

          {:ok, held} ->
            if stale?(held) do
              File.rm(lock)
              take_lock_once(lock, owner)
            else
              {:error, {:locked, held}}
            end

          {:error, :enoent} ->
            take_lock_once(lock, owner)

          {:error, reason} ->
            {:error, {:lock, reason}}
        end

      {:error, reason} ->
        {:error, {:lock, reason}}
    end
  end

  defp take_lock_once(lock, owner) do
    case File.write(lock, owner, [:exclusive]) do
      :ok -> File.chmod(lock, 0o600)
      {:error, :eexist} -> {:error, {:locked, "taken concurrently"}}
      {:error, reason} -> {:error, {:lock, reason}}
    end
  end

  defp stale?(held) do
    with [os_pid, erl_pid] <- String.split(held, " ", parts: 2),
         {_int, ""} <- Integer.parse(os_pid) do
      if os_pid == System.pid(),
        do: not alive_local?(erl_pid),
        else: not os_alive?(os_pid)
    else
      _ -> true
    end
  end

  defp alive_local?(erl_pid) do
    Process.alive?(:erlang.list_to_pid(String.to_charlist(erl_pid)))
  rescue
    ArgumentError -> false
  end

  defp os_alive?(os_pid) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end
end
