defmodule Geex.Highlight.Grammars do
  @moduledoc """
  Resolves a language name to a **compiled, cached** tree-sitter grammar handle.

  [ADR-0023](../../../doc/adr/0023-theming-and-extension-loading.md): geex ships
  **a few default grammars** as portable `.wasm` under `priv/grammars/<lang>/`
  (`parser.wasm` + `highlights.scm`). Compiling a grammar (wasm + query) is the
  expensive step, so the resulting `TreeSitterWasm` handle is compiled **once
  per language** and memoized in `:persistent_term` — a process-independent,
  read-many cache for an immutable handle. User grammars (config-declared paths,
  ADR-0023) land with the user-config layer; geex fetches nothing.

  Each grammar dir's name doubles as the language name passed to the engine,
  which resolves the `tree_sitter_<name>` export inside `parser.wasm`.
  """

  @bundled ~w(json elixir)

  @doc "Languages geex bundles a grammar for."
  @spec bundled() :: [String.t()]
  def bundled, do: @bundled

  @doc """
  A cached, compiled grammar handle for `language`. Compiles + memoizes on first
  use; later calls return the same handle.

  Returns `{:ok, TreeSitterWasm.grammar()}` or `{:error, reason}`:

    * `{:unknown_language, name}` — no bundled grammar
    * `{:grammar_read, posix}` — grammar files unreadable
    * `{:engine, message}` — the engine rejected the grammar/query
  """
  @spec handle(String.t()) :: {:ok, TreeSitterWasm.grammar()} | {:error, term()}
  def handle(language) when is_binary(language) do
    case :persistent_term.get({__MODULE__, language}, :miss) do
      :miss ->
        with {:ok, grammar} <- compile(language) do
          # Idempotent: a concurrent first-call may compile twice; last write
          # wins and the extra handle is GC'd. Errors are never cached.
          :persistent_term.put({__MODULE__, language}, grammar)
          {:ok, grammar}
        end

      grammar ->
        {:ok, grammar}
    end
  end

  defp compile(language) when language in @bundled do
    with {:ok, dir} <- grammar_dir(language),
         {:ok, wasm} <- File.read(Path.join(dir, "parser.wasm")),
         {:ok, scm} <- File.read(Path.join(dir, "highlights.scm")),
         {:ok, grammar} <- load_grammar(wasm, language, scm) do
      {:ok, grammar}
    else
      {:error, posix} when is_atom(posix) -> {:error, {:grammar_read, posix}}
      {:error, _} = tagged -> tagged
    end
  end

  defp compile(language), do: {:error, {:unknown_language, language}}

  # Application.app_dir/2 raises if :geex isn't loaded; keep the contract's
  # tagged-error shape rather than leaking an ArgumentError to the caller.
  defp grammar_dir(language) do
    {:ok, Application.app_dir(:geex, Path.join(["priv", "grammars", language]))}
  rescue
    ArgumentError -> {:error, {:app_not_loaded, :geex}}
  end

  defp load_grammar(wasm, name, scm) do
    case TreeSitterWasm.load_grammar(wasm, name, scm) do
      {:ok, grammar} -> {:ok, grammar}
      {:error, message} -> {:error, {:engine, message}}
    end
  end
end
