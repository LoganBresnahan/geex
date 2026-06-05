defmodule Geex.Edit.Resolve do
  @moduledoc """
  The pure matcher behind the `edit` (search/replace) tool (ADR-0020): given the
  current buffer text and one `{search, replace}` block, **locate** the search text
  and return a coordinate span + the replacement to splice there — or refuse with a
  classification the model can act on. It does **not** mutate; `Geex.Commands.Edit`
  applies the span via the `Geex.Buffer.Doc.replace/3` primitive.

  Ported from DeepSeek-Moby's hard-won apply engine, but **stricter** — geex refuses
  on uncertainty rather than guessing. Moby's scar: a "merge on uncertainty" fallback
  silently duplicated code on disk; geex never merges, never force-applies a fuzzy
  match. Two confident, deterministic tiers *apply*:

    1. **Exact-unique substring.** The search appears verbatim exactly once → that
       span. More than once → `:ambiguous` (the model must add context). This tier is
       grapheme-correct without byte math: positions are derived by splitting the real
       string (`pos_after/1`), so UTF-8 is handled the same way `Doc` indexes it.
    2. **Whitespace-normalized line window.** No exact hit, but a contiguous run of
       lines matches the search line-for-line after trimming → that window, with the
       replacement **re-indented to the file's actual indentation**. Again unique-or-
       refuse: >1 matching window → `:ambiguous`.

  No further tier *applies*. Where Moby would fuzzily apply an anchor/patch match
  (its riskiest path), geex instead **classifies the refusal** so the model gets an
  actionable message — `classify/2`: if most of the search's lines still exist in the
  file (just not as a contiguous block) the file likely changed → `:stale` ("re-read");
  otherwise the quoted text isn't there → `:not_found` ("quote exact text"). Empty
  search is refused (`:not_found`) — prepend/create is deferred.

  `String.myers_difference`-style similarity is available built-in, but the line-presence
  classifier here is simpler and sufficient for crafting the self-correction message;
  no hex dependency is needed (the hard part — robust fuzzy *apply* — has no maintained
  Elixir lib anyway, and geex deliberately does not do it).
  """

  # Fraction of the search's distinct non-blank lines that must still be present in the
  # file for a no-match to read as "stale" (re-read) rather than "not found" (re-quote).
  # Both messages steer the model to re-read and re-quote, so the boundary is not sharp.
  @stale_presence_threshold 0.5

  @type pos :: {non_neg_integer(), non_neg_integer()}
  @type span :: {pos(), pos()}
  @type reason :: :stale | :ambiguous | :not_found

  @doc """
  Resolve one `{search, replace}` block against `text`. Returns
  `{:ok, span, replacement}` (a `Doc.replace/3` range + the text to put there) or
  `{:error, :stale | :ambiguous | :not_found}`.
  """
  @spec resolve_block(String.t(), String.t(), String.t()) ::
          {:ok, span(), String.t()} | {:error, reason()}
  def resolve_block(text, search, replace)
      when is_binary(text) and is_binary(search) and is_binary(replace) do
    if String.trim(search) == "" do
      # Empty/whitespace-only search (prepend/create) is deferred — refuse rather than
      # guess where it goes.
      {:error, :not_found}
    else
      case exact(text, search, replace) do
        {:ok, _span, _repl} = hit -> hit
        :ambiguous -> {:error, :ambiguous}
        :none -> normalized(text, search, replace)
      end
    end
  end

  # --- tier 1: exact-unique substring ---

  defp exact(text, search, replace) do
    case occurrences(text, search) do
      0 ->
        :none

      1 ->
        [before, _after] = String.split(text, search, parts: 2)
        {:ok, {pos_after(before), pos_after(before <> search)}, replace}

      _more_than_one ->
        :ambiguous
    end
  end

  # Count *overlapping* occurrences. `String.split` counts non-overlapping, which
  # undercounts a self-overlapping search — e.g. "end\nend" occurs twice (overlapping) in
  # "end\nend\nend" yet splits into only two pieces. Treating that as unique would silently
  # apply at the first of several real matches; this must refuse :ambiguous. The applied
  # *position* still comes from String.split (grapheme-correct); this byte scan only counts.
  defp occurrences(text, search), do: count_overlapping(text, search, 0)

  defp count_overlapping(text, search, acc) do
    case :binary.match(text, search) do
      :nomatch ->
        acc

      {start, _len} ->
        rest = binary_part(text, start + 1, byte_size(text) - start - 1)
        count_overlapping(rest, search, acc + 1)
    end
  end

  # The {row, col} position immediately after `prefix` — i.e. where `prefix` ends. row =
  # newlines in prefix; col = graphemes in its last line. Grapheme-correct (String.length).
  defp pos_after(prefix) do
    lines = String.split(prefix, "\n")
    {length(lines) - 1, String.length(List.last(lines))}
  end

  # --- tier 2: whitespace-normalized contiguous line window (unique-or-refuse) ---

  defp normalized(text, search, replace) do
    content_lines = String.split(text, "\n")
    search_lines = String.split(search, "\n")
    n = length(search_lines)
    normalized = Enum.map(search_lines, &String.trim/1)
    last_start = length(content_lines) - n

    starts =
      if last_start < 0 do
        []
      else
        for i <- 0..last_start,
            window = Enum.slice(content_lines, i, n),
            Enum.map(window, &String.trim/1) == normalized,
            do: i
      end

    case starts do
      [i] ->
        window = Enum.slice(content_lines, i, n)
        end_line = i + n - 1
        end_col = content_lines |> Enum.at(end_line) |> String.length()
        span = {{i, 0}, {end_line, end_col}}
        {:ok, span, reindent(List.first(window), replace, line_ending(window))}

      [] ->
        {:error, classify(content_lines, search_lines)}

      _multiple ->
        {:error, :ambiguous}
    end
  end

  # Re-indent `replace` to the file: line 0 takes the matched line's indentation; later
  # lines keep their indentation *relative* to the replacement's first line, rebased onto
  # that indent. Blank lines stay blank. (Relative indent is space-counted, like Moby —
  # imperfect for tab-relative nesting, fine for the common case.) `ending` is the matched
  # window's line ending ("\r" for a CRLF file, else "") re-applied to every rebuilt line,
  # so a tier-2 match against a CRLF buffer does not silently flip it to LF.
  defp reindent(matched_line, replace, ending) do
    indent = leading_ws(matched_line)
    # Normalize the replacement to LF first (a CRLF replacement would otherwise double its
    # \r when we re-append the file's ending below).
    replace_lines = replace |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))
    base = replace_lines |> List.first() |> leading_ws() |> String.length()

    replace_lines
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, idx} ->
      body =
        cond do
          String.trim(line) == "" ->
            ""

          idx == 0 ->
            indent <> String.trim_leading(line)

          true ->
            relative = max(0, String.length(leading_ws(line)) - base)
            indent <> String.duplicate(" ", relative) <> String.trim_leading(line)
        end

      body <> ending
    end)
  end

  # The line ending the matched window uses: "\r" when every matched line is CRLF (the \r
  # is content, since Doc splits only on \n), otherwise "" (LF).
  defp line_ending(window) do
    if Enum.all?(window, &String.ends_with?(&1, "\r")), do: "\r", else: ""
  end

  defp leading_ws(line) do
    case Regex.run(~r/^\s*/, line) do
      [ws] -> ws
      _ -> ""
    end
  end

  # --- refusal classification (no apply — just a better message) ---

  # The search wasn't found exactly or as a trimmed window. If most of its distinct
  # non-blank lines still exist somewhere in the file, the block probably drifted (the
  # file changed) → :stale; otherwise the quoted text isn't here → :not_found.
  defp classify(content_lines, search_lines) do
    present_set = content_lines |> Enum.map(&String.trim/1) |> MapSet.new()

    needles =
      search_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case needles do
      [] ->
        :not_found

      lines ->
        present = Enum.count(lines, &MapSet.member?(present_set, &1))
        if present / length(lines) >= @stale_presence_threshold, do: :stale, else: :not_found
    end
  end
end
