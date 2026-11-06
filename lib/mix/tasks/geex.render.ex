defmodule Mix.Tasks.Geex.Render do
  @shortdoc "Print a markdown file as the read-only preview draws it"
  @moduledoc """
  The markdown preview's development tool ([ADR-0043](../../../doc/adr/0043-markdown-preview.md)
  §8), as `mix geex.highlight` is highlighting's: parse a markdown file with the installed
  Markdown and Markdown inline grammars (`Geex.Markdown.Parse`), lay it out at a width
  (`Geex.Markdown.Layout`) and print it in a theme's colours (`Geex.Markdown.Style`).

      mix geex.render README.md
      mix geex.render doc/vision.md --width 72 --map --stats

  - `--width N`: columns (default: the terminal's, else 80)
  - `--theme NAME`: an installed theme (default: the settings view's, else the terminal's)
  - `--map`: a gutter with the source line each row draws (what the preview keeps its place
    by, ADR-0043 §6)
  - `--stats`: sizes and timings on stderr
  - `--plain`: no colour

  Both grammars must be installed (`geex install markdown markdown_inline`).

  Fenced code is highlighted by the installed grammar for its language. Loads the app without
  starting it, like `mix geex.highlight`.
  """
  use Mix.Task

  alias Geex.Markdown.{Layout, Style}
  alias Geex.{Sgr, Theme}

  @switches [
    width: :integer,
    theme: :string,
    map: :boolean,
    stats: :boolean,
    plain: :boolean
  ]
  @gutter 6

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, paths, _invalid} = OptionParser.parse(args, strict: @switches)
    opts = Map.new(opts)

    path =
      case paths do
        [path] ->
          path

        _ ->
          Mix.raise(
            "usage: mix geex.render FILE [--width N] [--theme NAME] [--map] [--stats] [--plain]"
          )
      end

    text = File.read!(path)
    theme = theme(opts[:theme])
    width = (opts[:width] || columns()) - if(opts[:map], do: @gutter, else: 0)

    {load_us, grammars} =
      :timer.tc(fn ->
        case Geex.Markdown.handles() do
          {:ok, grammars} ->
            grammars

          {:error, {:missing, names}} ->
            Mix.raise("geex render: geex install #{Enum.join(names, " ")}")

          {:error, :update} ->
            Mix.raise("geex render: the Markdown grammars need an update")
        end
      end)

    {parse_us, parsed} =
      :timer.tc(fn ->
        case Geex.Markdown.parse(text, grammars) do
          {:ok, parsed} -> parsed
          {:error, reason} -> Mix.raise("geex render: parse failed: #{inspect(reason)}")
        end
      end)

    {layout_us, rows} = :timer.tc(fn -> Geex.Markdown.rows(parsed, width) end)

    IO.write(print(rows, parsed.text, theme, width, opts))

    if opts[:stats] do
      st = parsed.stats

      IO.puts(:stderr, """
      geex render #{path}: #{byte_size(text)} bytes, #{line_count(text)} lines → #{length(rows)} rows at #{width} columns
        grammars loaded   #{ms(load_us)}
        block parse       #{ms(parse_us - st.inline_us - st.code_us)}  (#{st.block_captures} captures, one call)
        inline parse      #{ms(st.inline_us)}  (#{st.inline_calls} calls, one per paragraph, heading or cell)
        code highlighting #{ms(st.code_us)}  (#{st.code_blocks} fenced blocks)
        layout            #{ms(layout_us)}\
      """)
    end
  end

  ## Printing

  defp print(rows, text, theme, width, opts) do
    lines = newlines(text)

    {out, _last} =
      Enum.map_reduce(rows, nil, fn row, last ->
        # A blank row between blocks belongs to the block after it, but the label goes on that
        # block's first drawn row.
        {gutter, last} =
          cond do
            not Map.get(opts, :map, false) -> {[], last}
            Map.get(row, :blank, false) -> {gutter(last, last, lines, theme, opts), last}
            true -> {gutter(row.src, last, lines, theme, opts), row.src}
          end

        body = Enum.map(row.runs, &paint(&1, theme, opts))
        fill = String.duplicate(" ", max(width - Layout.runs_width(row.runs), 0))
        {[gutter, body, paint({fill, []}, theme, opts), "\n"], last}
      end)

    out
  end

  defp gutter(src, src, _lines, theme, opts),
    do: paint({String.duplicate(" ", @gutter), [:muted]}, theme, opts)

  defp gutter(src, _last, lines, theme, opts) do
    label = src |> line_of(lines) |> Integer.to_string() |> String.pad_leading(@gutter - 2)
    paint({label <> "  ", [:muted]}, theme, opts)
  end

  defp paint({text, _roles}, _theme, %{plain: true}), do: text

  defp paint(run, theme, _opts) do
    {text, %{fg: fg, bg: bg, attrs: attrs}} = Style.run(theme, run)
    strike = if :strike in attrs, do: "\e[9m", else: ""
    [Sgr.escape(fg, bg, attrs -- [:strike]), strike, text, Sgr.reset()]
  end

  # The 1-based line of byte `at`, by binary search over the newlines' offsets.
  defp newlines(text),
    do: text |> :binary.matches("\n") |> Enum.map(&elem(&1, 0)) |> List.to_tuple()

  defp line_of(at, offsets), do: count_below(offsets, at, 0, tuple_size(offsets)) + 1

  defp count_below(_offsets, _at, lo, hi) when lo >= hi, do: lo

  defp count_below(offsets, at, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(offsets, mid) < at,
      do: count_below(offsets, at, mid + 1, hi),
      else: count_below(offsets, at, lo, mid)
  end

  defp line_count(text), do: tuple_size(newlines(text))

  defp theme(nil) do
    with name when is_binary(name) <- Geex.Settings.load()["theme"],
         {:ok, theme} <- Theme.named(name) do
      theme
    else
      _ -> Theme.default()
    end
  end

  defp theme(name) do
    case Theme.named(name) do
      {:ok, theme} ->
        theme

      _ ->
        Mix.raise(
          "geex render: no installed theme #{name} (installed: #{Enum.join(Theme.names(), ", ")})"
        )
    end
  end

  defp columns do
    case :io.columns() do
      {:ok, n} -> n
      _ -> 80
    end
  end

  defp ms(us), do: :io_lib.format("~.1f ms", [us / 1000]) |> IO.iodata_to_binary()
end
