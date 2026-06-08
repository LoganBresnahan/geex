defmodule Geex.Highlight.Grammars do
  @moduledoc """
  Resolves a language name to its tree-sitter grammar bytes + highlights query.

  [ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md): geex ships
  **a few default grammars** as portable `.wasm` under `priv/grammars/<lang>/`
  (`parser.wasm` + `highlights.scm`). User grammars are loaded by **declaring a
  path in config** — geex fetches nothing; that override lands with the
  user-config layer. For now this resolves only the bundled set.

  Each grammar dir's name doubles as the language name passed to the engine,
  which resolves the `tree_sitter_<name>` export inside `parser.wasm`.
  """

  @bundled ~w(json elixir)

  @doc "Languages geex bundles a grammar for."
  @spec bundled() :: [String.t()]
  def bundled, do: @bundled

  @doc """
  Load a bundled grammar. Returns the language name (the engine export key),
  the portable `parser.wasm` bytes, and the `highlights.scm` query.
  """
  @spec load(String.t()) ::
          {:ok, %{name: String.t(), wasm: binary(), scm: String.t()}}
          | {:error, {:unknown_language, String.t()} | {:grammar_read, File.posix()}}
  def load(language) when is_binary(language) do
    if language in @bundled do
      dir = Application.app_dir(:geex, Path.join(["priv", "grammars", language]))

      with {:ok, wasm} <- File.read(Path.join(dir, "parser.wasm")),
           {:ok, scm} <- File.read(Path.join(dir, "highlights.scm")) do
        {:ok, %{name: language, wasm: wasm, scm: scm}}
      else
        {:error, posix} -> {:error, {:grammar_read, posix}}
      end
    else
      {:error, {:unknown_language, language}}
    end
  end
end
