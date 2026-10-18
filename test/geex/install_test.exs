defmodule Geex.InstallTest do
  # Installing grammars and themes (ADR-0040 §3, §4): the one install path, its checks, and the
  # rule that only an install touches the network. Each test has its own data directory (the
  # app's `data_dir`), so not async.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Geex.{Highlight, Install, Installed, Theme}
  alias Geex.Catalog.Package
  alias Geex.Highlight.Grammars

  doctest Install

  @json_dir Application.app_dir(:geex, "priv/grammars/json")

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_install_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:geex, :data_dir)
    Application.put_env(:geex, :data_dir, Path.join(dir, "data"))
    Installed.refresh()

    on_exit(fn ->
      Application.put_env(:geex, :data_dir, previous)
      Installed.refresh()
      Grammars.forget("json")
      System.delete_env("GEEX_CATALOG_URL")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # The bundled JSON grammar's files, as a package: `overrides` replace or add files.
  defp json_files(overrides \\ %{}) do
    base =
      for n <- ["parser.wasm", "highlights.scm", "manifest.json"],
          into: %{},
          do: {n, File.read!(Path.join(@json_dir, n))}

    base |> Map.put("LICENSE", "MIT\n") |> Map.merge(overrides) |> Enum.to_list()
  end

  defp manifest(changes),
    do:
      File.read!(Path.join(@json_dir, "manifest.json"))
      |> JSON.decode!()
      |> Map.merge(changes)
      |> JSON.encode!()

  defp write_zip(ctx, name, files) do
    path = Path.join(ctx.dir, name)
    File.write!(path, Package.zip(files))
    path
  end

  describe "a local package" do
    test "a grammar directory installs, is used, and is recorded as local", ctx do
      pkg = Path.join(ctx.dir, "pkg")
      File.mkdir_p!(pkg)
      for {n, b} <- json_files(), do: File.write!(Path.join(pkg, n), b)

      assert {:ok, %{kind: :grammar, name: "json", sha256: sha}} = Install.install_path(pkg)

      assert %{"installed" => %{"source" => "local", "sha256" => ^sha}} =
               Installed.grammar("json")

      assert Installed.grammar("json")["dir"] == Installed.dir(:grammar, "json")
      assert {:ok, [_ | _]} = Highlight.spans(~s({"a": 1}), "json")
      refute Installed.update?(Installed.grammar("json"))

      # Again, as a zip: replaced in place, nothing left beside it.
      zip = write_zip(ctx, "json.zip", json_files(%{"LICENSE" => "MIT, again\n"}))
      assert {:ok, _} = Install.install_path(zip)
      assert File.read!(Path.join(Installed.dir(:grammar, "json"), "LICENSE")) == "MIT, again\n"
      assert File.ls!(Path.dirname(Installed.dir(:grammar, "json"))) == ["json"]
    end

    test "a theme zip installs and `theme` can use it", ctx do
      json = File.read!(Application.app_dir(:geex, "priv/themes/birds-of-paradise.json"))
      theme = JSON.decode!(json) |> Map.put("name", "Mine") |> JSON.encode!()

      man =
        JSON.encode!(%{
          "kind" => "theme",
          "name" => "mine",
          "display" => "Mine",
          "license" => "MIT"
        })

      zip =
        write_zip(ctx, "mine.zip", [
          {"mine.json", theme},
          {"manifest.json", man},
          {"LICENSE", "x"}
        ])

      assert {:ok, %{kind: :theme, name: "mine"}} = Install.install_path(zip)
      assert "mine" in Theme.names()
      assert {:ok, %Theme{name: "Mine"}} = Theme.named("mine")
    end

    test "a package with a file it shouldn't hold is refused, and nothing is written", ctx do
      for {bad, why} <- [
            {"../evil", "a path up"},
            {"sub/parser.wasm", "a directory"},
            {"run.sh", "an unexpected name"},
            {"/abs", "an absolute path"}
          ] do
        zip = write_zip(ctx, "bad.zip", json_files(%{bad => "x"}))
        assert {:error, {:bad_entry, _}} = Install.install_path(zip), why
      end

      refute File.exists?(Installed.dir(:grammar, "json"))
    end

    test "a symlink entry lands as a plain file holding its target's name, never a link", ctx do
      # A zip entry whose unix mode says symlink (0o120777), pointing anywhere.
      info =
        File.Stat.to_record(%File.Stat{
          size: 4,
          type: :regular,
          access: :read_write,
          mtime: {{2026, 1, 1}, {0, 0, 0}},
          atime: {{2026, 1, 1}, {0, 0, 0}},
          ctime: {{2026, 1, 1}, {0, 0, 0}},
          mode: 0o120777,
          links: 1,
          major_device: 0,
          minor_device: 0,
          inode: 0,
          uid: 0,
          gid: 0
        })

      entries =
        for({n, b} <- json_files(), do: {String.to_charlist(n), b}) ++
          [{~c"LICENSE-link", "/etc", info}]

      {:ok, {_, zip}} = :zip.create(~c"x.zip", entries, [:memory])
      path = Path.join(ctx.dir, "link.zip")
      File.write!(path, zip)
      assert {:ok, _} = Install.install_path(path)
      link = Path.join(Installed.dir(:grammar, "json"), "LICENSE-link")
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(link)
      assert File.read!(link) == "/etc"
    end

    test "too large unpacked is refused before unpacking", ctx do
      big = :binary.copy(<<0>>, 65 * 1024 * 1024)
      zip = write_zip(ctx, "big.zip", json_files(%{"LICENSE" => big}))
      assert {:error, :too_large} = Install.install_path(zip)
    end

    test "a manifest naming another package, or a bad name, is refused", ctx do
      zip =
        write_zip(ctx, "a.zip", json_files(%{"manifest.json" => manifest(%{"kind" => "theme"})}))

      assert {:error, _} = Install.install_path(zip)

      zip =
        write_zip(ctx, "b.zip", json_files(%{"manifest.json" => manifest(%{"name" => "../x"})}))

      assert {:error, {:bad_name, "../x"}} = Install.install_path(zip)
    end

    test "a grammar for another tree-sitter ABI is refused", ctx do
      zip = write_zip(ctx, "abi.zip", json_files(%{"manifest.json" => manifest(%{"abi" => 16})}))
      assert {:error, {:abi, 16}} = Install.install_path(zip)
      assert Install.describe({:abi, 16}) =~ "ABI 16"
    end
  end

  test "one already installed for another ABI is plain text with a hint, never a crash" do
    # As a stale install would be: written straight to its place.
    dir = Installed.dir(:grammar, "json")
    File.mkdir_p!(dir)

    for {n, b} <- json_files(%{"manifest.json" => manifest(%{"abi" => 16})}),
        do: File.write!(Path.join(dir, n), b)

    File.write!(Path.join(dir, "installed.json"), ~s({"source":"catalog","sha256":"x"}))
    Installed.refresh()
    Grammars.forget("json")

    assert Highlight.grammar_status("a.json") == {:needs_update, "JSON"}
    assert Highlight.language_for_path("a.json") == :error
    assert Grammars.handle("json") == {:error, {:abi, 16}}
  end

  test "opening such a file says so; an install says what it made available", ctx do
    dir = Installed.dir(:grammar, "json")
    File.mkdir_p!(dir)

    for {n, b} <- json_files(%{"manifest.json" => manifest(%{"abi" => 12})}),
        do: File.write!(Path.join(dir, n), b)

    File.write!(Path.join(dir, "installed.json"), ~s({"source":"catalog","sha256":"x"}))
    Installed.refresh()

    file = Path.join(ctx.dir, "a.json")
    File.write!(file, "{}\n")
    Geex.Session.set_start(ctx.dir)
    {:ok, pid} = Geex.Session.open_file(file)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Geex.BufferSupervisor, pid)
      Geex.Session.set_active_buffer(nil)
    end)

    {:noreply, state} =
      Geex.Loop.handle_info({:geex_active_buffer, pid}, Geex.Loop.new_state(120, 30))

    assert state.notice == "JSON highlighting needs an update: geex install json"
    assert state.watched[pid].reactor == nil

    # A build it can load arrives: the open file gets a reactor, and the loop follows it.
    {:ok, _} = Install.install_path(write_zip(ctx, "json.zip", json_files()))
    Application.put_env(:geex, :start_highlight, true)
    on_exit(fn -> Application.put_env(:geex, :start_highlight, false) end)

    {:noreply, state} = Geex.Loop.handle_info({:geex_installed, :grammar, "json"}, state)
    assert state.notice == "JSON highlighting installed"
    assert {:ok, reactor} = Geex.Highlight.Reactor.for_buffer(pid)
    assert state.watched[pid].reactor == reactor
    {:noreply, state} = Geex.Loop.handle_info({:geex_installed, :theme, "mine"}, state)
    assert state.notice =~ "theme mine installed"
  end

  describe "an install by another geex" do
    test "is noticed: the editor is told what's new or changed, once per burst", ctx do
      w =
        start_supervised!(
          {Geex.Installed.Watcher,
           name: :installed_watcher_test, notify: self(), delay_ms: 20, start_worker: stub(self())}
        )

      assert_receive {:started, worker}
      zip = write_zip(ctx, "json.zip", json_files())
      # The install's own message goes to Geex.Loop (not running here); the watcher sees disk.
      {:ok, _} = Install.install_path(zip)
      for _ <- 1..3, do: send(w, {:file_event, worker, {"x", [:moved_to, :isdir]}})
      assert_receive {:geex_installed, :grammar, "json"}
      refute_receive {:geex_installed, _, _}, 100

      # The same files again: same sha256, nothing new to say.
      {:ok, _} = Install.install_path(zip)
      send(w, {:file_event, worker, {"x", [:moved_to]}})
      refute_receive {:geex_installed, _, _}, 100
    end

    @tag :inotify
    test "with inotify, for real", ctx do
      if System.find_executable("inotifywait") do
        start_supervised!(
          {Geex.Installed.Watcher, name: :installed_watcher_real, notify: self(), delay_ms: 20}
        )

        Process.sleep(300)
        {:ok, _} = Install.install_path(write_zip(ctx, "json.zip", json_files()))
        assert_receive {:geex_installed, :grammar, "json"}, 2_000
      end
    end

    # A stand-in worker that answers FileSystem.subscribe/1, and tells `test` it started.
    defp stub(test), do: fn _dirs -> stub_worker(test) end

    defp stub_worker(test) do
      worker =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, :subscribe} -> GenServer.reply(from, :ok)
          end

          Process.sleep(:infinity)
        end)

      send(test, {:started, worker})
      {:ok, worker}
    end
  end

  # The step 5 review's findings.
  describe "review fixes" do
    test "another geex installing the same name: busy; a lock left by a dead process is taken",
         ctx do
      parent = Path.dirname(Installed.dir(:grammar, "json"))
      File.mkdir_p!(parent)
      lock = Path.join(parent, ".json.lock")
      zip = write_zip(ctx, "json.zip", json_files())

      File.write!(lock, System.pid())
      assert Install.install_path(zip) == {:error, :busy}
      refute File.exists?(Installed.dir(:grammar, "json"))

      # No such process: the lock is stale.
      File.write!(lock, "999999999")
      assert {:ok, _} = Install.install_path(zip)
      refute File.exists?(lock)
      assert Enum.sort(File.ls!(parent)) == ["json"]
    end

    test "a manifest listed over 64 KB is refused before anything is unpacked", ctx do
      man = manifest(%{"pad" => String.duplicate(" ", 70_000)})
      zip = write_zip(ctx, "m.zip", json_files(%{"manifest.json" => man}))
      assert {:error, {:bad_manifest, :too_large}} = Install.install_path(zip)
    end

    test "file names that are null, not strings, or empty are refused; match ignores them", ctx do
      for bad <- [
            %{"filenames" => nil},
            %{"extensions" => nil},
            %{"extensions" => [""]},
            %{"extensions" => [1]}
          ] do
        zip = write_zip(ctx, "n.zip", json_files(%{"manifest.json" => manifest(bad)}))
        assert {:error, {:bad_manifest, :file_names}} = Install.install_path(zip), inspect(bad)
      end

      entries = [%{"name" => "x", "filenames" => nil, "extensions" => ["", nil, ".x"]}]
      assert Geex.Catalog.match(entries, "a.txt") == nil
      assert Geex.Catalog.match(entries, "a.x")["name"] == "x"
    end

    test "a package directory: other files are left alone, a link is refused, modes are 0644",
         ctx do
      pkg = Path.join(ctx.dir, "checkout")
      File.mkdir_p!(pkg)
      for {n, b} <- json_files(), do: File.write!(Path.join(pkg, n), b)
      File.write!(Path.join(pkg, "README.md"), "a grammar's checkout has other files\n")
      File.chmod!(Path.join(pkg, "LICENSE"), 0o600)

      assert {:ok, _} = Install.install_path(pkg)
      license = Path.join(Installed.dir(:grammar, "json"), "LICENSE")
      assert File.stat!(license).mode |> Bitwise.band(0o777) == 0o644
      refute File.exists?(Path.join(Installed.dir(:grammar, "json"), "README.md"))

      secret = Path.join(ctx.dir, "secret")
      File.write!(secret, "not for a package\n")
      File.rm!(Path.join(pkg, "LICENSE"))
      File.ln_s!(secret, Path.join(pkg, "LICENSE"))
      assert {:error, {:not_a_file, _}} = Install.install_path(pkg)
    end

    test "names a package can't have, and a manifest's wrong types, are refused", ctx do
      theme = File.read!(Application.app_dir(:geex, "priv/themes/birds-of-paradise.json"))

      for name <- ["installed", "terminal"] do
        man = JSON.encode!(%{"kind" => "theme", "name" => name, "license" => "MIT"})
        zip = write_zip(ctx, "t.zip", [{name <> ".json", theme}, {"manifest.json", man}])
        assert {:error, {:bad_name, ^name}} = Install.install_path(zip)
      end

      # A theme named `manifest`: its file would be a second manifest.json.
      man = JSON.encode!(%{"kind" => "theme", "name" => "manifest", "license" => "MIT"})
      zip = write_zip(ctx, "m.zip", [{"manifest.json", theme}, {"manifest.json", man}])
      assert {:error, _} = Install.install_path(zip)
      refute File.exists?(Installed.dir(:theme, "manifest"))

      zip = write_zip(ctx, "n.zip", json_files(%{"manifest.json" => manifest(%{"name" => 5})}))
      assert {:error, {:bad_name, 5}} = Install.install_path(zip)

      zip =
        write_zip(ctx, "d.zip", json_files(%{"manifest.json" => manifest(%{"display" => %{}})}))

      assert {:error, {:bad_manifest, :display}} = Install.install_path(zip)
    end

    test "a cached grammar from a build since replaced is compiled again" do
      :persistent_term.put({Grammars, "json"}, {"a build since replaced", :not_a_grammar})
      assert {:ok, grammar} = Grammars.handle("json")
      assert grammar != :not_a_grammar
      assert {:ok, ^grammar} = Grammars.handle("json")
    end
  end

  test "a catalog download that doesn't match its sha256 is refused", ctx do
    entry = Geex.Catalog.grammar("rust")
    File.write!(Path.join(ctx.dir, entry["asset"]), "not the package")
    System.put_env("GEEX_CATALOG_URL", "file://" <> ctx.dir)

    assert Install.url(entry) == "file://#{ctx.dir}/#{entry["asset"]}"
    assert {:error, {:sha256_mismatch, _}} = Install.install("rust")
    assert Installed.grammar("rust") == nil
    assert {:error, {:not_in_catalog, "cobol"}} = Install.install("cobol")
  end

  test "update?: a catalog install whose sha256 differs from this geex's catalog" do
    entry = Geex.Catalog.grammar("rust")
    pkg = %{"name" => "rust", "kind" => "grammar"}

    refute Installed.update?(
             Map.put(pkg, "installed", %{"source" => "catalog", "sha256" => entry["sha256"]})
           )

    assert Installed.update?(
             Map.put(pkg, "installed", %{"source" => "catalog", "sha256" => "older"})
           )

    refute Installed.update?(
             Map.put(pkg, "installed", %{"source" => "local", "sha256" => "older"})
           )
  end

  describe "over HTTP" do
    defmodule Server do
      @behaviour Plug
      import Plug.Conn

      def init(opts), do: opts

      def call(%{request_path: "/pkg"} = conn, _), do: send_resp(conn, 200, "package bytes")
      def call(%{request_path: "/hop"} = conn, _), do: redirect(conn, "/pkg")
      def call(%{request_path: "/loop"} = conn, _), do: redirect(conn, "/loop")

      def call(%{request_path: "/big"} = conn, _) do
        conn = send_chunked(conn, 200)
        chunk = :binary.copy("x", 1024 * 1024)

        Enum.reduce_while(1..40, conn, fn _, conn ->
          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)
      end

      def call(conn, _), do: send_resp(conn, 404, "")

      defp redirect(conn, to), do: conn |> put_resp_header("location", to) |> send_resp(302, "")
    end

    setup do
      bandit =
        start_supervised!(
          {Bandit, plug: Server, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      %{base: "http://127.0.0.1:#{port}"}
    end

    test "a redirect is followed; a loop, a 404 and an endless body stop", %{base: base} do
      assert Install.fetch(base <> "/hop") == {:ok, "package bytes"}
      assert Install.fetch(base <> "/loop") == {:error, :too_many_redirects}
      assert Install.fetch(base <> "/nope") == {:error, {:http_status, 404}}
      assert Install.fetch(base <> "/big") == {:error, :too_large}
      assert Install.fetch("ftp://x") == {:error, {:bad_url, "ftp://x"}}
    end
  end

  # ADR-0040 §3: geex never makes a network request the user didn't start. Only `Geex.Install`
  # calls an HTTP client or opens a connection, and only `geex install` and the settings view
  # call it.
  test "only Geex.Install can make a request" do
    # Every remote function a module calls is in its import table: read each of geex's.
    beams = :code.lib_dir(:geex) |> Path.join("ebin/*.beam") |> Path.wildcard()
    assert length(beams) > 50

    callers =
      for beam <- beams,
          {:ok, {mod, [imports: imports]}} =
            :beam_lib.chunks(String.to_charlist(beam), [:imports]),
          Enum.any?(imports, &outbound?/1),
          do: mod

    # Bandit and ThousandIsland serve the loopback listeners; they're deps, not geex's modules.
    # (Geex.MCP.Port listens on loopback to find a free port: not outbound.)
    assert callers == [Geex.Install]
  end

  # A call that reaches out: any HTTP client call, or opening a TCP or TLS connection.
  defp outbound?({:httpc, _f, _a}), do: true
  defp outbound?({:inets, _f, _a}), do: true
  defp outbound?({m, :connect, _a}) when m in [:gen_tcp, :ssl, :gen_udp], do: true
  defp outbound?(_mfa), do: false
end
