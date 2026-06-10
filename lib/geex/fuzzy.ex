defmodule Geex.Fuzzy do
  @moduledoc """
  A small, **pure** fuzzy matcher — the ranking behind the command palette
  ([ADR-0028](../../doc/adr/0028-editor-shell-and-minibuffer.md)) and, later, the file/buffer
  finder.

  `score/2` asks: is `query` a (case-insensitive) **subsequence** of `candidate`, and how good
  a match is it? It returns `nil` when no subsequence match exists, or a non-negative integer
  where **higher is better**. The scoring is a single greedy left-to-right walk (O(n) in the
  candidate length — no backtracking), which is plenty for short command names and keeps the
  ranking predictable:

    * each matched character is worth a base point;
    * a **run** of consecutive matches compounds (so `cop` scores higher against `copy` than
      against `c-o-p` scattered), making prefix/substring hits float to the top;
    * a match right after a **word boundary** (start, space, `_`, `-`, `.`, `:`) earns a bonus,
      so an acronym-style query (`sa` → `select all`) ranks well.

  An empty query matches everything at score `0` — callers keep their input order. The matcher
  is content-only: it knows nothing about commands, so the finder can reuse it over file paths.
  """

  @base 1
  @run 10
  @boundary 8

  @doc "True when `query` is a case-insensitive subsequence of `candidate`."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(candidate, query) when is_binary(candidate) and is_binary(query),
    do: score(candidate, query) != nil

  @doc """
  Score `candidate` against `query`: `nil` for no match, else a non-negative integer
  (higher = better). Case-insensitive; an empty `query` scores `0`.
  """
  @spec score(String.t(), String.t()) :: non_neg_integer() | nil
  def score(candidate, query) when is_binary(candidate) and is_binary(query) do
    c = candidate |> String.downcase() |> String.to_charlist()
    q = query |> String.downcase() |> String.to_charlist()
    walk(c, q, ?\s, 0, 0)
  end

  # query exhausted → all chars matched; `acc` is the score.
  defp walk(_c, [], _prev, _run, acc), do: acc
  # candidate exhausted with query left → not a subsequence.
  defp walk([], _q, _prev, _run, _acc), do: nil

  # A match: bank the base point + the boundary bonus + the compounding run bonus, and
  # carry a longer run forward.
  defp walk([h | ct], [h | qt], prev, run, acc) do
    boundary = if boundary?(prev), do: @boundary, else: 0
    walk(ct, qt, h, run + 1, acc + @base + boundary + run * @run)
  end

  # A miss: advance the candidate, breaking the run; remember this char as the new `prev`
  # so the *next* candidate char knows whether it sits on a word boundary.
  defp walk([h | ct], q, _prev, _run, acc), do: walk(ct, q, h, 0, acc)

  defp boundary?(c), do: c in [?\s, ?_, ?-, ?., ?:, ?/]
end
