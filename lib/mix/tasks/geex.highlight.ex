defmodule Mix.Tasks.Geex.Highlight do
  @shortdoc "Preview a file syntax-highlighted with a geex theme (truecolor ANSI)"
  @moduledoc """
  Render a source file with the Birds of Paradise theme to stdout as 24-bit
  truecolor ANSI — a preview of the highlight pipeline (ADR-0021/0023):

      tree-sitter (wasm) → capture spans → theme → ANSI

      mix geex.highlight lib/geex/ansi.ex      # highlight a file
      mix geex.highlight                        # built-in elixir sample

  Language comes from the extension (`.ex`/`.exs` → elixir, `.json` → json);
  geex's bundled grammars only. Loads the app without starting the TUI.
  """
  use Mix.Task

  @sample """
  defmodule Demo do
    @moduledoc "Birds of Paradise preview."

    def greet(name) when is_binary(name) do
      # a friendly hello
      IO.puts("hello, " <> name <> "!\\n")
      {:ok, 42}
    end
  end
  """

  @impl true
  def run(args) do
    # Load + configure the app (priv grammars, the NIF) WITHOUT starting the
    # supervision tree — no terminal grab.
    Mix.Task.run("app.config")

    {text, lang} =
      case args do
        [] ->
          {@sample, "elixir"}

        [path | _] ->
          case File.read(path) do
            {:ok, text} -> {text, lang_for(path)}
            {:error, posix} -> Mix.raise("could not read #{path}: #{:file.format_error(posix)}")
          end
      end

    case Geex.Highlight.spans(text, lang) do
      {:ok, spans} ->
        IO.write(Geex.Ansi.highlight(Geex.Theme.default(), text, spans))

      {:error, reason} ->
        Mix.raise("highlight failed: #{inspect(reason)}")
    end
  end

  defp lang_for(path) do
    case Geex.Highlight.language_for_path(path) do
      {:ok, lang} ->
        lang

      :error ->
        Mix.raise(
          "no grammar for #{inspect(Path.basename(path))} " <>
            "(have: #{Enum.join(Geex.Highlight.Grammars.available(), ", ")})"
        )
    end
  end
end
