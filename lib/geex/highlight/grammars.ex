defmodule Geex.Highlight.Grammars do
  @moduledoc """
  Resolves a language name to a **compiled, cached** tree-sitter grammar handle.

  The grammars are what `Geex.Installed` lists ([ADR-0040](../../../doc/adr/0040-bare-geex-and-the-catalog.md)
  §4): the ones installed from the catalog or a local package, and, until geex ships bare, the
  ones bundled under `priv/grammars/<lang>/`. Each is a directory with `parser.wasm`,
  `highlights.scm` and `manifest.json`. Compiling a grammar (wasm + query) is the expensive
  step, so the resulting `TreeSitterWasm` handle is compiled **once per language** and memoized
  in `:persistent_term`, a process-independent, read-many cache for an immutable handle;
  `forget/1` drops one when its package is replaced. The compiled wasm is also kept on disk
  across starts (`cache_dir/0`, ADR-0040 §8).

  A grammar built for a tree-sitter language ABI the NIF doesn't load (ADR-0040 §5) is never
  handed to the engine: it is `{:error, {:abi, version}}`, and the file shows as plain text.

  The directory's name is the language name passed to the engine, which resolves the
  `tree_sitter_<name>` export inside `parser.wasm`.
  """

  alias Geex.Installed

  # The language ABIs the NIF's tree-sitter (0.26.9) loads.
  @abi 13..15

  @doc "The tree-sitter language ABIs this geex loads."
  @spec abi() :: Range.t()
  def abi, do: @abi

  @doc "The languages there are grammars for: installed, and bundled until geex ships bare."
  @spec available() :: [String.t()]
  def available, do: Enum.map(Installed.grammars(), & &1["name"])

  @doc """
  A cached, compiled grammar handle for `language`. Compiles + memoizes on first
  use; later calls return the same handle.

  Returns `{:ok, TreeSitterWasm.grammar()}` or `{:error, reason}`:

    * `{:unknown_language, name}` — no grammar for it
    * `{:abi, version}` — built for a language ABI this geex doesn't load
    * `{:grammar_read, posix}` — grammar files unreadable
    * `{:engine, message}` — the engine rejected the grammar/query
  """
  @spec handle(String.t()) :: {:ok, TreeSitterWasm.grammar()} | {:error, term()}
  def handle(language) when is_binary(language) do
    # The handle is cached with the build it came from (an install's sha256), so one compiled
    # from a package since replaced is never used, even if its compile finished after the
    # replacement's `forget/1`.
    build = build(Installed.grammar(language))

    case :persistent_term.get({__MODULE__, language}, :miss) do
      {^build, grammar} ->
        {:ok, grammar}

      _miss_or_stale ->
        with {:ok, grammar} <- compile(language) do
          # Idempotent: a concurrent first-call may compile twice; last write
          # wins and the extra handle is GC'd. Errors are never cached.
          :persistent_term.put({__MODULE__, language}, {build, grammar})
          {:ok, grammar}
        end
    end
  end

  defp build(%{"installed" => %{"sha256" => sha}}), do: sha
  defp build(%{"dir" => dir}), do: dir
  defp build(nil), do: nil

  @doc "Drop `language`'s cached handle, so the next use compiles the package now installed."
  @spec forget(String.t()) :: :ok
  def forget(language) do
    _ = :persistent_term.erase({__MODULE__, language})
    :ok
  end

  defp compile(language) do
    with %{"dir" => dir} = manifest <-
           Installed.grammar(language) || {:error, {:unknown_language, language}},
         :ok <- check_abi(manifest),
         {:ok, wasm} <- File.read(Path.join(dir, "parser.wasm")),
         {:ok, scm} <- File.read(Path.join(dir, "highlights.scm")) do
      load_grammar(wasm, language, scm)
    else
      {:error, posix} when is_atom(posix) -> {:error, {:grammar_read, posix}}
      {:error, _} = tagged -> tagged
    end
  end

  defp check_abi(%{"abi" => abi}) when abi in @abi, do: :ok
  defp check_abi(%{"abi" => abi}), do: {:error, {:abi, abi}}
  defp check_abi(_manifest), do: {:error, {:abi, nil}}

  # Compiled grammars are kept in `$XDG_CACHE_HOME/geex/wasm` (ADR-0040 §8), so a later start
  # loads them in a few ms instead of compiling them again. Off under test (`wasm_cache`).
  defp load_grammar(wasm, name, scm) do
    opts = if cache_dir = cache_dir(), do: [cache_dir: cache_dir], else: []

    case TreeSitterWasm.load_grammar(wasm, name, scm, opts) do
      {:ok, grammar} -> {:ok, grammar}
      {:error, message} -> {:error, {:engine, message}}
    end
  end

  @doc "Where compiled grammars are cached, or `nil` when the cache is off."
  @spec cache_dir() :: Path.t() | nil
  def cache_dir do
    if Application.get_env(:geex, :wasm_cache, true) do
      case System.get_env("XDG_CACHE_HOME") do
        empty when empty in [nil, ""] -> Path.expand("~/.cache/geex/wasm")
        dir -> Path.join([dir, "geex", "wasm"])
      end
    end
  end
end
