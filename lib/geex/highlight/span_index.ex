defmodule Geex.Highlight.SpanIndex do
  @moduledoc """
  An overlay's spans indexed for a frame ([ADR-0035](../../../doc/adr/0035-the-loop-never-waits.md)):
  sorted by start byte, with the longest span's length, so the spans over a byte window (the
  lines on screen) are found by binary search instead of a walk over the whole file's spans.
  Built once per overlay by `Geex.Highlight.Reactor`, off the loop. Pure.
  """

  alias Geex.Highlight.Span

  @type t :: {tuple(), non_neg_integer()}

  @doc """
  Index `spans`.

      iex> alias Geex.Highlight.{Span, SpanIndex}
      iex> {spans, longest} = SpanIndex.build([%Span{start_byte: 5, end_byte: 9, capture: "b"}, %Span{start_byte: 0, end_byte: 2, capture: "a"}])
      iex> {Enum.map(Tuple.to_list(spans), & &1.capture), longest}
      {["a", "b"], 4}
  """
  @spec build([Span.t()]) :: t()
  def build(spans) do
    sorted = Enum.sort_by(spans, & &1.start_byte)
    longest = Enum.reduce(sorted, 0, &max(&2, &1.end_byte - &1.start_byte))
    {List.to_tuple(sorted), longest}
  end

  @doc """
  The spans that overlap bytes `[from, to)`, in start order.

      iex> alias Geex.Highlight.{Span, SpanIndex}
      iex> index = SpanIndex.build(for {s, e} <- [{0, 2}, {3, 30}, {10, 12}, {40, 44}], do: %Span{start_byte: s, end_byte: e, capture: "c"})
      iex> SpanIndex.window(index, 11, 20) |> Enum.map(&{&1.start_byte, &1.end_byte})
      [{3, 30}, {10, 12}]
      iex> SpanIndex.window(index, 44, 50)
      []
  """
  @spec window(t(), non_neg_integer(), non_neg_integer()) :: [Span.t()]
  def window({spans, longest}, from, to) do
    # A span overlapping the window starts before `to`, and (being at most `longest` long) no
    # earlier than `from - longest`.
    first = first_at_or_after(spans, from - longest)
    last = first_at_or_after(spans, to)

    if first >= last,
      do: [],
      else: for(i <- first..(last - 1)//1, s = elem(spans, i), s.end_byte > from, do: s)
  end

  # The index of the first span starting at or after `byte` (the count, if none does).
  defp first_at_or_after(spans, byte), do: search(spans, byte, 0, tuple_size(spans))

  defp search(_spans, _byte, lo, hi) when lo >= hi, do: lo

  defp search(spans, byte, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(spans, mid).start_byte < byte,
      do: search(spans, byte, mid + 1, hi),
      else: search(spans, byte, lo, mid)
  end
end
