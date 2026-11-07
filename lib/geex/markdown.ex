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

  @aliases %{
    "sh" => "bash",
    "shell" => "bash",
    "console" => "bash",
    "zsh" => "bash",
    "js" => "javascript",
    "ts" => "typescript",
    "py" => "python",
    "ex" => "elixir",
    "exs" => "elixir",
    "iex" => "elixir",
    "md" => "markdown",
    "jsonc" => "json",
    "yml" => "yaml",
    "erl" => "erlang",
    "rs" => "rust"
  }

  @doc """
  The grammar a fenced block's info string names (its first word): the one alias table, shared
  by the preview and `mix geex.render` (ADR-0043 §4).

      iex> Geex.Markdown.language("sh")
      "bash"
      iex> Geex.Markdown.language("Rust")
      "rust"
  """
  @spec language(String.t()) :: String.t()
  def language(info) do
    word = String.downcase(info)
    Map.get(@aliases, word, word)
  end

  @typedoc """
  One read of a document, what the preview keeps between layouts (ADR-0043 §2, §3): the text
  (each `\r\n` turned to `\n`), its tree, each fenced block's highlight spans by `{code, info
  word}` (capture names, not colours, §5) and, built from them once, the captures covering each
  byte (`Geex.Markdown.Layout.captures/1`), the grammars its code blocks name (whether installed
  or not: installing one re-renders), and the parse's stats.
  """
  @type parsed :: %{
          text: String.t(),
          tree: Parse.tree(),
          code: %{{String.t(), String.t()} => [Geex.Highlight.Span.t()]},
          captures: %{{String.t(), String.t()} => map()},
          languages: [String.t()],
          stats: map()
        }

  @doc """
  Parse `text` with the render handles: line endings normalised, the tree built, and each
  fenced block highlighted once by the installed grammar for its language.
  """
  @spec parse(String.t(), Parse.grammars()) :: {:ok, parsed()} | {:error, term()}
  def parse(text, grammars) when is_binary(text) do
    text = String.replace(text, "\r\n", "\n")

    with {:ok, tree, stats} <- Parse.parse(text, grammars) do
      blocks = Geex.Markdown.Layout.code_blocks(tree, text)
      installed = MapSet.new(Grammars.available())
      {us, code} = :timer.tc(fn -> highlight(blocks, installed) end)

      {:ok,
       %{
         text: text,
         tree: tree,
         code: code,
         captures:
           Map.new(code, fn {key, spans} -> {key, Geex.Markdown.Layout.captures(spans)} end),
         languages: blocks |> Enum.map(&language(elem(&1, 1))) |> Enum.uniq(),
         stats: Map.merge(stats, %{code_blocks: length(blocks), code_us: us})
       }}
    end
  end

  defp highlight(blocks, installed) do
    for {code, info} <- Enum.uniq(blocks),
        lang = language(info),
        lang in installed,
        {:ok, spans} <- [Geex.Highlight.spans(code, lang)],
        into: %{},
        do: {{code, info}, spans}
  end

  @doc "The rows of a parsed document at `width` columns (`Geex.Markdown.Layout.rows/4`)."
  @spec rows(parsed(), pos_integer()) :: [Geex.Markdown.Layout.row()]
  def rows(%{tree: tree, text: text, captures: captures}, width) do
    Geex.Markdown.Layout.rows(tree, text, width, captures: &Map.get(captures, {&1, &2}))
  end

  @doc """
  Whether the preview can be offered, from the installed manifests alone: both grammars
  installed, each of an ABI this geex loads. Cheap enough for the key loop (it compiles nothing);
  a render query that doesn't compile shows later, as the preview's status.
  """
  @spec available() :: :ok | {:error, unavailable()}
  def available do
    manifests = Enum.map(grammars(), &{&1, Geex.Installed.grammar(&1)})

    case for({name, nil} <- manifests, do: name) do
      [] ->
        if Enum.all?(manifests, fn {_name, m} -> m["abi"] in Grammars.abi() end),
          do: :ok,
          else: {:error, :update}

      missing ->
        {:error, {:missing, missing}}
    end
  end

  @doc """
  The package to install or update first for `why` (`available/0`'s error): the missing one, or
  the first of an ABI this geex doesn't load. Alt+Y opens on its row.
  """
  @spec to_install(unavailable()) :: String.t()
  def to_install({:missing, [name | _]}), do: name

  def to_install(:update) do
    Enum.find(grammars(), @block, fn name ->
      Geex.Installed.grammar(name)["abi"] not in Grammars.abi()
    end)
  end

  @doc """
  Whether `path` is a markdown file: the grammar for its name, installed or in the catalog, is
  Markdown. Not whether the preview can be offered (`available/0`), so a `.md` file with Markdown
  missing or outdated is told what to install, not that it isn't markdown.
  """
  @spec file?(String.t() | nil) :: boolean()
  def file?(path) when is_binary(path) do
    case Geex.Installed.for_path(path) || Geex.Catalog.for_path(path) do
      %{"name" => @block} -> true
      _ -> false
    end
  end

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
