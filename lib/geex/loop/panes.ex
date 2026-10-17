defmodule Geex.Loop.Panes do
  @moduledoc """
  The editor's file panes and their tabs ([ADR-0038](../../../doc/adr/0038-split-panes-and-tabs.md)).
  Pure: `Geex.Loop` holds one of these and asks it what to show; the buffers themselves live in
  their own processes.

  - **`split`** is how the editor's rectangle is divided (`Geex.Layout.split/2`): a pane, or a
    split of two.
  - **`panes`** maps each pane's id to its tabs and which one it shows (`at`).
  - **`pane`** is the current file pane: where keys go when the editor has focus, and where a
    file opens. It stays current while the tree or the edits pane has focus.
  - A **tab** is a buffer seen from one pane: `%{buffer, cursor, scroll, hscroll}`. The same
    buffer in two panes is one buffer (one text, one history) with a cursor and scroll per pane.
    The current tab's cursor lives in `Geex.Session` while it is current (the loop copies it
    out when it leaves); every other tab keeps its own here.

  Closing a pane's last tab closes the pane, unless it is the only one.
  """

  @type tab :: %{
          buffer: pid(),
          cursor: {non_neg_integer(), non_neg_integer()},
          scroll: non_neg_integer(),
          hscroll: non_neg_integer()
        }
  @type pane :: %{tabs: [tab()], at: non_neg_integer()}
  @type t :: %{
          split: Geex.Layout.split(),
          panes: %{pos_integer() => pane()},
          pane: pos_integer(),
          next: pos_integer()
        }

  @doc "One pane, no tabs."
  @spec new() :: t()
  def new, do: %{split: {:pane, 1}, panes: %{1 => %{tabs: [], at: 0}}, pane: 1, next: 2}

  @doc "A new tab for `buffer`, at the top of the file unless a cursor is given."
  @spec tab(pid(), {non_neg_integer(), non_neg_integer()}) :: tab()
  def tab(buffer, cursor \\ {0, 0}), do: %{buffer: buffer, cursor: cursor, scroll: 0, hscroll: 0}

  @doc "The current pane's shown tab, or `nil` when it has none."
  @spec current(t()) :: tab() | nil
  def current(ps), do: shown(ps, ps.pane)

  @doc "The tab pane `id` shows, or `nil`."
  @spec shown(t(), pos_integer()) :: tab() | nil
  def shown(ps, id) do
    %{tabs: tabs, at: at} = ps.panes[id]
    Enum.at(tabs, at)
  end

  @doc "Update the current tab with `fun` (a no-op when there is none)."
  @spec update_current(t(), (tab() -> tab())) :: t()
  def update_current(ps, fun), do: update_shown(ps, ps.pane, fun)

  @doc "Update the tab pane `id` shows with `fun`."
  @spec update_shown(t(), pos_integer(), (tab() -> tab())) :: t()
  def update_shown(ps, id, fun) do
    %{tabs: tabs, at: at} = pane = ps.panes[id]

    if at < length(tabs),
      do: put_in(ps.panes[id], %{pane | tabs: List.update_at(tabs, at, fun)}),
      else: ps
  end

  @doc """
  Show `buffer` in the current pane: its tab there if it has one, else a new tab at the end
  (with `cursor`). Returns the panes and whether the tab is new.
  """
  @spec show(t(), pid(), {non_neg_integer(), non_neg_integer()}) :: {t(), :new | :existing}
  def show(ps, buffer, cursor \\ {0, 0}) do
    %{tabs: tabs} = pane = ps.panes[ps.pane]

    case Enum.find_index(tabs, &(&1.buffer == buffer)) do
      nil ->
        pane = %{pane | tabs: tabs ++ [tab(buffer, cursor)], at: length(tabs)}
        {put_in(ps.panes[ps.pane], pane), :new}

      i ->
        {put_in(ps.panes[ps.pane], %{pane | at: i}), :existing}
    end
  end

  @doc "Show the current pane's tab `i` (0-based); out of range changes nothing."
  @spec select(t(), integer()) :: t()
  def select(ps, i) do
    %{tabs: tabs} = pane = ps.panes[ps.pane]
    if i >= 0 and i < length(tabs), do: put_in(ps.panes[ps.pane], %{pane | at: i}), else: ps
  end

  @doc "Show the current pane's next (`+1`) or previous (`-1`) tab, wrapping."
  @spec step(t(), integer()) :: t()
  def step(ps, delta) do
    %{tabs: tabs, at: at} = ps.panes[ps.pane]
    if tabs == [], do: ps, else: select(ps, Integer.mod(at + delta, length(tabs)))
  end

  @doc """
  Split the current pane in two, `:rows` (top and bottom) or `:cols` (side by side). The new
  pane, after it, shows the same tab (a copy: its own cursor and scroll from here on) and becomes
  current. A pane with no tabs isn't split.
  """
  @spec split(t(), :rows | :cols) :: t()
  def split(ps, dir) do
    case current(ps) do
      # Nothing to show twice: a pane with no tabs isn't split.
      nil ->
        ps

      tab ->
        id = ps.next

        %{
          ps
          | split: replace(ps.split, ps.pane, {dir, {:pane, ps.pane}, {:pane, id}}),
            panes: Map.put(ps.panes, id, %{tabs: [tab], at: 0}),
            pane: id,
            next: id + 1
        }
    end
  end

  @doc """
  Close the current tab. The pane then shows the tab before it (the first, if it was first). A
  pane left with no tabs closes, unless it is the only pane; the pane that takes its place
  becomes current.
  """
  @spec close_tab(t()) :: t()
  def close_tab(ps) do
    %{tabs: tabs, at: at} = ps.panes[ps.pane]

    if at < length(tabs),
      do: put_tabs(ps, ps.pane, List.delete_at(tabs, at), max(at - 1, 0)),
      else: ps
  end

  @doc "Drop every tab of `buffer` (it ended), closing panes left with none (not the last)."
  @spec drop_buffer(t(), pid()) :: t()
  def drop_buffer(ps, buffer) do
    Enum.reduce(ids(ps), ps, fn id, acc ->
      case acc.panes[id] do
        nil ->
          acc

        %{tabs: tabs, at: at} ->
          if Enum.any?(tabs, &(&1.buffer == buffer)) do
            # The shown tab keeps its place among those left; if it was this buffer's, the
            # pane shows the tab before it, as `close_tab/1` does.
            before = tabs |> Enum.take(at) |> Enum.count(&(&1.buffer == buffer))
            gone = if Enum.at(tabs, at).buffer == buffer, do: 1, else: 0
            kept = Enum.reject(tabs, &(&1.buffer == buffer))
            at = (at - before - gone) |> max(0) |> min(max(length(kept) - 1, 0))
            put_tabs(acc, id, kept, at)
          else
            acc
          end
      end
    end)
  end

  @doc "Every buffer in a tab, in any pane."
  @spec buffers(t()) :: MapSet.t(pid())
  def buffers(ps), do: for({_id, p} <- ps.panes, t <- p.tabs, into: MapSet.new(), do: t.buffer)

  @doc "Whether `buffer` is in a tab other than the current one (in any pane)."
  @spec elsewhere?(t(), pid()) :: boolean()
  def elsewhere?(ps, buffer) do
    Enum.any?(ps.panes, fn {id, %{tabs: tabs, at: at}} ->
      tabs
      |> Enum.with_index()
      |> Enum.any?(fn {t, i} -> t.buffer == buffer and not (id == ps.pane and i == at) end)
    end)
  end

  @doc "The panes' ids in reading order (left to right, top to bottom)."
  @spec ids(t()) :: [pos_integer()]
  def ids(ps), do: leaves(ps.split)

  @doc "Make pane `id` current."
  @spec focus(t(), pos_integer()) :: t()
  def focus(ps, id) when is_map_key(ps.panes, id), do: %{ps | pane: id}

  # Set a pane's tabs; an emptied pane closes unless it is the only one.
  defp put_tabs(ps, id, [], _at) do
    if map_size(ps.panes) == 1 do
      put_in(ps.panes[id], %{tabs: [], at: 0})
    else
      {split, heir} = remove(ps.split, id)
      pane = if ps.pane == id, do: heir, else: ps.pane
      %{ps | split: split, panes: Map.delete(ps.panes, id), pane: pane}
    end
  end

  defp put_tabs(ps, id, tabs, at), do: put_in(ps.panes[id], %{tabs: tabs, at: at})

  defp leaves({:pane, id}), do: [id]
  defp leaves({_dir, a, b}), do: leaves(a) ++ leaves(b)

  defp replace({:pane, id}, id, with), do: with
  defp replace({:pane, _} = leaf, _id, _with), do: leaf
  defp replace({dir, a, b}, id, with), do: {dir, replace(a, id, with), replace(b, id, with)}

  # Remove pane `id`: its sibling takes the split's place. Returns the new split and the pane
  # that inherits the space (the sibling's first pane).
  defp remove({_dir, {:pane, id}, other}, id), do: {other, hd(leaves(other))}
  defp remove({_dir, other, {:pane, id}}, id), do: {other, hd(leaves(other))}

  defp remove({dir, a, b}, id) do
    if id in leaves(a) do
      {a2, heir} = remove(a, id)
      {{dir, a2, b}, heir}
    else
      {b2, heir} = remove(b, id)
      {{dir, a, b2}, heir}
    end
  end
end
