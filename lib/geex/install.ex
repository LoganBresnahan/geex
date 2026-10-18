defmodule Geex.Install do
  @moduledoc """
  Installs a grammar or a theme ([ADR-0040](../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §3, §4): from the catalog this geex embeds, or from a local package. One path for both kinds:

  1. **Fetch** the package: the catalog entry's URL, or under `GEEX_CATALOG_URL` (a `file://`
     directory or an `http(s)://` base) when set, for testing before a release exists. Over
     HTTP(S) it is OTP's `:httpc`, with `:ssl` verifying the peer against the system's CA store
     and the host name, wildcards included (GitHub redirects a release asset to a CDN host),
     redirects followed only from https to https, and at most #{32} MB read: a host that sends
     more is cut off before anything is written.
  2. **Check** its sha256 against the catalog's. A local package has nothing to check against:
     its own hash is recorded.
  3. **Unpack** it in memory, after checking every entry: a file, a flat name from the
     package's expected set (`parser.wasm`, `highlights.scm`, `manifest.json`, `LICENSE*`,
     `NOTICE*`; a theme's `<name>.json`), no repeats, at most 64 MB unpacked in all. Every file
     is written by geex as a plain file, so an entry the zip marks as a symlink lands as a file
     holding its target's name, never a link. A local zip is untrusted, so it is unpacked in a
     process whose heap is capped: a zip whose entries lie about their size is killed, not the
     editor.
  4. **Validate** it: the manifest names the expected kind and name; a grammar's ABI is one this
     geex loads and the NIF accepts its wasm and query; a theme passes `Geex.Theme.from_json/1`.
  5. **Write** it to a temporary directory beside its place, `installed.json` (its sha256, its
     source, when) last, and rename it into place. A failure leaves what was there.

  Nothing here runs at startup: only `geex install` and the settings view call it, on the
  user's word. `:inets` and `:ssl` start only when a download begins.
  """

  alias Geex.Catalog
  alias Geex.Catalog.Package
  alias Geex.Highlight.Grammars
  alias Geex.Installed

  require Logger

  @max_download 32 * 1024 * 1024
  @max_unpacked 64 * 1024 * 1024
  @max_redirects 5
  @timeout_ms 120_000

  @type kind :: :grammar | :theme
  @type result :: %{kind: kind(), name: String.t(), display: String.t(), sha256: String.t()}

  @doc """
  Install the catalog's package named `name` (a grammar's or a theme's name). Returns what was
  installed, or `{:error, reason}`, with what was there before left in place.
  """
  @spec install(String.t()) :: {:ok, result()} | {:error, term()}
  def install(name) do
    case catalog_entry(name) do
      {kind, entry} ->
        with {:ok, zip} <- fetch(url(entry)),
             :ok <- verify(zip, entry["sha256"]),
             {:ok, files} <- unpack(zip, kind, name),
             {:ok, manifest} <- validate(kind, name, files) do
          put(kind, manifest, files, %{"source" => "catalog", "sha256" => entry["sha256"]})
        end

      nil ->
        {:error, {:not_in_catalog, name}}
    end
  end

  @doc """
  Install a local package: a directory holding a package's files, or its `.zip`. It names its
  own kind and name in its `manifest.json`; its hash is recorded as given.
  """
  @spec install_path(Path.t()) :: {:ok, result()} | {:error, term()}
  def install_path(path) do
    with {:ok, zip} <- local_zip(path),
         {:ok, %{"kind" => kind_s, "name" => name}} <- peek_manifest(zip),
         {:ok, kind} <- kind(kind_s),
         {:ok, files} <- unpack(zip, kind, name),
         {:ok, manifest} <- validate(kind, name, files) do
      put(kind, manifest, files, %{
        "source" => "local",
        "path" => Path.expand(path),
        "sha256" => Package.sha256(zip)
      })
    end
  end

  @doc """
  Where a catalog entry is fetched from: its URL, or its asset under `GEEX_CATALOG_URL` when
  that is set.
  """
  @spec url(map()) :: String.t()
  def url(entry) do
    case System.get_env("GEEX_CATALOG_URL") do
      empty when empty in [nil, ""] -> entry["url"]
      base -> String.trim_trailing(base, "/") <> "/" <> entry["asset"]
    end
  end

  defp catalog_entry(name) do
    cond do
      entry = Catalog.grammar(name) -> {:grammar, entry}
      entry = Catalog.theme(name) -> {:theme, entry}
      true -> nil
    end
  end

  defp kind("grammar"), do: {:ok, :grammar}
  defp kind("theme"), do: {:ok, :theme}
  defp kind(other), do: {:error, {:bad_manifest, {:kind, other}}}

  ## Fetching

  @doc false
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch("file://" <> path), do: read_capped(path)
  def fetch("https://" <> _ = url), do: http_get(url, @max_redirects)
  def fetch("http://" <> _ = url), do: http_get(url, @max_redirects)
  def fetch(url), do: {:error, {:bad_url, url}}

  defp read_capped(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_download -> File.read(path)
      {:ok, %{type: :regular}} -> {:error, :too_large}
      {:ok, _} -> {:error, {:not_a_file, path}}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp http_get(_url, -1), do: {:error, :too_many_redirects}

  defp http_get(url, redirects_left) do
    with :ok <- start_http() do
      uri = URI.parse(url)
      headers = [{~c"user-agent", ~c"geex"}]

      http_opts = [
        ssl: ssl_opts(uri.host),
        autoredirect: false,
        timeout: @timeout_ms,
        connect_timeout: 15_000
      ]

      case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts,
             sync: false,
             stream: :self,
             body_format: :binary
           ) do
        {:ok, ref} -> receive_body(ref, url, redirects_left, [], 0)
        {:error, reason} -> {:error, {:http, reason}}
      end
    end
  end

  defp start_http do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    else
      {:error, reason} -> {:error, {:no_http, reason}}
    end
  end

  # Verify the server's certificate against the system's CA store, and its host name, wildcard
  # names included: a release asset redirects to *.githubusercontent.com.
  defp ssl_opts(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 4
    ]
  end

  defp receive_body(ref, url, redirects_left, acc, size) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        receive_body(ref, url, redirects_left, acc, size)

      {:http, {^ref, :stream, part}} ->
        size = size + byte_size(part)

        if size > @max_download do
          :httpc.cancel_request(ref)
          {:error, :too_large}
        else
          receive_body(ref, url, redirects_left, [acc | part], size)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, IO.iodata_to_binary(acc)}

      # A response that isn't streamed: a redirect, an error, or a small 200.
      {:http, {^ref, {{_version, status, _reason}, headers, body}}} ->
        response(status, headers, body, url, redirects_left)

      {:http, {^ref, {:error, reason}}} ->
        {:error, {:http, reason}}
    after
      @timeout_ms ->
        :httpc.cancel_request(ref)
        {:error, :timeout}
    end
  end

  defp response(200, _headers, body, _url, _left) when byte_size(body) <= @max_download,
    do: {:ok, body}

  defp response(200, _headers, _body, _url, _left), do: {:error, :too_large}

  defp response(status, headers, _body, url, left) when status in [301, 302, 303, 307, 308] do
    case List.keyfind(headers, ~c"location", 0) do
      {_, location} ->
        with {:ok, next} <- redirect(url, List.to_string(location)), do: http_get(next, left - 1)

      nil ->
        {:error, {:http_status, status}}
    end
  end

  defp response(status, _headers, _body, _url, _left), do: {:error, {:http_status, status}}

  @doc """
  Where a redirect from `url` to `location` goes, if it may be followed: never from https to
  anything else.

      iex> Geex.Install.redirect("https://github.com/a/b", "https://cdn.example/x")
      {:ok, "https://cdn.example/x"}
      iex> Geex.Install.redirect("https://github.com/a/b", "/c")
      {:ok, "https://github.com/c"}
      iex> Geex.Install.redirect("https://github.com/a/b", "http://cdn.example/x")
      {:error, {:insecure_redirect, "http://cdn.example/x"}}
  """
  @spec redirect(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def redirect(url, location) do
    next = URI.merge(url, location) |> URI.to_string()

    if URI.parse(url).scheme == "https" and URI.parse(next).scheme != "https",
      do: {:error, {:insecure_redirect, next}},
      else: {:ok, next}
  end

  @doc false
  @spec verify(binary(), String.t()) :: :ok | {:error, term()}
  def verify(zip, sha256) do
    case Package.sha256(zip) do
      ^sha256 -> :ok
      other -> {:error, {:sha256_mismatch, other}}
    end
  end

  ## Unpacking

  @doc """
  The files in a package `zip` of `kind` named `name`, after checking every entry: a plain file,
  a flat name the package may have, no repeats, at most #{64} MB in all. Unpacked in a process
  with a capped heap, so a zip whose entries lie about their size can't take the editor down.
  """
  @spec unpack(binary(), kind(), String.t()) :: {:ok, [{String.t(), binary()}]} | {:error, term()}
  def unpack(zip, kind, name) do
    with :ok <- valid_name(name),
         {:ok, entries} <- list(zip),
         :ok <- check_entries(entries, kind, name) do
      extract(zip, Enum.map(entries, & &1.name))
    end
  end

  defp valid_name(name) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, name),
      do: :ok,
      else: {:error, {:bad_name, name}}
  end

  defp list(zip) do
    case :zip.list_dir(zip) do
      {:ok, items} ->
        {:ok,
         for {:zip_file, name, info, _comment, _offset, _size} <- items do
           %{name: List.to_string(name), size: elem(info, 1), type: elem(info, 2)}
         end}

      {:error, reason} ->
        {:error, {:bad_zip, reason}}
    end
  rescue
    _ -> {:error, {:bad_zip, :unreadable}}
  end

  defp check_entries(entries, kind, name) do
    names = Enum.map(entries, & &1.name)
    total = Enum.sum(Enum.map(entries, & &1.size))

    cond do
      bad = Enum.find(entries, &(not allowed?(&1, kind, name))) ->
        {:error, {:bad_entry, bad.name}}

      length(Enum.uniq(names)) != length(names) ->
        {:error, :repeated_entry}

      total > @max_unpacked ->
        {:error, :too_large}

      "manifest.json" not in names ->
        {:error, {:missing, "manifest.json"}}

      true ->
        :ok
    end
  end

  # A file (not a directory entry) with a flat name the package may carry. A symlink can't get
  # through: `:zip` reports one as a regular file, and its "content" (the target's name) is
  # written as a plain file by `put/4`, which never makes a link.
  defp allowed?(%{name: n, type: type}, kind, name) do
    flat? = n != "" and not String.contains?(n, ["/", "\\", <<0>>]) and n not in [".", ".."]
    type == :regular and flat? and expected?(n, kind, name)
  end

  defp expected?(n, kind, name) do
    n == "manifest.json" or String.starts_with?(n, ["LICENSE", "NOTICE"]) or
      case kind do
        :grammar -> n in ["parser.wasm", "highlights.scm"]
        :theme -> n == name <> ".json"
      end
  end

  defp extract(zip, names) do
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(4 * @max_unpacked, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        result = :zip.unzip(zip, [:memory, file_list: Enum.map(names, &String.to_charlist/1)])
        exit({:unzipped, result})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:unzipped, {:ok, files}}} ->
        files = for {n, bytes} <- files, do: {List.to_string(n), bytes}

        if Enum.sum(Enum.map(files, &byte_size(elem(&1, 1)))) > @max_unpacked,
          do: {:error, :too_large},
          else: {:ok, files}

      {:DOWN, ^ref, :process, ^pid, {:unzipped, {:error, reason}}} ->
        {:error, {:bad_zip, reason}}

      {:DOWN, ^ref, :process, ^pid, _killed} ->
        {:error, :too_large}
    after
      @timeout_ms ->
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  defp local_zip(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> zip_dir(path)
      {:ok, %{type: :regular}} -> read_capped(path)
      {:ok, _} -> {:error, {:not_a_file, path}}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  # A directory's package files, zipped the catalog's way, so its hash is the zip's.
  defp zip_dir(dir) do
    with {:ok, names} <- File.ls(dir) do
      files =
        for n <- Enum.sort(names),
            n != "installed.json",
            path = Path.join(dir, n),
            File.regular?(path),
            do: {n, File.read!(path)}

      {:ok, Package.zip(files)}
    end
  end

  # The manifest, read before unpacking, to learn the kind and name it checks the rest against.
  defp peek_manifest(zip) do
    with {:ok, [{_, json}]} <- :zip.unzip(zip, [:memory, file_list: [~c"manifest.json"]]),
         true <- byte_size(json) <= 64 * 1024,
         {:ok, %{} = manifest} <- JSON.decode(json) do
      {:ok, manifest}
    else
      _ -> {:error, {:bad_manifest, :unreadable}}
    end
  rescue
    _ -> {:error, {:bad_manifest, :unreadable}}
  end

  ## Validating

  defp validate(kind, name, files) do
    files = Map.new(files)

    with {:ok, manifest} <- decode_manifest(files["manifest.json"]),
         :ok <- same(manifest, kind, name) do
      check_package(kind, name, manifest, files)
    end
  end

  defp decode_manifest(json) do
    case JSON.decode(json || "") do
      {:ok, %{} = manifest} -> {:ok, manifest}
      _ -> {:error, {:bad_manifest, :unreadable}}
    end
  end

  defp same(%{"kind" => k, "name" => n}, kind, name) do
    if k == Atom.to_string(kind) and n == name,
      do: :ok,
      else: {:error, {:bad_manifest, {:names, k, n}}}
  end

  defp same(_manifest, _kind, _name), do: {:error, {:bad_manifest, :no_kind_or_name}}

  defp check_package(:grammar, name, manifest, files) do
    abi = manifest["abi"]
    endings = manifest["extensions"] || []
    names = manifest["filenames"] || []

    cond do
      not (is_list(endings) and is_list(names) and Enum.all?(endings ++ names, &is_binary/1)) ->
        {:error, {:bad_manifest, :file_names}}

      not (is_integer(abi) and abi in Grammars.abi()) ->
        {:error, {:abi, abi}}

      not (is_binary(files["parser.wasm"]) and is_binary(files["highlights.scm"])) ->
        {:error, {:missing, "parser.wasm or highlights.scm"}}

      true ->
        opts = if dir = Grammars.cache_dir(), do: [cache_dir: dir], else: []

        case TreeSitterWasm.load_grammar(
               files["parser.wasm"],
               name,
               files["highlights.scm"],
               opts
             ) do
          {:ok, _grammar} -> {:ok, manifest}
          {:error, message} -> {:error, {:engine, message}}
        end
    end
  end

  defp check_package(:theme, name, manifest, files) do
    with json when is_binary(json) <- files[name <> ".json"],
         {:ok, data} <- JSON.decode(json),
         {:ok, theme} <- Geex.Theme.from_json(data) do
      {:ok, Map.put_new(manifest, "appearance", Atom.to_string(theme.appearance))}
    else
      nil -> {:error, {:missing, name <> ".json"}}
      {:error, reason} -> {:error, {:bad_theme, reason}}
    end
  end

  ## Writing

  defp put(kind, manifest, files, record) do
    name = manifest["name"]
    target = Installed.dir(kind, name)
    parent = Path.dirname(target)
    tag = System.unique_integer([:positive])
    tmp = Path.join(parent, ".#{name}.new-#{tag}")
    old = Path.join(parent, ".#{name}.old-#{tag}")
    record = Map.put(record, "installed_at", DateTime.utc_now() |> DateTime.to_iso8601())

    try do
      File.mkdir_p!(tmp)
      for {n, bytes} <- files, do: File.write!(Path.join(tmp, n), bytes)
      File.write!(Path.join(tmp, "installed.json"), JSON.encode!(record))
      if File.exists?(target), do: File.rename!(target, old)
      File.rename!(tmp, target)
      File.rm_rf(old)
      installed(kind, name)

      {:ok,
       %{kind: kind, name: name, display: manifest["display"] || name, sha256: record["sha256"]}}
    rescue
      e in File.Error ->
        File.rm_rf(tmp)
        if File.exists?(old) and not File.exists?(target), do: File.rename(old, target)
        {:error, {:write, e.reason, e.path}}
    end
  end

  # Tell this VM: read the directories again, drop the replaced grammar's compiled handle, and
  # let the editor (if one runs) highlight what it now can.
  defp installed(kind, name) do
    Installed.refresh()
    if kind == :grammar, do: Grammars.forget(name)
    Logger.info("geex install: #{kind} #{name} installed")

    case Process.whereis(Geex.Loop) do
      nil -> :ok
      loop -> send(loop, {:geex_installed, kind, name})
    end
  end

  @doc "A one-line description of an install's failure, for the terminal or the status line."
  @spec describe(term()) :: String.t()
  def describe({:not_in_catalog, name}),
    do: "#{name} isn't in this geex's catalog (geex install --list)"

  def describe({:sha256_mismatch, _}),
    do: "the download doesn't match the catalog's sha256; nothing installed"

  def describe(:too_large), do: "the package is larger than geex accepts"
  def describe({:http_status, status}), do: "the server answered #{status}"
  def describe({:http, reason}), do: "the download failed: #{inspect(reason)}"
  def describe({:insecure_redirect, url}), do: "refused a redirect from https to #{url}"
  def describe(:too_many_redirects), do: "too many redirects"
  def describe(:timeout), do: "the download timed out"

  def describe({:abi, abi}),
    do: "built for tree-sitter ABI #{inspect(abi)}; this geex loads 13-15"

  def describe({:engine, message}), do: "the grammar doesn't load: #{message}"
  def describe({:bad_entry, name}), do: "the package holds a file it shouldn't: #{inspect(name)}"
  def describe({:bad_name, name}), do: "not a package name: #{inspect(name)}"
  def describe({:read, reason}), do: "can't read it: #{:file.format_error(reason)}"
  def describe({:write, reason, path}), do: "can't write #{path}: #{:file.format_error(reason)}"
  def describe(other), do: inspect(other)
end
