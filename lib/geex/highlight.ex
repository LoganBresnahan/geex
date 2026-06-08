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

  The compiled grammar is cached per language (`Geex.Highlight.Grammars`); the
  parse is bounded by a deadline so a pathological buffer can't pin a scheduler.
  *When* highlighting fires — debounced, async, viewport-first off the command
  stream — is the reactor's job
  ([ADR-0022](../../doc/adr/0022-capability-reactor.md)), built as its own slice;
  this is the function the reactor will call.
  """

  alias Geex.Highlight.{Grammars, Span}

  # Generous default parse deadline; only guards against pathological input.
  @default_timeout_ms 5_000

  @doc """
  Capture spans for `text` in `language` (a bundled grammar name, e.g. `"elixir"`),
  bounding the parse to `timeout_ms` (default #{@default_timeout_ms} ms).

  Returns `{:ok, [Span.t()]}` or `{:error, reason}`:

    * `{:unknown_language, name}` — no bundled grammar
    * `{:grammar_read, posix}` — grammar files unreadable
    * `:timeout` — the parse exceeded the deadline
    * `{:engine, message}` — the engine rejected the grammar/query (never a crash)
  """
  @spec spans(String.t(), String.t(), non_neg_integer()) ::
          {:ok, [Span.t()]} | {:error, term()}
  def spans(text, language, timeout_ms \\ @default_timeout_ms)
      when is_binary(text) and is_binary(language) and is_integer(timeout_ms) and timeout_ms >= 0 do
    with {:ok, grammar} <- Grammars.handle(language),
         {:ok, raw} <- engine_highlight(grammar, text, timeout_ms) do
      {:ok, Enum.map(raw, fn {s, e, capture} -> %Span{start_byte: s, end_byte: e, capture: capture} end)}
    end
  end

  defp engine_highlight(grammar, text, timeout_ms) do
    case TreeSitterWasm.highlight(grammar, text, timeout_ms) do
      {:ok, raw} -> {:ok, raw}
      {:error, :timeout} -> {:error, :timeout}
      # Normalize the engine's human-readable string into a tagged reason.
      {:error, message} when is_binary(message) -> {:error, {:engine, message}}
    end
  end
end
