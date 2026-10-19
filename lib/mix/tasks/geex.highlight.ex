defmodule Mix.Tasks.Geex.Highlight do
  @shortdoc "Preview a file syntax-highlighted with a geex theme (truecolor ANSI)"
  @moduledoc """
  Render a source file to stdout as ANSI with the theme the settings view keeps (else the
  built-in terminal theme) — a preview of the highlight pipeline (ADR-0021/0023):

      tree-sitter (wasm) → capture spans → theme → ANSI

      mix geex.highlight lib/geex/ansi.ex      # highlight a file
      mix geex.highlight                        # built-in elixir sample

  The language comes from the installed grammars' file names (ADR-0040: geex ships none;
  `geex install elixir`). Loads the app without starting the TUI. The installed program's
  `geex highlight FILE` is the same (`Geex.CLI.highlight/1`).
  """
  use Mix.Task

  @sample """
  defmodule Demo do
    @moduledoc "A highlight preview."

    def greet(name) when is_binary(name) do
      # a friendly hello
      IO.puts("hello, " <> name <> "!\\n")
      {:ok, 42}
    end
  end
  """

  @impl true
  def run(args) do
    # Load + configure the app (the NIF) WITHOUT starting the supervision tree — no terminal
    # grab.
    Mix.Task.run("app.config")

    case args do
      [] ->
        case Geex.CLI.ansi(@sample, "demo.ex") do
          {:ok, ansi} -> IO.write(ansi)
          {:error, message} -> Mix.raise("highlight failed: #{message}")
        end

      [path | _] ->
        if Geex.CLI.highlight([path]) != 0, do: exit({:shutdown, 1})
    end
  end
end
