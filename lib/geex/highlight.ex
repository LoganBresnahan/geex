defmodule Geex.Highlight do
  @moduledoc """
  Syntax highlighting — geex's **host-in capability**
  ([ADR-0021](../../doc/adr/0021-capability-connections.md) /
  [ADR-0023](../../doc/adr/0023-theming-and-extension-loading.md)).

  Unlike LSP (a *connect-out* network capability), highlighting is an **engine
  hosted in geex's VM**: the native tree-sitter runtime that loads portable
  grammar `.wasm` (`TreeSitterWasm`). This module is the single seam where
  geex's world touches that engine; it produces `Geex.Highlight.Span`s — capture
  spans — and knows nothing about colour. Mapping captures → colour is the
  theme's job ([ADR-0023](../../doc/adr/0023-theming-and-extension-loading.md)).

  Synchronous and pure-ish (reads bundled grammar files, calls the NIF). *When*
  highlighting fires — debounced, async, viewport-first off the command stream —
  is the reactor's job ([ADR-0022](../../doc/adr/0022-capability-reactor.md)),
  built as its own slice; this is the function the reactor will call.
  """

  alias Geex.Highlight.{Grammars, Span}

  @doc """
  Capture spans for `text` in `language` (a bundled grammar name, e.g. `"elixir"`).

  Returns `{:ok, [Span.t()]}` or `{:error, reason}`:

    * `{:unknown_language, name}` — no bundled grammar
    * `{:grammar_read, posix}` — grammar files unreadable
    * `{:engine, message}` — the engine rejected the grammar/query (never a crash)
  """
  @spec spans(String.t(), String.t()) :: {:ok, [Span.t()]} | {:error, term()}
  def spans(text, language) when is_binary(text) and is_binary(language) do
    with {:ok, g} <- Grammars.load(language),
         {:ok, raw} <- engine_highlight(g, text) do
      {:ok, Enum.map(raw, fn {s, e, capture} -> %Span{start_byte: s, end_byte: e, capture: capture} end)}
    end
  end

  defp engine_highlight(g, text) do
    case TreeSitterWasm.highlight(g.wasm, g.name, g.scm, text) do
      {:ok, raw} -> {:ok, raw}
      # Normalize the engine's human-readable string into a tagged reason.
      {:error, message} -> {:error, {:engine, message}}
    end
  end
end
