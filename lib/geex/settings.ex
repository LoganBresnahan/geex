defmodule Geex.Settings do
  @moduledoc """
  What the settings view (`Alt+Y`) keeps across starts ([ADR-0040](../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §7): the theme, whether the mouse starts on, and whether the file tree and the edits pane
  start shown. Stored in `$XDG_CONFIG_HOME/geex/settings.json` (default
  `~/.config/geex/settings.json`), which geex writes itself; the hand-edited `config.toml`
  (ADR-0025), when it exists, is to be read over it.

  A missing or unreadable file is no settings: geex starts with its defaults. A write goes to a
  temporary file beside it and is renamed in, so a crash leaves the old file or the new one.
  """

  @type t :: %{optional(String.t()) => term()}

  @doc "The file: `$XDG_CONFIG_HOME/geex/settings.json`, or the app's `settings_path` (tests)."
  @spec path() :: Path.t()
  def path do
    case {Application.get_env(:geex, :settings_path), System.get_env("XDG_CONFIG_HOME")} do
      {path, _} when is_binary(path) -> path
      {nil, xdg} when xdg in [nil, ""] -> Path.expand("~/.config/geex/settings.json")
      {nil, xdg} -> Path.join([xdg, "geex", "settings.json"])
    end
  end

  @doc "The settings, or `%{}` when there are none (or the file can't be read)."
  @spec load() :: t()
  def load do
    with {:ok, json} <- File.read(path()),
         {:ok, %{} = settings} <- JSON.decode(json) do
      settings
    else
      _ -> %{}
    end
  end

  @doc """
  Set `key` to `value` and write the file. Returns `:ok` or `{:error, reason}`. A file that is
  there but isn't a JSON object is left alone (`{:error, :unreadable}`): rewriting it with only
  this key would lose the rest.
  """
  @spec put(String.t(), term()) :: :ok | {:error, term()}
  def put(key, value) do
    file = path()

    with {:ok, current} <- current(file) do
      write(file, Map.put(current, key, value))
    end
  end

  defp current(file) do
    case File.read(file) do
      {:ok, json} ->
        case JSON.decode(json) do
          {:ok, %{} = settings} -> {:ok, settings}
          _ -> {:error, :unreadable}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(file, settings) do
    tmp = file <> ".tmp-#{System.pid()}"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, JSON.encode!(settings) <> "\n"),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end
end
