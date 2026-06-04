defmodule Geex.MixProject do
  use Mix.Project

  def project do
    [
      app: :geex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Cassette fixtures are data loaded via Code.eval_file/1, not test modules.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Geex.Application, []}
    ]
  end

  defp deps do
    [
      # The HTTP MCP transport (ADR-0018) — geex's first dependency: own the
      # dispatcher/provenance, rent the HTTP framing. Bandit + Plug are the
      # BEAM-native stack; JSON stays the built-in module.
      {:bandit, "~> 1.11"},
      {:plug, "~> 1.16"}
    ]
  end
end
