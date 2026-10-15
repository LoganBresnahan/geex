defmodule Geex.Attest.Discovery do
  @moduledoc """
  Tells a hook payload where this geex listens (ADR-0032).

  On start it mints a per-instance token and writes `<dir>/<os_pid>.json`:

      {"v": 1, "url": "http://127.0.0.1:<port>/attest", "token": "…", "pid": <os_pid>}

  `<dir>` is `$XDG_RUNTIME_DIR/geex`, or `<tmp>/geex-<user>` without it, created `0700`; the
  file is `0600`. The payload sends to every live instance's file and skips any whose `pid`
  is gone (a crash skips cleanup). On a clean stop the file is removed, and on start any file
  left by a geex that is no longer running is swept, so a reused pid never gets a stale token.

  The token keeps other local users' processes out. A process running as the same user could
  read it, but it could also write the file directly, so the token is hygiene, not a
  security boundary.
  """

  use GenServer

  require Logger

  @token_key {__MODULE__, :token}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "This instance's token, or `nil` when no discovery file is published."
  @spec token() :: String.t() | nil
  def token, do: :persistent_term.get(@token_key, nil)

  @doc "The discovery directory: `$XDG_RUNTIME_DIR/geex`, else `<tmp>/geex-<user>`."
  @spec default_dir() :: Path.t()
  def default_dir do
    case System.get_env("XDG_RUNTIME_DIR") do
      runtime when is_binary(runtime) and runtime != "" -> Path.join(runtime, "geex")
      _ -> Path.join(System.tmp_dir!(), "geex-" <> (System.get_env("USER") || "user"))
    end
  end

  @impl true
  def init(opts) do
    # Trap exits so a supervisor shutdown runs terminate/2 and removes the file.
    Process.flag(:trap_exit, true)

    url = Keyword.fetch!(opts, :url)
    dir = Keyword.get(opts, :dir, default_dir())
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    os_pid = System.pid() |> String.to_integer()
    file = Path.join(dir, "#{os_pid}.json")

    :persistent_term.put(@token_key, token)
    sweep(dir)

    case publish(dir, file, %{"v" => 1, "url" => url, "token" => token, "pid" => os_pid}) do
      :ok ->
        Logger.info("geex attest: listening at #{url} (discovery #{file})")
        {:ok, %{file: file}}

      {:error, reason} ->
        # The editor runs fine without it; agent writes just stay `:external`.
        Logger.warning("geex attest: could not publish #{file}: #{inspect(reason)}")
        {:ok, %{file: nil}}
    end
  end

  @impl true
  def terminate(_reason, %{file: file}) do
    :persistent_term.erase(@token_key)
    if file, do: File.rm(file)
    :ok
  end

  # A crashed geex (kill -9) leaves its file. The directory is 0700 and ours, so every file in
  # it was written by one of our geex processes: one whose pid is gone is stale.
  defp sweep(dir) do
    for file <- Path.wildcard(Path.join(dir, "*.json")),
        {:ok, bytes} <- [File.read(file)],
        {:ok, %{"pid" => pid}} when is_integer(pid) <- [JSON.decode(bytes)],
        not os_alive?(pid) do
      File.rm(file)
    end

    :ok
  end

  defp os_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  # Write to a temp name and rename into place, so a reader never sees a half-written file;
  # the 0700 directory is what keeps the token from other users in the meantime.
  defp publish(dir, file, contents) do
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, JSON.encode!(contents)),
         :ok <- File.chmod(tmp, 0o600) do
      File.rename(tmp, file)
    end
  end
end
