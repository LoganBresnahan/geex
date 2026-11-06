defmodule Geex.Markdown.Parse do
  @moduledoc """
  **Spike** for the read-only markdown preview (ADR-0043 to come): a markdown document as a tree
  of byte-ranged nodes, from the installed tree-sitter markdown grammars.

  It adds no NIF surface. `TreeSitterWasm.highlight/3` returns every capture of the query a
  grammar was loaded with, so the block grammar loaded with `@block_query` (structure, not
  highlight scopes) gives the document's outline. The inline grammar, run once over each
  `inline` node and table cell, gives the markup inside them. The grammar's README parses those
  ranges in one pass with `ts_parser_set_included_ranges`; one call per range stands in until
  the NIF can. A container's line prefixes inside an inline range (a quote's `> `, a list's
  indent: `block_continuation` nodes) are blanked to spaces first, so offsets don't move.

  A node is `%{type: atom, s: byte, e: byte, children: [node]}`, `s`/`e` indexing the text.
  """

  @block_query ~S"""
  (atx_heading) @atx_heading
  (atx_h1_marker) @h1
  (atx_h2_marker) @h2
  (atx_h3_marker) @h3
  (atx_h4_marker) @h4
  (atx_h5_marker) @h5
  (atx_h6_marker) @h6
  (setext_heading) @setext_heading
  (setext_h1_underline) @setext_h1
  (setext_h2_underline) @setext_h2
  (paragraph) @paragraph
  (inline) @inline
  (block_continuation) @continuation
  (block_quote) @block_quote
  (list) @list
  (list_item) @list_item
  (list_marker_minus) @bullet
  (list_marker_plus) @bullet
  (list_marker_star) @bullet
  (list_marker_dot) @number
  (list_marker_parenthesis) @number
  (task_list_marker_checked) @task_done
  (task_list_marker_unchecked) @task_open
  (fenced_code_block) @fenced_code
  (info_string) @info
  (language) @language
  (code_fence_content) @code
  (indented_code_block) @indented_code
  (thematic_break) @rule
  (html_block) @html
  (pipe_table) @table
  (pipe_table_header) @table_header
  (pipe_table_delimiter_row) @table_delimiter
  (pipe_table_delimiter_cell) @table_delimiter_cell
  (pipe_table_align_left) @align_left
  (pipe_table_align_right) @align_right
  (pipe_table_row) @table_row
  (pipe_table_cell) @table_cell
  (link_reference_definition) @link_definition
  (link_label) @link_label
  (minus_metadata) @metadata
  (plus_metadata) @metadata
  """

  @inline_query ~S"""
  (emphasis) @emphasis
  (strong_emphasis) @strong
  (strikethrough) @strike
  (emphasis_delimiter) @delimiter
  (code_span) @code_span
  (code_span_delimiter) @delimiter
  (inline_link) @link
  (full_reference_link) @reference_link
  (collapsed_reference_link) @reference_link
  (shortcut_link) @reference_link
  (link_text) @link_text
  (link_destination) @link_destination
  (link_title) @link_title
  (link_label) @link_label
  (image) @image
  (image_description) @image_description
  (uri_autolink) @autolink
  (email_autolink) @autolink
  (backslash_escape) @escape
  (hard_line_break) @hard_break
  (html_tag) @html_tag
  (entity_reference) @entity
  (numeric_character_reference) @entity
  (latex_block) @latex
  """

  @types ~w(atx_heading h1 h2 h3 h4 h5 h6 setext_heading setext_h1 setext_h2 paragraph inline
            continuation block_quote list list_item bullet number task_done task_open fenced_code
            info language code indented_code rule html table table_header table_delimiter
            table_delimiter_cell align_left align_right table_row table_cell link_definition
            link_label metadata emphasis strong strike delimiter code_span link reference_link
            link_text link_destination link_title image image_description autolink escape
            hard_break html_tag entity latex)a
         |> Map.new(&{Atom.to_string(&1), &1})

  @default_inline_wasm "_build/markdown_inline/parser.wasm"

  @type tree :: %{
          type: atom(),
          s: non_neg_integer(),
          e: non_neg_integer(),
          children: [tree()]
        }
  @type grammars :: %{block: TreeSitterWasm.grammar(), inline: TreeSitterWasm.grammar()}

  @doc """
  The two grammars loaded with the render queries: the installed Markdown (block) grammar, and
  the inline grammar from `:inline_wasm` (default `#{@default_inline_wasm}`, not packaged yet).
  """
  @spec load(keyword()) :: {:ok, grammars()} | {:error, String.t()}
  def load(opts \\ []) do
    inline_path = Keyword.get(opts, :inline_wasm) || @default_inline_wasm

    with {:ok, dir} <- markdown_dir(),
         {:ok, block_wasm} <- read(Path.join(dir, "parser.wasm")),
         {:ok, inline_wasm} <- read(inline_path),
         {:ok, block} <- compile(block_wasm, "markdown", @block_query),
         {:ok, inline} <- compile(inline_wasm, "markdown_inline", @inline_query) do
      {:ok, %{block: block, inline: inline}}
    end
  end

  defp markdown_dir do
    case Geex.Installed.grammar("markdown") do
      %{"dir" => dir} -> {:ok, dir}
      _ -> {:error, "the Markdown grammar isn't installed (geex install markdown)"}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, posix} -> {:error, "#{path}: #{:file.format_error(posix)}"}
    end
  end

  defp compile(wasm, name, query) do
    opts =
      case Geex.Highlight.Grammars.cache_dir() do
        nil -> []
        dir -> [cache_dir: dir]
      end

    case TreeSitterWasm.load_grammar(wasm, name, query, opts) do
      {:ok, grammar} -> {:ok, grammar}
      {:error, reason} -> {:error, "#{name}: #{reason}"}
    end
  end

  @doc """
  Parse `text` into a tree. The stats count the block captures and the inline calls, with the
  time the inline calls took (µs).
  """
  @spec parse(String.t(), grammars()) :: {:ok, tree(), map()} | {:error, term()}
  def parse(text, %{block: block, inline: inline}) when is_binary(text) do
    with {:ok, block_caps} <- TreeSitterWasm.highlight(block, text) do
      sorted = Enum.sort_by(block_caps, fn {s, e, _name} -> {s, -e} end)
      targets = for {s, e, name} <- sorted, name in ["inline", "table_cell"], e > s, do: {s, e}
      blanks = for {s, e, "continuation"} <- sorted, e > s, do: {s, e}
      {us, found} = :timer.tc(fn -> inline_captures(targets, blanks, text, inline, []) end)

      with {:ok, inline_caps} <- found do
        stats = %{
          block_captures: length(block_caps),
          inline_calls: length(targets),
          inline_us: us
        }

        {:ok, tree(block_caps ++ inline_caps, byte_size(text)), stats}
      end
    end
  end

  # Ranges never overlap and come in order, so the continuations are walked once.
  defp inline_captures([], _blanks, _text, _grammar, acc), do: {:ok, List.flatten(acc)}

  defp inline_captures([{s, e} | rest], blanks, text, grammar, acc) do
    blanks = Enum.drop_while(blanks, fn {_bs, be} -> be <= s end)
    inside = Enum.take_while(blanks, fn {bs, _be} -> bs < e end)
    source = blank(binary_part(text, s, e - s), s, inside)

    case TreeSitterWasm.highlight(grammar, source) do
      {:ok, caps} ->
        shifted = Enum.map(caps, fn {a, b, name} -> {a + s, b + s, name} end)
        inline_captures(rest, blanks, text, grammar, [shifted | acc])

      {:error, _} = error ->
        error
    end
  end

  # `source` (which starts at byte `offset` of the text) with the given ranges turned to spaces.
  defp blank(source, _offset, []), do: source

  defp blank(source, offset, ranges) do
    size = byte_size(source)

    {parts, at} =
      Enum.reduce(ranges, {[], 0}, fn {bs, be}, {parts, at} ->
        a = max(bs - offset, at)
        b = min(be - offset, size)

        if b <= a,
          do: {parts, at},
          else: {[:binary.copy(" ", b - a), binary_part(source, at, a - at) | parts], b}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(source, at, size - at) | parts]))
  end

  @doc """
  The tree of captures `{byte_start, byte_end, name}`: each node holds the captures inside its
  range. Ties (two names on one range) keep their order in the list, so a block capture listed
  before an inline one on the same range is its parent. Names not in the queries are dropped.

      iex> t = Geex.Markdown.Parse.tree([{0, 5, "paragraph"}, {0, 4, "inline"}, {1, 3, "strong"}], 6)
      iex> [%{type: :paragraph, children: [%{type: :inline, children: [%{type: :strong}]}]}] = t.children
      iex> t.e
      6
  """
  @spec tree([{non_neg_integer(), non_neg_integer(), String.t()}], non_neg_integer()) :: tree()
  def tree(captures, size) do
    captures
    |> Enum.flat_map(fn {s, e, name} ->
      case Map.fetch(@types, name) do
        {:ok, type} -> [{s, e, type}]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.sort_by(fn {{s, e, _type}, i} -> {s, -e, i} end)
    |> Enum.map(&elem(&1, 0))
    |> nest([node(:document, 0, size)])
  end

  defp node(type, s, e), do: %{type: type, s: s, e: e, children: []}

  defp nest([], stack), do: close(stack)

  defp nest([{s, e, type} | rest] = caps, [top | below] = stack) do
    cond do
      s >= top.s and e <= top.e -> nest(rest, [node(type, s, e) | stack])
      below == [] -> nest(rest, stack)
      true -> nest(caps, pop(stack))
    end
  end

  defp pop([top, parent | below]),
    do: [%{parent | children: [done(top) | parent.children]} | below]

  defp done(node), do: %{node | children: Enum.reverse(node.children)}

  defp close([root]), do: done(root)
  defp close(stack), do: close(pop(stack))
end
