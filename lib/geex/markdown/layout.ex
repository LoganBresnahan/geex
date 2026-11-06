defmodule Geex.Markdown.Layout do
  @moduledoc """
  The markdown preview's layout ([ADR-0043](../../../doc/adr/0043-markdown-preview.md) §5): a
  parsed markdown tree (`Geex.Markdown.Parse`) as rows, `width` columns wide. Pure.

  A row is `%{runs: [{text, roles}], src: byte}`. `roles` name what a run is (`:heading`,
  `:strong`, `:link`, `:code`, a table `:border` …); a code run also carries the highlight
  captures covering it, `{:captures, names}`, narrowest first. `Geex.Markdown.Style` turns roles
  into colours against a theme when drawing, so the layout never sees one, and a theme change
  only redraws. Widths are `Geex.Width` display widths, a rendering concern only.

  `src` is a byte of the source line the row draws, where it draws one (§6): each table row
  (a border takes the row beside it), each line of code (the label takes the fence line), each
  line of raw HTML or front matter. A paragraph's or heading's wrapped rows keep the block's
  start, and list and quote rows the starts of the blocks inside them. `Geex.Markdown.Place`
  keeps the reader's place by them.

  It corrects the grammars' gaps it can (§4): a table cell's column comes from the pipes before
  it, a heading drops its closing `#`s, an ordered list counts up from its first number, and
  `$…$` is math only where GitHub reads it so.

  Paragraphs and headings wrap at the width; code, raw HTML and front matter are cut with `…`;
  a table too wide for the width shrinks its widest columns and wraps their cells.
  """

  alias Geex.Width

  @blocks [
    :paragraph,
    :atx_heading,
    :setext_heading,
    :block_quote,
    :list,
    :fenced_code,
    :indented_code,
    :rule,
    :html,
    :table,
    :metadata
  ]
  @bullets ["•", "◦", "▪"]
  @tab "    "
  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "copy" => "©",
    "mdash" => "—",
    "ndash" => "–",
    "hellip" => "…",
    "rarr" => "→",
    "larr" => "←",
    "times" => "×"
  }

  @type run :: {String.t(), [term()]}
  @type row :: %{
          required(:runs) => [run()],
          required(:src) => non_neg_integer(),
          optional(:blank) => true
        }

  @doc """
  The rows of `tree` (parsed from `text`) at `width` columns. Option `:captures` is
  `fn code, info_word -> captures | nil end`, a fenced block's `captures/1` (`Geex.Markdown.parse/2`
  keeps them, built once per read); without it code is plain.
  """
  @spec rows(Geex.Markdown.Parse.tree(), String.t(), pos_integer(), keyword()) :: [row()]
  def rows(tree, text, width, opts \\ []) do
    ctx = %{
      text: text,
      defs: definitions(tree, text),
      code: Keyword.get(opts, :captures, fn _code, _language -> nil end),
      depth: 0,
      loose: true
    }

    width = max(width, 1)

    # Containers indent what they hold, so nesting deeper than the width allows would spill;
    # every row is cut to fit instead, since a preview has no horizontal scroll (§1).
    tree.children
    |> blocks(width, ctx)
    |> Enum.map(&%{&1 | runs: clip(&1.runs, width, [:muted])})
  end

  ## Blocks

  defp blocks(nodes, width, ctx) do
    nodes
    |> Enum.filter(&(&1.type in @blocks))
    |> Enum.map(&{&1, block(&1, width, ctx)})
    |> Enum.reject(fn {_node, rows} -> rows == [] end)
    |> join(ctx)
  end

  # Blocks are a blank row apart, except in a tight list, where only a blank source line parts
  # them.
  defp join([], _ctx), do: []

  defp join([{_node, rows} | rest], ctx) do
    rows ++
      Enum.flat_map(rest, fn {node, rows} ->
        if ctx.loose or blank_before?(ctx.text, node.s), do: [blank(node.s) | rows], else: rows
      end)
  end

  # `blank` survives the prefixes a quote or list adds to the row.
  defp blank(src), do: %{runs: [], src: src, blank: true}

  defp block(%{type: :paragraph} = n, width, ctx) do
    (child(n, :inline) || n) |> segments(ctx) |> wrap(width) |> to_rows(n.s)
  end

  defp block(%{type: :atx_heading} = n, width, ctx) do
    level = Enum.find_value(n.children, 1, &heading_level/1)
    heading(n |> child(:inline) |> without_closing(ctx.text), level, n.s, width, ctx)
  end

  defp block(%{type: :setext_heading} = n, width, ctx) do
    level = if child(n, :setext_h1), do: 1, else: 2
    content = with %{} = p <- child(n, :paragraph), do: child(p, :inline)
    heading(content, level, n.s, width, ctx)
  end

  defp block(%{type: :block_quote} = n, width, ctx) do
    n.children
    |> blocks(max(width - 2, 1), %{ctx | loose: true})
    |> Enum.map(fn row ->
      quoted = Enum.map(row.runs, fn {t, roles} -> {t, [:quote | roles]} end)
      %{row | runs: [{"▌ ", [:quote_bar]} | quoted]}
    end)
  end

  defp block(%{type: :list} = n, width, ctx) do
    items = Enum.filter(n.children, &(&1.type == :list_item))
    loose = loose?(items, ctx.text)
    start = start_number(items, ctx.text)
    marks = items |> Enum.with_index() |> Enum.map(fn {item, i} -> mark(item, start + i, ctx) end)
    mw = marks |> Enum.map(fn {m, _roles} -> Width.string(m) end) |> Enum.max(fn -> 1 end)
    inner = %{ctx | depth: ctx.depth + 1, loose: loose}
    indent = String.duplicate(" ", mw + 1)

    items
    |> Enum.zip(marks)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{item, {m, roles}}, i} ->
      rows =
        case blocks(item.children, max(width - mw - 1, 1), inner) do
          [] -> [blank(item.s)]
          rows -> rows
        end

      # Numbers line up on their right edge; bullets are all one column.
      pad = String.duplicate(" ", mw - Width.string(m))
      [first | more] = rows
      head = %{first | runs: [{pad <> m <> " ", roles} | first.runs]}
      body = Enum.map(more, &%{&1 | runs: [{indent, []} | &1.runs]})
      if i > 0 and loose, do: [blank(item.s), head | body], else: [head | body]
    end)
  end

  defp block(%{type: :fenced_code} = n, width, ctx) do
    {code, lang} = fenced(n, ctx.text)

    starts =
      case child(n, :code) do
        nil -> [n.s]
        c -> line_starts(ctx.text, c.s, c.e)
      end

    code_rows(code, lang, n.s, starts, width, ctx)
  end

  defp block(%{type: :indented_code} = n, width, ctx) do
    code =
      n
      |> plain(ctx.text)
      |> String.trim_trailing("\n")
      |> String.split("\n")
      |> Enum.map_join("\n", &dedent/1)

    code_rows(code, nil, n.s, line_starts(ctx.text, n.s, n.e), width, ctx)
  end

  defp block(%{type: :rule} = n, width, _ctx),
    do: [%{runs: [{String.duplicate("─", width), [:rule]}], src: n.s}]

  defp block(%{type: type} = n, width, ctx) when type in [:html, :metadata] do
    role = if type == :html, do: :html, else: :meta

    n
    |> plain(ctx.text)
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.zip_with(line_starts(ctx.text, n.s, n.e) |> pad_list(), fn line, src ->
      %{runs: clip([{expand(line), [role]}], width, [:muted]), src: src}
    end)
  end

  defp block(%{type: :table} = n, width, ctx), do: table(n, width, ctx)

  ## Headings

  defp heading_level(%{type: t}) when t in [:h1, :h2, :h3, :h4, :h5, :h6],
    do: t |> Atom.to_string() |> String.last() |> String.to_integer()

  defp heading_level(_node), do: nil

  # An ATX heading's closing sequence (CommonMark): a run of `#` at the end, after a space or
  # tab or alone, is no part of its text. The grammar keeps it in the inline node. An escaped
  # `\#` isn't one, since a backslash, not a space, comes before the run.
  defp without_closing(nil, _text), do: nil

  defp without_closing(inline, text) do
    case Regex.run(~r/(?:^|[ \t])#+[ \t]*$/, slice(text, inline), return: :index) do
      [{at, _len}] ->
        e = inline.s + at
        %{inline | e: e, children: Enum.filter(inline.children, &(&1.s < e))}

      nil ->
        inline
    end
  end

  defp heading(content, level, src, width, ctx) do
    rows =
      content
      |> segments(ctx)
      |> Enum.map(&add_roles(&1, [:heading, {:level, level}]))
      |> wrap(width)
      |> to_rows(src)

    # An empty heading (`#`) is still a heading: one empty row, and its rule.
    rows = if rows == [], do: [%{runs: [], src: src}], else: rows
    rows ++ heading_rule(level, src, width)
  end

  defp heading_rule(1, src, width),
    do: [%{runs: [{String.duplicate("━", width), [:heading_rule]}], src: src}]

  defp heading_rule(2, src, width),
    do: [%{runs: [{String.duplicate("─", width), [:heading_rule]}], src: src}]

  defp heading_rule(_level, _src, _width), do: []

  ## Lists

  defp mark(item, n, ctx) do
    cond do
      child(item, :task_done) -> {"☑", [:task_done]}
      child(item, :task_open) -> {"☐", [:task_open]}
      true -> number_or_bullet(child(item, :number), n, ctx)
    end
  end

  # An ordered list counts up from its first item's number (CommonMark's start), each item
  # keeping its own delimiter.
  defp number_or_bullet(nil, _n, ctx), do: {Enum.at(@bullets, rem(ctx.depth, 3)), [:bullet]}

  defp number_or_bullet(number, n, ctx),
    do: {"#{n}#{ctx.text |> slice(number) |> String.trim() |> String.last()}", [:bullet]}

  defp start_number(items, text) do
    with [first | _] <- items,
         %{} = number <- child(first, :number),
         {start, _rest} <- Integer.parse(String.trim(slice(text, number))) do
      start
    else
      _ -> 1
    end
  end

  # Loose (CommonMark): items, or blocks inside an item, parted by a blank line.
  defp loose?(items, text) do
    Enum.any?(Enum.drop(items, 1), &blank_before?(text, &1.s)) or
      Enum.any?(items, fn item ->
        item.children
        |> Enum.filter(&(&1.type in @blocks))
        |> Enum.drop(1)
        |> Enum.any?(&blank_before?(text, &1.s))
      end)
  end

  ## Code

  @doc """
  The fenced blocks of `tree` that name a language, as `{code, info word}`: what the preview
  highlights once per read (`Geex.Markdown.parse/2`), the same code the layout draws.
  """
  @spec code_blocks(Geex.Markdown.Parse.tree(), String.t()) :: [{String.t(), String.t()}]
  def code_blocks(tree, text) do
    for n <- all(tree, :fenced_code),
        {code, lang} = fenced(n, text),
        lang != nil,
        do: {code, lang}
  end

  defp fenced(n, text) do
    lang =
      with %{} = node <- find(n, [:language, :info]),
           [word | _] <- String.split(slice(text, node)),
           do: word

    code =
      case child(n, :code) do
        nil -> ""
        c -> c |> plain(text) |> String.trim_trailing("\n")
      end

    {code, lang}
  end

  # Every row starts with a gutter column (`:code_gutter`), which `Geex.Markdown.Style` draws as
  # a bar when the theme has no tint for code (§5).
  @gutter {" ", [:code_block, :code_gutter]}

  defp code_rows(code, lang, src, starts, width, ctx) do
    captures = if lang, do: ctx.code.(code, lang)

    label =
      if lang,
        do: [
          %{
            runs: pad([@gutter, {lang, [:code_block, :code_label]}], width, [:code_block]),
            src: src
          }
        ],
        else: []

    {lines, _offset} =
      code
      |> String.split("\n")
      |> Enum.map_reduce(0, fn line, offset ->
        {line_runs(String.trim_trailing(line, "\r"), offset, captures),
         offset + byte_size(line) + 1}
      end)

    label ++
      Enum.zip_with(lines, pad_list(starts), fn runs, line_src ->
        row = clip([@gutter | runs], width, [:code_block, :muted])
        %{runs: pad(row, width, [:code_block]), src: line_src}
      end)
  end

  @doc """
  A fenced block's highlight spans as `byte => [capture]`, narrowest first and, at equal width,
  the most dotted first: the order `Geex.Highlight.Paint` decides a byte's colour in, so drawing
  takes the first one the theme styles. `nil` for no spans.
  """
  @spec captures([Geex.Highlight.Span.t()] | nil) :: %{non_neg_integer() => [String.t()]} | nil
  def captures(nil), do: nil
  def captures([]), do: nil

  def captures(spans) do
    spans
    |> Enum.sort_by(&{-(&1.end_byte - &1.start_byte), dots(&1.capture)})
    |> Enum.reduce(%{}, fn span, acc ->
      Enum.reduce(span.start_byte..(span.end_byte - 1)//1, acc, fn b, acc ->
        Map.update(acc, b, [span.capture], &[span.capture | List.delete(&1, span.capture)])
      end)
    end)
  end

  defp dots(capture), do: capture |> :binary.matches(".") |> length()

  defp line_runs("", _offset, _captures), do: []
  defp line_runs(line, _offset, nil), do: [{expand(line), [:code_block]}]

  defp line_runs(line, offset, captures) do
    0..(byte_size(line) - 1)//1
    |> Enum.chunk_by(&Map.get(captures, offset + &1))
    |> Enum.map(fn [first | _] = bytes ->
      seg = expand(binary_part(line, first, length(bytes)))

      case Map.get(captures, offset + first) do
        nil -> {seg, [:code_block]}
        names -> {seg, [:code_block, {:captures, names}]}
      end
    end)
  end

  # The bytes the lines in `[s, e)` start at, the first at `s` (which may be mid-line, after a
  # list's indent): the source line each row of a block draws.
  defp line_starts(text, s, e) do
    rest =
      for {at, 1} <- :binary.matches(text, "\n", scope: {s, max(e - s, 0)}),
          at + 1 < e,
          do: at + 1

    [s | rest]
  end

  # A list of row sources long enough for any count of rows: the last repeats.
  defp pad_list(list), do: Stream.concat(list, Stream.repeatedly(fn -> List.last(list) end))

  defp dedent("    " <> rest), do: rest
  defp dedent("\t" <> rest), do: rest
  defp dedent(line), do: String.trim_leading(line, " ")

  defp expand(text), do: String.replace(text, "\t", @tab)

  ## Tables

  defp table(n, width, ctx) do
    aligns =
      case child(n, :table_delimiter) do
        nil ->
          []

        row ->
          row.children |> Enum.filter(&(&1.type == :table_delimiter_cell)) |> Enum.map(&align/1)
      end

    header_node = child(n, :table_header)
    header = cells(header_node, ctx.text)
    cols = max(length(header), 1)
    body_nodes = Enum.filter(n.children, &(&1.type == :table_row))

    grid =
      [header | Enum.map(body_nodes, &cells(&1, ctx.text))]
      |> Enum.map(fn row ->
        for c <- 0..(cols - 1)//1 do
          case List.keyfind(row, c, 0) do
            {^c, cell} -> cell |> segments(ctx) |> trim() |> unescape_pipes()
            nil -> []
          end
        end
      end)

    columns = for c <- 0..(cols - 1)//1, do: Enum.map(grid, &cell_text(Enum.at(&1, c)))
    room = width - (cols + 1) - 2 * cols

    if room < cols do
      block(%{n | type: :html}, width, ctx)
    else
      widths = fit_columns(columns, room)
      [head | body] = grid
      # Each row names its own line; a border takes the row beside it.
      head_src = if header_node, do: header_node.s, else: n.s
      srcs = Enum.map(body_nodes, & &1.s)
      last_src = List.last(srcs) || head_src

      [border("┌", "┬", "┐", widths, head_src)] ++
        table_row(head, widths, aligns, [:table_header], head_src) ++
        [border("├", "┼", "┤", widths, head_src)] ++
        Enum.flat_map(Enum.zip(body, srcs), fn {row, src} ->
          table_row(row, widths, aligns, [], src)
        end) ++
        [border("└", "┴", "┘", widths, last_src)]
    end
  end

  # GFM takes the backslash out of a cell's `\|` before inline parsing, so a code span in a
  # table shows `|` too (text already does: `\|` there is an escape).
  defp unescape_pipes(segs) do
    Enum.map(segs, fn
      :break -> :break
      {t, roles} -> {String.replace(t, "\\|", "|"), roles}
    end)
  end

  # A row's cells as `{column, cell}`. GFM places a cell by the unescaped pipes before it in the
  # row (a pipe inside a code span counting too), less one when the row starts with a pipe; the
  # grammar gives an empty `||` no cell, so its position among the cells would shift the rest.
  defp cells(nil, _text), do: []

  defp cells(row, text) do
    lead = if String.starts_with?(String.trim_leading(slice(text, row)), "|"), do: 1, else: 0

    for cell <- row.children, cell.type == :table_cell do
      {pipes(binary_part(text, row.s, cell.s - row.s), 0) - lead, cell}
    end
  end

  defp pipes(<<?\\, _escaped, rest::binary>>, n), do: pipes(rest, n)
  defp pipes(<<?|, rest::binary>>, n), do: pipes(rest, n + 1)
  defp pipes(<<_byte, rest::binary>>, n), do: pipes(rest, n)
  defp pipes(<<>>, n), do: n

  defp align(cell) do
    case {child(cell, :align_left), child(cell, :align_right)} do
      {l, r} when l != nil and r != nil -> :center
      {nil, r} when r != nil -> :right
      _ -> :left
    end
  end

  # Columns as wide as their widest cell when that fits. When it doesn't, a column starts at its
  # typical cell (the 90th percentile) or its longest word, whichever is wider: a few long cells
  # wrap rather than widening a column of short ones, and no word breaks while that can be
  # helped (one wider than an even share of the room still may). The room left goes to the
  # columns with long cells, by how much they want. Only when even those widths don't fit does
  # the widest column give way.
  defp fit_columns(columns, room) do
    natural = Enum.map(columns, fn texts -> texts |> Enum.map(&Width.string/1) |> max_or(1) end)
    even = max(div(room, length(columns)), 1)

    if Enum.sum(natural) <= room do
      natural
    else
      typical =
        Enum.map(columns, fn texts ->
          widths = Enum.map(texts, &Width.string/1)
          word = texts |> Enum.flat_map(&String.split/1) |> Enum.map(&Width.string/1) |> max_or(1)
          max(percentile(widths, 0.9), min(word, even)) |> max(1)
        end)

      if Enum.sum(typical) <= room,
        do: share(typical, natural, room - Enum.sum(typical)),
        else: shrink(typical, room)
    end
  end

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, trunc(p * (length(sorted) - 1)), 1)
  end

  defp share(typical, natural, spare) do
    wants = Enum.zip_with(natural, typical, &(&1 - &2))
    total = max(Enum.sum(wants), 1)
    given = Enum.map(wants, &div(&1 * spare, total))
    left = spare - Enum.sum(given)

    # What rounding left over goes one column at a time to the ones still wanting most.
    extra =
      wants
      |> Enum.zip(given)
      |> Enum.with_index()
      |> Enum.sort_by(fn {{want, got}, _i} -> got - want end)
      |> Enum.take(left)
      |> MapSet.new(fn {_pair, i} -> i end)

    [typical, given]
    |> Enum.zip_with(fn [t, g] -> t + g end)
    |> Enum.with_index()
    |> Enum.map(fn {w, i} -> if MapSet.member?(extra, i), do: w + 1, else: w end)
  end

  # Take a column from the widest until the row fits.
  defp shrink(widths, room) do
    if Enum.sum(widths) <= room do
      widths
    else
      widest = Enum.max(widths)
      i = Enum.find_index(widths, &(&1 == widest))
      shrink(List.replace_at(widths, i, max(widest - 1, 1)), room)
    end
  end

  defp table_row(cells, widths, aligns, roles, src) do
    columns =
      cells
      |> Enum.zip(widths)
      |> Enum.map(fn {segs, w} -> segs |> Enum.map(&add_roles(&1, roles)) |> wrap(w) end)

    height = columns |> Enum.map(&length/1) |> Enum.max(fn -> 1 end) |> max(1)

    for line <- 0..(height - 1)//1 do
      runs =
        columns
        |> Enum.zip(widths)
        |> Enum.with_index()
        |> Enum.flat_map(fn {{lines, w}, c} ->
          [{" ", []} | aligned(Enum.at(lines, line, []), w, Enum.at(aligns, c, :left))] ++
            [{" │", [:border]}]
        end)

      %{runs: [{"│", [:border]} | runs], src: src}
    end
  end

  defp aligned(runs, w, align) do
    gap = max(w - runs_width(runs), 0)

    case align do
      :right -> [{spaces(gap), []} | runs]
      :center -> [{spaces(div(gap, 2)), []} | runs] ++ [{spaces(gap - div(gap, 2)), []}]
      :left -> runs ++ [{spaces(gap), []}]
    end
  end

  defp border(l, m, r, widths, src) do
    line = l <> Enum.map_join(widths, m, &String.duplicate("─", &1 + 2)) <> r
    %{runs: [{line, [:border]}], src: src}
  end

  # A cell's text on one line, its whitespace collapsed: what its widths are measured on.
  defp cell_text(segs) do
    segs
    |> Enum.map_join(fn
      :break -> " "
      {t, _roles} -> t
    end)
    |> String.split()
    |> Enum.join(" ")
  end

  defp max_or([], default), do: default
  defp max_or(values, default), do: max(Enum.max(values), default)

  ## Inline content: a node's text as segments `{text, roles}`, or `:break` for a hard break.

  defp segments(nil, _ctx), do: []
  defp segments(node, ctx), do: walk(node.s, node.e, node.children, [], ctx)

  defp walk(from, to, children, roles, ctx) do
    {segs, at} =
      Enum.reduce(children, {[], from}, fn child, {acc, at} ->
        {[inline(child, roles, ctx), text_seg(ctx.text, at, child.s, roles) | acc],
         max(at, child.e)}
      end)

    List.flatten(Enum.reverse([text_seg(ctx.text, at, to, roles) | segs]))
  end

  defp text_seg(_text, a, b, _roles) when b <= a, do: []
  defp text_seg(text, a, b, roles), do: [{binary_part(text, a, b - a), roles}]

  defp inline(%{type: type}, _roles, _ctx) when type in [:continuation, :delimiter], do: []

  defp inline(%{type: :emphasis} = n, roles, ctx),
    do: walk(n.s, n.e, n.children, roles ++ [:em], ctx)

  defp inline(%{type: :strong} = n, roles, ctx),
    do: walk(n.s, n.e, n.children, roles ++ [:strong], ctx)

  defp inline(%{type: :strike} = n, roles, ctx),
    do: walk(n.s, n.e, n.children, roles ++ [:strike], ctx)

  defp inline(%{type: :code_span} = n, roles, ctx),
    do: [{code_span(n, ctx.text), roles ++ [:code]}]

  defp inline(%{type: :link} = n, roles, ctx), do: link(n, roles, ctx)

  # A reference link only links when the document defines its label; tree-sitter can't know,
  # so `[x]` with no definition is text, brackets and all.
  defp inline(%{type: :reference_link} = n, roles, ctx) do
    if MapSet.member?(ctx.defs, reference_label(n, ctx.text)),
      do: link(n, roles, ctx),
      else: walk(n.s, n.e, n.children, roles, ctx)
  end

  defp inline(%{type: :image} = n, roles, ctx) do
    alt =
      case child(n, :image_description) do
        nil -> []
        d -> walk(d.s, d.e, d.children, roles ++ [:image], ctx)
      end

    [{"▣ ", roles ++ [:image]} | alt]
  end

  defp inline(%{type: :autolink} = n, roles, ctx) do
    url = ctx.text |> slice(n) |> String.trim_leading("<") |> String.trim_trailing(">")
    [{url, roles ++ [:link]}]
  end

  defp inline(%{type: :escape} = n, roles, ctx),
    do: [{ctx.text |> slice(n) |> String.trim_leading("\\"), roles}]

  defp inline(%{type: :hard_break}, _roles, _ctx), do: [:break]
  defp inline(%{type: :entity} = n, roles, ctx), do: [{entity(slice(ctx.text, n)), roles}]
  defp inline(%{type: :html_tag} = n, roles, ctx), do: [{slice(ctx.text, n), roles ++ [:html]}]

  defp inline(%{type: :latex} = n, roles, ctx) do
    raw = slice(ctx.text, n)
    if math?(raw, ctx.text, n.e), do: [{raw, roles ++ [:code]}], else: [{raw, roles}]
  end

  defp inline(n, roles, ctx), do: walk(n.s, n.e, n.children, roles, ctx)

  # GitHub's rule for inline math: the opening `$` not followed by whitespace, and the closing
  # `$` neither preceded by whitespace nor followed by a letter or digit. Otherwise the span is
  # text, so prices and shell variables in prose stay prose. `$$…$$` is display math.
  defp math?("$$" <> _ = raw, _text, _e), do: byte_size(raw) > 4

  defp math?(raw, text, e) when byte_size(raw) >= 3 do
    inner = binary_part(raw, 1, byte_size(raw) - 2)
    after_ = String.first(binary_part(text, e, byte_size(text) - e)) || ""

    String.starts_with?(raw, "$") and String.ends_with?(raw, "$") and
      not String.match?(inner, ~r/\A\s|\s\z/u) and not String.match?(after_, ~r/\A[\p{L}\p{N}]/u)
  end

  defp math?(_raw, _text, _e), do: false

  defp link(n, roles, ctx) do
    case child(n, :link_text) do
      nil -> walk(n.s, n.e, n.children, roles, ctx)
      t -> walk(t.s, t.e, t.children, roles ++ [:link], ctx)
    end
  end

  defp reference_label(n, text) do
    case child(n, :link_label) || child(n, :link_text) do
      nil -> ""
      label -> normalize(slice(text, label))
    end
  end

  defp definitions(tree, text) do
    tree
    |> all(:link_definition)
    |> Enum.flat_map(fn d ->
      case child(d, :link_label) do
        nil -> []
        label -> [normalize(slice(text, label))]
      end
    end)
    |> MapSet.new()
  end

  defp normalize(label) do
    label
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split()
    |> Enum.join(" ")
    |> String.downcase()
  end

  # CommonMark: line endings become spaces, and one space each side comes off when both are
  # there (so `` `` a`b `` `` shows a`b).
  defp code_span(n, text) do
    {a, b} =
      case Enum.filter(n.children, &(&1.type == :delimiter)) do
        [] -> {n.s, n.e}
        delims -> {hd(delims).e, List.last(delims).s}
      end

    inner = %{n | s: a, e: max(a, b)} |> plain(text) |> String.replace(~r/\r?\n/, " ")

    if byte_size(inner) > 2 and String.starts_with?(inner, " ") and String.ends_with?(inner, " ") and
         String.trim(inner) != "",
       do: binary_part(inner, 1, byte_size(inner) - 2),
       else: inner
  end

  defp entity("&#" <> rest = raw) do
    {digits, base} =
      case rest do
        "x" <> hex -> {hex, 16}
        "X" <> hex -> {hex, 16}
        dec -> {dec, 10}
      end

    case Integer.parse(String.trim_trailing(digits, ";"), base) do
      {cp, ""} when cp in 1..0x10FFFF and cp not in 0xD800..0xDFFF -> <<cp::utf8>>
      _ -> raw
    end
  end

  defp entity("&" <> name = raw), do: Map.get(@entities, String.trim_trailing(name, ";"), raw)

  defp trim(segs) do
    segs
    |> trim_edge(&String.trim_leading/1)
    |> Enum.reverse()
    |> trim_edge(&String.trim_trailing/1)
    |> Enum.reverse()
  end

  defp trim_edge([{t, roles} | rest], fun) do
    case fun.(t) do
      "" -> trim_edge(rest, fun)
      t -> [{t, roles} | rest]
    end
  end

  defp trim_edge(segs, _fun), do: segs

  defp add_roles(:break, _roles), do: :break
  defp add_roles({t, rs}, roles), do: {t, roles ++ rs}

  ## Wrapping: segments to lines of runs, greedy, breaking at spaces; a word wider than the
  ## width breaks between graphemes.

  @doc false
  @spec wrap([{String.t(), [term()]} | :break], pos_integer()) :: [[run()]]
  def wrap(segments, width) do
    case segments |> tokens() |> words() do
      [] -> []
      elements -> fill(elements, width)
    end
  end

  defp tokens(segments) do
    Enum.flat_map(segments, fn
      :break ->
        [:break]

      {text, roles} ->
        ~r/[ \t\r\n]+/
        |> Regex.split(text, include_captures: true)
        |> Enum.flat_map(fn
          "" ->
            []

          piece ->
            if String.trim(piece) == "", do: [{:space, roles}], else: [{:text, piece, roles}]
        end)
    end)
  end

  defp words(tokens) do
    {acc, cur} =
      Enum.reduce(tokens, {[], []}, fn
        {:text, t, roles}, {acc, cur} -> {acc, [{t, roles} | cur]}
        other, {acc, cur} -> {[other | flush(cur, acc)], []}
      end)

    Enum.reverse(flush(cur, acc))
  end

  defp flush([], acc), do: acc

  defp flush(cur, acc) do
    pieces = Enum.reverse(cur)
    [{:word, pieces, runs_width(pieces)} | acc]
  end

  # Lines accumulate newest first, and the line being filled runs backwards.
  defp fill(elements, width) do
    {lines, line, _w, _space} =
      Enum.reduce(elements, {[], [], 0, nil}, fn
        :break, {lines, line, _w, _sp} ->
          {[Enum.reverse(line) | lines], [], 0, nil}

        {:space, roles}, {lines, line, w, _sp} ->
          {lines, line, w, if(w > 0, do: roles)}

        {:word, pieces, ww}, {lines, line, w, sp} ->
          cond do
            w == 0 and ww <= width ->
              {lines, Enum.reverse(pieces), ww, nil}

            w > 0 and w + 1 + ww <= width ->
              {lines, Enum.reverse(pieces) ++ [{" ", sp || []} | line], w + 1 + ww, nil}

            ww <= width ->
              {[Enum.reverse(line) | lines], Enum.reverse(pieces), ww, nil}

            true ->
              lines = if w > 0, do: [Enum.reverse(line) | lines], else: lines
              {full, rest, rw} = split_word(pieces, width)
              {Enum.reverse(full) ++ lines, rest, rw, nil}
          end
      end)

    [Enum.reverse(line) | lines]
    |> Enum.reverse()
    |> Enum.map(&merge/1)
  end

  defp split_word(pieces, width) do
    {full, cur, cw} =
      for({t, roles} <- pieces, g <- String.graphemes(t), do: {g, roles})
      |> Enum.reduce({[], [], 0}, fn {g, roles}, {full, cur, cw} ->
        gw = Width.cells(g)

        if cw > 0 and cw + gw > width,
          do: {[Enum.reverse(cur) | full], [{g, roles}], gw},
          else: {full, [{g, roles} | cur], cw + gw}
      end)

    {Enum.reverse(full), cur, cw}
  end

  defp merge(runs) do
    runs
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn [{_t, roles} | _] = same -> {Enum.map_join(same, &elem(&1, 0)), roles} end)
  end

  ## Helpers

  defp to_rows(lines, src), do: Enum.map(lines, &%{runs: &1, src: src})

  @doc false
  @spec runs_width([run()]) :: non_neg_integer()
  def runs_width(runs), do: Enum.reduce(runs, 0, fn {t, _roles}, acc -> acc + Width.string(t) end)

  defp pad(runs, width, roles) do
    case width - runs_width(runs) do
      gap when gap > 0 -> runs ++ [{spaces(gap), roles}]
      _ -> runs
    end
  end

  # `runs` cut to `width` columns, the last one an ellipsis when anything was cut.
  defp clip(runs, width, ellipsis_roles) do
    if runs_width(runs) <= width,
      do: runs,
      else: cut(runs, max(width - 1, 0), []) ++ [{"…", ellipsis_roles}]
  end

  defp cut([], _room, acc), do: Enum.reverse(acc)

  defp cut([{t, roles} | rest], room, acc) do
    tw = Width.string(t)

    if tw <= room,
      do: cut(rest, room - tw, [{t, roles} | acc]),
      else: Enum.reverse([{cols(t, room), roles} | acc])
  end

  defp cols(text, room) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, w} ->
      gw = Width.cells(g)
      if w + gw > room, do: {:halt, {acc, w}}, else: {:cont, {[g | acc], w + gw}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp spaces(n), do: String.duplicate(" ", max(n, 0))

  defp child(node, type), do: Enum.find(node.children, &(&1.type == type))

  defp find(node, types) do
    Enum.find_value(node.children, fn c ->
      if c.type in types, do: c, else: find(c, types)
    end)
  end

  defp all(node, type) do
    mine = if node.type == type, do: [node], else: []
    mine ++ Enum.flat_map(node.children, &all(&1, type))
  end

  defp slice(text, node), do: binary_part(text, node.s, node.e - node.s)

  # A node's text without its container prefixes (`block_continuation`: a quote's `> `, a
  # list's indent).
  defp plain(node, text) do
    {parts, at} =
      node
      |> all(:continuation)
      |> Enum.sort_by(& &1.s)
      |> Enum.reduce({[], node.s}, fn c, {parts, at} ->
        a = min(max(c.s, at), node.e)
        b = min(max(c.e, a), node.e)
        {[binary_part(text, at, a - at) | parts], b}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(text, at, node.e - at) | parts]))
  end

  # Whether the line before the one holding byte `at` is blank (a quote's bare `>` counts).
  defp blank_before?(text, at) do
    case line_start(text, at) do
      0 ->
        false

      start ->
        prev = line_start(text, start - 1)

        binary_part(text, prev, start - 1 - prev)
        |> String.trim()
        |> String.trim(">")
        |> String.trim() == ""
    end
  end

  defp line_start(_text, 0), do: 0

  defp line_start(text, at) do
    if :binary.at(text, at - 1) == ?\n, do: at, else: line_start(text, at - 1)
  end
end
