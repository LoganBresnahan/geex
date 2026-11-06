defmodule Geex.Markdown do
  @moduledoc """
  The markdown preview's entry points ([ADR-0043](../../doc/adr/0043-markdown-preview.md)): which
  files it is offered for, and the two grammars it renders with.

  The preview reads a document with the installed Markdown grammar (the blocks) and its
  companion `markdown_inline` (the markup inside them, ADR-0043 §7), each loaded with geex's own
  render query (`Geex.Markdown.Parse.query/1`) instead of the package's highlights. The handles
  are `Geex.Highlight.Grammars.render_handle/2`'s, so they are cached by each install's sha256,
  never loaded for an ABI this geex doesn't take, and dropped when either package is replaced.
  """

  alias Geex.Highlight.Grammars
  alias Geex.Markdown.Parse

  @block "markdown"
  @inline "markdown_inline"

  @typedoc """
  Why the preview isn't offered: `{:missing, names}` (packages to install, in order), or
  `:update` (a package of an ABI this geex doesn't load, or one geex's render query doesn't
  compile against: the engine's own message is never shown).
  """
  @type unavailable :: {:missing, [String.t()]} | :update

  @doc "The two grammars the preview needs: Markdown, then its companion."
  @spec grammars() :: [String.t()]
  def grammars, do: [@block, @inline]

  @doc """
  The two render handles, `%{block: grammar, inline: grammar}`, or why there are none.
  `:query` (a test's) replaces `Geex.Markdown.Parse.query/1`.
  """
  @spec handles(keyword()) :: {:ok, Parse.grammars()} | {:error, unavailable()}
  def handles(opts \\ []) do
    query = Keyword.get(opts, :query, &Parse.query/1)
    handle = &Grammars.render_handle(&1, query.(&1))

    case {handle.(@block), handle.(@inline)} do
      {{:ok, block}, {:ok, inline}} ->
        {:ok, %{block: block, inline: inline}}

      results ->
        missing =
          for {name, {:error, {:unknown_language, _}}} <-
                Enum.zip(grammars(), Tuple.to_list(results)),
              do: name

        if missing == [], do: {:error, :update}, else: {:error, {:missing, missing}}
    end
  end

  @doc """
  Whether `path` is a markdown file: its installed grammar is Markdown. Says nothing about the
  companion; `handles/0` does.
  """
  @spec file?(String.t() | nil) :: boolean()
  def file?(path) when is_binary(path),
    do: Geex.Highlight.language_for_path(path) == {:ok, @block}

  def file?(_path), do: false

  @doc """
  What to tell the user when the preview isn't available, as ADR-0040's hint and §5's update
  notice say it for highlighting.

      iex> Geex.Markdown.describe({:missing, ["markdown_inline"]})
      "Markdown preview needs Markdown inline installed (Alt+Y)"
      iex> Geex.Markdown.describe({:missing, ["markdown", "markdown_inline"]})
      "Markdown preview needs Markdown and Markdown inline installed (Alt+Y)"
      iex> Geex.Markdown.describe(:update)
      "Markdown preview needs an update (Alt+Y)"
  """
  @spec describe(unavailable()) :: String.t()
  def describe(:update), do: "Markdown preview needs an update (Alt+Y)"

  def describe({:missing, names}) do
    "Markdown preview needs #{Enum.map_join(names, " and ", &display/1)} installed (Alt+Y)"
  end

  defp display(name) do
    case Geex.Catalog.grammar(name) do
      %{"display" => display} -> display
      nil -> name
    end
  end

  @doc """
  The label a companion grammar is listed under where grammars are listed as languages (Alt+Y's
  Languages tab, `geex install --list`): `"<display> (preview)"`. Any other grammar keeps its
  display name.

      iex> Geex.Markdown.label(%{"display" => "Markdown inline", "for" => "markdown"})
      "Markdown inline (preview)"
      iex> Geex.Markdown.label(%{"display" => "Markdown"})
      "Markdown"
  """
  @spec label(map()) :: String.t()
  def label(%{"display" => display, "for" => for}) when is_binary(for),
    do: display <> " (preview)"

  def label(%{"display" => display}), do: display
end
