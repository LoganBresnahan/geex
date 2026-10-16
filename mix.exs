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

  # A prod build carries the commit in its version (`0.1.0+1a2b3c4d`, plus `.dirty` for an
  # uncommitted tree). Burrito unpacks the binary into a directory named after the version and
  # skips unpacking when that directory exists, so two builds sharing a version would run the
  # first one's code (ADR-0036). Dev and test keep the plain version.
  defp version do
    if Mix.env() == :prod, do: "#{@version}+#{build_id()}", else: @version
  end

  defp build_id do
    case System.cmd("git", ["rev-parse", "--short=8", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        {status, _} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)
        String.trim(sha) <> if(String.trim(status) == "", do: "", else: ".dirty")

      _ ->
        "local"
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
      extra_applications: [:logger, :crypto],
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
