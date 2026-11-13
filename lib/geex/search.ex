defmodule Geex.Search do
  @moduledoc """
  Finding a query in a text ([ADR-0053](../../doc/adr/0053-search.md) and its 2026-11-13
  amendment). Pure: the loop runs it off the key loop on the buffer's text (ADR-0035) and draws
  what it answers.

  **Where the matches are.** Each line's leftmost non-overlapping occurrences, from the line's
  start (`"aa"` in `"aaaa"` is at 0 and 2), never across a line end. The text is split on `"\\n"`
  before it is segmented, as `Geex.Buffer.Doc` does, so a CRLF line's `"\\r"` is no part of a
  match (it is dropped before matching, and the cursor never goes past it). Graphemes come from
  `Geex.Text`: a byte that isn't UTF-8 is one grapheme and matches only itself. An empty query
  matches nothing.

  **Smart case.** A query with no capital matches either case; one with a capital matches
  exactly. A capital is a grapheme that lowercasing changes (`"ǅ"` and the Kelvin sign count).
  Folding lowercases each grapheme of both sides, never uppercases (`"ß"` would become `"SS"`),
  and positions are always the original line's graphemes: lowercasing can change a grapheme's
  bytes (U+023A goes from 2 to 3), never their count.

  **The answer is packed.** All the matches, in document order, as one binary of 12 bytes each
  (`<<line::32, start::32, stop::32>>`, grapheme columns, `stop` exclusive). A large binary is
  shared between processes rather than copied, so the loop receives a million matches without
  copying them, and `count/1`, `next_at/2`, `index_of/2` and `on_lines/3` read it by binary search.
  The count, `Alt+N` and the highlights all read this one set.

  An ASCII line searched for an ASCII query goes by `:binary.matches/2`: inside a line (no
  `"\\n"`) every ASCII byte is one grapheme, so byte offsets are columns and the answer is exact.
  """

  alias Geex.{Ascii, Text}

  @typedoc "A text position: `{line, column}`, columns in graphemes."
  @type pos :: {non_neg_integer(), non_neg_integer()}
  @typedoc "One match: `{line, start, stop}`, grapheme columns, `stop` exclusive."
  @type match :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @typedoc "Every match, in document order, 12 bytes each (`matches/2`)."
  @type packed :: binary()

  @size 12

  @doc """
  Whether `query` has a capital: a grapheme that lowercasing changes. Then the search is exact.

      iex> {Geex.Search.capital?("foo"), Geex.Search.capital?("Foo"), Geex.Search.capital?("ǅ")}
      {false, true, true}
      iex> Geex.Search.capital?("123 é")
      false
  """
  @spec capital?(String.t()) :: boolean()
  def capital?(query), do: Enum.any?(Text.graphemes(query), &(String.downcase(&1) != &1))

  @doc """
  Every match of `query` in `text`, packed (see the moduledoc). An empty query matches nothing.

      iex> Geex.Search.matches("aaaa\\nbAA", "aa") |> Geex.Search.to_list()
      [{0, 0, 2}, {0, 2, 4}, {1, 1, 3}]
      iex> Geex.Search.matches("aaaa\\nbAA", "AA") |> Geex.Search.to_list()
      [{1, 1, 3}]
  """
  @spec matches(binary(), String.t()) :: packed()
  def matches(_text, ""), do: <<>>

  def matches(text, query) do
    finder = finder(query)

    text
    |> :binary.split("\n", [:global])
    |> Enum.with_index()
    |> Enum.reduce([], fn {line, i}, acc ->
      Enum.reduce(finder.(line), acc, fn {s, e}, acc -> [<<i::32, s::32, e::32>> | acc] end)
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @doc """
  The matches of `query` in one `line` (no `"\\n"`), as `{start, stop}` grapheme columns.

      iex> Geex.Search.line_matches("Straße STRASSE", "straße")
      [{0, 6}]
      iex> Geex.Search.line_matches("ab\\r", "b\\r")
      []
  """
  @spec line_matches(binary(), String.t()) :: [{non_neg_integer(), non_neg_integer()}]
  def line_matches(_line, ""), do: []
  def line_matches(line, query), do: finder(query).(line)

  @doc """
  The first match at or after `pos`, searching only as far as it must: forward from `pos`, then
  from the top down to it. `{match, wrapped?}`, or `nil`. For a big file, what the loop shows
  before every match is counted (ADR-0053's 2026-11-13 amendment).

      iex> Geex.Search.first_from("ab\\nab\\nab", "b", {1, 2})
      {{2, 1, 2}, false}
      iex> Geex.Search.first_from("ab\\nab\\nxx", "b", {2, 0})
      {{0, 1, 2}, true}
  """
  @spec first_from(binary(), String.t(), pos()) :: {match(), boolean()} | nil
  def first_from(_text, "", _pos), do: nil

  def first_from(text, query, {line, col}) do
    finder = finder(query)
    lines = :binary.split(text, "\n", [:global])
    {before, rest} = Enum.split(lines, line)

    forward =
      rest
      |> Enum.with_index(line)
      |> Enum.find_value(fn {l, i} ->
        Enum.find_value(finder.(l), fn {s, e} -> if i > line or s >= col, do: {i, s, e} end)
      end)

    cond do
      forward ->
        {forward, false}

      true ->
        # From the top, through the start line's matches before `col`.
        (before ++ Enum.take(rest, 1))
        |> Enum.with_index()
        |> Enum.find_value(fn {l, i} ->
          case finder.(l) do
            [{s, e} | _] -> {{i, s, e}, true}
            [] -> nil
          end
        end)
    end
  end

  @doc "How many matches `packed` holds."
  @spec count(packed()) :: non_neg_integer()
  def count(packed), do: div(byte_size(packed), @size)

  @doc """
  The `i`th match (0-based), or `nil`.

      iex> Geex.Search.matches("ab ab", "b") |> Geex.Search.at(1)
      {0, 4, 5}
  """
  @spec at(packed(), integer()) :: match() | nil
  def at(packed, i) when is_integer(i) do
    if i >= 0 and i < count(packed) do
      <<l::32, s::32, e::32>> = binary_part(packed, i * @size, @size)
      {l, s, e}
    end
  end

  @doc """
  The first match at or after `pos`, wrapping to the first: `{match, index, wrapped?}` (index
  0-based), or `nil` with no matches.

      iex> p = Geex.Search.matches("ab\\nab", "b")
      iex> Geex.Search.next_at(p, {0, 1})
      {{0, 1, 2}, 0, false}
      iex> Geex.Search.next_at(p, {0, 2})
      {{1, 1, 2}, 1, false}
      iex> Geex.Search.next_at(p, {1, 2})
      {{0, 1, 2}, 0, true}
  """
  @spec next_at(packed(), pos()) :: {match(), non_neg_integer(), boolean()} | nil
  def next_at(packed, pos) do
    case count(packed) do
      0 ->
        nil

      n ->
        i = first_not_before(packed, pos, 0, n)
        if i < n, do: {at(packed, i), i, false}, else: {at(packed, 0), 0, true}
    end
  end

  @doc """
  Where `match` is among the matches, 1-based, for "3 of 12"; `nil` when it isn't one.

      iex> p = Geex.Search.matches("aaaa", "aa")
      iex> {Geex.Search.index_of(p, {0, 2, 4}), Geex.Search.index_of(p, {0, 1, 3})}
      {2, nil}
  """
  @spec index_of(packed(), match()) :: pos_integer() | nil
  def index_of(packed, {l, s, _e} = match) do
    i = first_not_before(packed, {l, s}, 0, count(packed))
    if at(packed, i) == match, do: i + 1
  end

  @doc """
  The matches on lines `first..last`, for the highlights of what is on screen.

      iex> Geex.Search.matches("a\\nba\\na\\na", "a") |> Geex.Search.on_lines(1, 2)
      [{1, 1, 2}, {2, 0, 1}]
  """
  @spec on_lines(packed(), non_neg_integer(), non_neg_integer()) :: [match()]
  def on_lines(packed, first, last) do
    n = count(packed)
    i = first_not_before(packed, {first, 0}, 0, n)

    Stream.iterate(i, &(&1 + 1))
    |> Stream.take_while(&(&1 < n))
    |> Stream.map(&at(packed, &1))
    |> Enum.take_while(fn {l, _, _} -> l <= last end)
  end

  @doc """
  The matches on `line` that overlap columns `from` (inclusive) to `to` (exclusive): what one
  row of the screen shows, however many matches the whole line holds.

      iex> Geex.Search.matches("aXaXaXa", "a") |> Geex.Search.on_line(0, 1, 5)
      [{0, 2, 3}, {0, 4, 5}]
      iex> Geex.Search.matches("abab", "ab") |> Geex.Search.on_line(0, 1, 2)
      [{0, 0, 2}]
  """
  @spec on_line(packed(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: [match()]
  def on_line(packed, line, from, to) do
    n = count(packed)
    i = first_not_before(packed, {line, from}, 0, n)
    # The match before may start earlier and still reach into the window.
    i = if i > 0 and match?({^line, _, e} when e > from, at(packed, i - 1)), do: i - 1, else: i

    Stream.iterate(i, &(&1 + 1))
    |> Stream.take_while(&(&1 < n))
    |> Stream.map(&at(packed, &1))
    |> Enum.take_while(fn {l, s, _} -> l == line and s < to end)
  end

  @doc "Every match, unpacked."
  @spec to_list(packed()) :: [match()]
  def to_list(packed), do: for(<<l::32, s::32, e::32 <- packed>>, do: {l, s, e})

  @doc """
  Where `Alt+N` looks from: the selection's end in document order, or the cursor (inclusive).
  `selection` is `{anchor, active}` or `nil`.

      iex> Geex.Search.after_position({{0, 5}, {0, 2}}, {0, 2})
      {0, 5}
  """
  @spec after_position({pos(), pos()} | nil, pos()) :: pos()
  def after_position(nil, cursor), do: cursor
  def after_position({a, b}, _cursor), do: max(a, b)

  @doc """
  Where the search as it is typed starts: the selection's start in document order (so a
  pre-filled occurrence is match 1), or the cursor.

      iex> Geex.Search.start_position({{0, 5}, {0, 2}}, {0, 2})
      {0, 2}
  """
  @spec start_position({pos(), pos()} | nil, pos()) :: pos()
  def start_position(nil, cursor), do: cursor
  def start_position({a, b}, _cursor), do: min(a, b)

  # The index of the first match not before `pos`, in [lo, hi).
  defp first_not_before(_packed, _pos, lo, hi) when lo >= hi, do: lo

  defp first_not_before(packed, pos, lo, hi) do
    mid = div(lo + hi, 2)
    {l, s, _e} = at(packed, mid)

    if {l, s} < pos,
      do: first_not_before(packed, pos, mid + 1, hi),
      else: first_not_before(packed, pos, lo, mid)
  end

  # A function finding `query` in one line: its folded graphemes worked out once.
  defp finder(query) do
    fold? = not capital?(query)
    ascii_query = Ascii.first_high(query) == nil
    qs = fold(Text.graphemes(query), fold?)
    n = length(qs)
    q_tuple = List.to_tuple(qs)
    q_ascii = if fold?, do: String.downcase(query, :ascii), else: query

    fn line ->
      line = String.replace_suffix(line, "\r", "")

      line_ascii? = Ascii.first_high(line) == nil

      cond do
        ascii_query and line_ascii? ->
          hay = if fold?, do: String.downcase(line, :ascii), else: line
          for {at, len} <- :binary.matches(hay, q_ascii), do: {at, at + len}

        # A query holding a non-ASCII byte never matches an ASCII line: folded, it has no
        # capital, so its graphemes are unchanged and still not ASCII; exact, the bytes differ.
        line_ascii? ->
          []

        true ->
          line |> Text.graphemes() |> fold(fold?) |> List.to_tuple() |> scan(q_tuple, n, 0, [])
      end
    end
  end

  defp fold(graphemes, false), do: graphemes
  defp fold(graphemes, true), do: Enum.map(graphemes, &fold_one/1)

  # An ASCII byte folds by itself (String.downcase/1 gives the same); anything else by Unicode.
  defp fold_one(<<c>>) when c in ?A..?Z, do: <<c + 32>>
  defp fold_one(<<c>> = g) when c < 128, do: g
  defp fold_one(g), do: String.downcase(g)

  # Leftmost non-overlapping occurrences of `q` (a tuple of `n` graphemes) in the tuple `gs`.
  defp scan(gs, q, n, i, acc) do
    if i + n > tuple_size(gs) do
      Enum.reverse(acc)
    else
      if at_here?(gs, q, n, i, 0),
        do: scan(gs, q, n, i + n, [{i, i + n} | acc]),
        else: scan(gs, q, n, i + 1, acc)
    end
  end

  defp at_here?(_gs, _q, n, _i, n), do: true

  defp at_here?(gs, q, n, i, k),
    do: elem(gs, i + k) == elem(q, k) and at_here?(gs, q, n, i, k + 1)
end
