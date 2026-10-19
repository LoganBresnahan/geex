defmodule Geex.MixProject do
  use Mix.Project

  @version "0.3.3"
  # The GitHub release the embedded catalog's packages are on (ADR-0040 §2). Bumped only when the
  # catalog changes, not with every version: a catalog release holds the full set of packages, and
  # a geex build names the release of the catalog it embeds.
  @catalog_release "v0.2.0"

  def project do
    [
      app: :geex,
      version: version(),
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Cassette fixtures are data loaded via Code.eval_file/1, not test modules.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      # Keep OTP's applications on the code path under mix: :inets and :ssl aren't dependencies
      # (they're loaded only in the release, ADR-0040 §3), and Mix hides undeclared ones.
      prune_code_paths: false,
      # Test fixtures as packages (geex ships none, ADR-0040): test/support, under test only.
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      releases: releases(),
      catalog_release: @catalog_release
    ]
  end

  # The tree_sitter_wasm commit geex is built against: CI and release builds check it out beside
  # this checkout (`../tree_sitter_wasm`, the path dep), and a release build stops when the one
  # there is another (ADR-0041 §5). A local build uses whatever is there, and names it.
  @tree_sitter_wasm_ref "89a872365aa02b7c5e1b29327c799cac26bde5c8"

  # A local prod build carries its commits in its version: geex's and the tree_sitter_wasm NIF's
  # (`0.3.0+1a2b3c4d.5e6f7a8b`), plus `.dirty` when either tree is uncommitted. Each version
  # installs into a directory of its own (ADR-0041 §4), so two builds sharing a version would
  # be one install. The NIF changes without geex changing, so its commit is part of the name.
  # A release build (`GEEX_RELEASE=1`, CI on a `v*` tag) is the plain version, built from clean
  # trees at the pinned NIF. Dev and test keep the plain version.
  defp version do
    cond do
      Mix.env() != :prod -> @version
      System.get_env("GEEX_RELEASE") == "1" -> release_version()
      true -> "#{@version}+#{build_id()}"
    end
  end

  defp release_version do
    nif = Path.expand("../tree_sitter_wasm", __DIR__)

    case {commit(__DIR__), commit(nif), full_sha(nif)} do
      {{_, false}, {_, false}, @tree_sitter_wasm_ref} ->
        @version

      other ->
        Mix.raise(
          "a release build needs clean trees and tree_sitter_wasm at #{@tree_sitter_wasm_ref}; " <>
            "got #{inspect(other)}"
        )
    end
  end

  defp full_sha(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  # A tree that isn't a git checkout names no code, so it reads `nogit` and the build is dirty:
  # a deploy then installs it again (`--force`), as it would any dirty build.
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

  # The installed program (ADR-0041): `MIX_ENV=prod mix release` assembles the release with the
  # VM that runs Mix, trims and checks it, puts geex's launcher in `bin/geex`, and packs it as
  # `_build/package/geex-<version>-<os>-<arch>.tar.gz`. `mix geex.deploy` installs that with
  # install.sh, as a release install does. CI builds one per target, each on its own runner.
  defp releases do
    [
      geex: [
        # After assembling: the VM programs geex never runs go, the rest lose their debug
        # information, and the release is checked (ADR-0036's 2026-10-18 amendment, ADR-0041 §1);
        # then the launcher and the tarball (ADR-0041 §2).
        steps: [
          :assemble,
          &Mix.Tasks.Geex.Deploy.trim_release/1,
          &Mix.Tasks.Geex.Deploy.package/1
        ],
        # Mix's default, stated: no debug information or docs in the .beam files.
        strip_beams: true,
        # :inets (`:httpc`) downloads a grammar or theme the user asked for (ADR-0040 §3).
        # Carried and loaded, not started at boot, and not a dependency of :geex (Mix won't let
        # a permanent app depend on a loaded one): `Geex.Install` starts it when a download
        # begins, so a geex that installs nothing never starts an HTTP client. (:ssl is already
        # started at boot, for Bandit's ThousandIsland.)
        applications: [inets: :load]
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
      {:tree_sitter_wasm, path: "../tree_sitter_wasm"}
    ]
  end
end
