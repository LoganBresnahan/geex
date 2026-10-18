defmodule Geex.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :geex,
      version: version(),
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Cassette fixtures are data loaded via Code.eval_file/1, not test modules.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps(),
      releases: releases()
    ]
  end

  # A prod build carries its commits in its version: geex's and the tree_sitter_wasm NIF's
  # (`0.1.0+1a2b3c4d.5e6f7a8b`), plus `.dirty` when either tree is uncommitted. Burrito unpacks
  # the binary into a directory named after the version and skips unpacking when that directory
  # exists, and a deploy keeps an unpack a running geex uses, so two builds sharing a version
  # would run the first one's code (ADR-0036). The NIF changes without geex changing, so its
  # commit is part of the name. Dev and test keep the plain version.
  defp version do
    if Mix.env() == :prod, do: "#{@version}+#{build_id()}", else: @version
  end

  # A tree that isn't a git checkout names no code, so it reads `nogit` and the build is dirty:
  # a deploy then won't keep an in-use unpack of that name, as it would a committed one's.
  defp build_id do
    commits = Enum.map([__DIR__, Path.expand("../tree_sitter_wasm", __DIR__)], &commit/1)
    shas = Enum.map_join(commits, ".", fn {sha, _dirty} -> sha end)
    shas <> if(Enum.any?(commits, &elem(&1, 1)), do: ".dirty", else: "")
  end

  # `{sha8, dirty?}` for the checkout at `dir`; a directory that isn't the top of one (a copied
  # tree, or one inside another repository) is `{"nogit", true}`.
  defp commit(dir) do
    git = fn args -> System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) end

    with {top, 0} <- git.(["rev-parse", "--show-toplevel"]),
         true <- Path.expand(String.trim(top)) == Path.expand(dir),
         {sha, 0} <- git.(["rev-parse", "--short=8", "HEAD"]) do
      {status, _} = git.(["status", "--porcelain"])
      {String.trim(sha), String.trim(status) != ""}
    else
      _ -> {"nogit", true}
    end
  end

  # The installed binary (ADR-0036): `MIX_ENV=prod mix release` assembles the release, then
  # Burrito wraps it into one file, `burrito_out/geex_linux`. `mix geex.deploy` does both and
  # installs it.
  #
  # Burrito's own phases are cut down to "copy the release, build the wrapper". Its default
  # Linux flow swaps in a precompiled musl ERTS, and the tree_sitter_wasm NIF (Rust, built
  # against this machine's glibc) can't load into that. The release already carries this
  # machine's ERTS, so it is wrapped as built: the binary runs where it was built, which is
  # what a local install needs. A Mac or a portable Linux binary needs the NIF built for
  # that target first.
  defp releases do
    [
      geex: [
        steps: [:assemble, &Burrito.wrap/1],
        # Carried, loaded, not started at boot (ADR-0040 §3).
        applications: [inets: :load, ssl: :load],
        burrito: [
          targets: [linux: [os: :linux, cpu: :x86_64]],
          phases: [
            fetch: [Burrito.Steps.Fetch.Init],
            patch: []
          ]
        ]
      ]
    ]
  end

  def application do
    [
      # :inets (`:httpc`) and :ssl download a grammar or theme the user asked for (ADR-0040 §3).
      # Optional, and loaded but not started in the release: `Geex.Install` starts them when a
      # download begins, so a geex that installs nothing never starts an HTTP client.
      extra_applications: [:logger, :crypto, inets: :optional, ssl: :optional],
      mod: {Geex.Application, []}
    ]
  end

  defp deps do
    [
      # The HTTP MCP transport (ADR-0018) — geex's first dependency: own the
      # dispatcher/provenance, rent the HTTP framing. Bandit + Plug are the
      # BEAM-native stack; JSON stays the built-in module.
      {:bandit, "~> 1.11"},
      {:plug, "~> 1.16"},
      # The reconcile file-watcher (ADR-0017) — push-based inotify/fsevents, the
      # standard BEAM choice (Phoenix live-reload uses it). The Linux backend shells
      # out to `inotifywait` (inotify-tools); without it the watcher degrades to a
      # no-op (logged) and the reconcile core is unaffected.
      {:file_system, "~> 1.0"},
      # The syntax-highlighting engine (ADR-0021 host-in / ADR-0023): the native
      # tree-sitter runtime that loads portable grammar.wasm. Net-new on the BEAM
      # (every other binding static-links grammars). Path dep during the spike;
      # github/hex once its highlight/4 API stabilizes.
      {:tree_sitter_wasm, path: "../tree_sitter_wasm"},
      # Wraps the release into one executable (ADR-0036). Build-time only, and only for prod
      # builds. Pinned to 1.5: 1.6 needs Zig 0.16, and this machine has Zig 0.15.2, the same
      # pin as pharos-mcp.
      {:burrito, "~> 1.5.0", only: :prod, runtime: false}
    ]
  end
end
