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
  - A **tab** is a buffer seen from one pane: `%{buffer, cursor, scroll, hscroll, hold}`. The
    same buffer in two panes is one buffer (one text, one history) with a cursor and scroll per
    pane. The current tab's cursor lives in `Geex.Session` while it is current (the loop copies
    it out when it leaves); every other tab keeps its own here. `hold` is `{cursor, {w, h}}`: the
    cursor and the pane's size when the mouse last set the scroll (the wheel, a click; ADR-0039).
    While both stay so, the scroll stays where the mouse put it, and the cursor may be out of
    view. `nil` otherwise.
  - A tab is a **source** tab (`view: :source`, the above) or a markdown **preview**
    ([ADR-0043](../../../doc/adr/0043-markdown-preview.md) §1): `%{buffer, view: :preview, scroll,
    from, rows_w}`, its `scroll` counting rendered rows of width `rows_w` and `from` the pane it
    was opened from, with no cursor, hscroll or hold. Only source tabs count as a buffer's views (`show/3`,
    `elsewhere?/2`, `in_other_pane?/3`); `buffers/1` and `drop_buffer/2` count previews too, so
    the loop watches their buffer and a buffer that ends takes its previews with it.

  - A pane's tab bar may be scrolled (roadmap item 18.5): `bar` is `{at, first}`, the bar
    starting at tab `first` while tab `at` is shown. Showing a tab drops it, and the bar follows
    the shown tab again (`bar_first/1`).

  Closing a pane's last tab closes the pane, unless it is the only one.
  """

  @type source_tab :: %{
          buffer: pid(),
          view: :source,
          cursor: {non_neg_integer(), non_neg_integer()},
          scroll: non_neg_integer(),
          hscroll: non_neg_integer(),
          hold:
            {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}}
            | nil
        }
  @type preview_tab :: %{
          buffer: pid(),
          view: :preview,
          scroll: non_neg_integer(),
          from: pos_integer(),
          rows_w: pos_integer() | nil
        }
  @type tab :: source_tab() | preview_tab()
  @type pane :: %{
          required(:tabs) => [tab()],
          required(:at) => non_neg_integer(),
          optional(:bar) => {non_neg_integer(), non_neg_integer()}
        }
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
  @spec tab(pid(), {non_neg_integer(), non_neg_integer()}) :: source_tab()
  def tab(buffer, cursor \\ {0, 0}),
    do: %{buffer: buffer, view: :source, cursor: cursor, scroll: 0, hscroll: 0, hold: nil}

  @doc """
  A new preview tab for `buffer`, opened from pane `from`, at the top. `rows_w` is the width of
  the rows its `scroll` indexes, set when rows are applied to it (`nil` until then).
  """
  @spec preview_tab(pid(), pos_integer()) :: preview_tab()
  def preview_tab(buffer, from),
    do: %{buffer: buffer, view: :preview, scroll: 0, from: from, rows_w: nil}

  @doc """
  Where pane `id`'s tab bar starts: scrolled to tab `first` while the tab shown now stays shown.

      iex> t = Geex.Loop.Panes.new() |> Geex.Loop.Panes.scroll_bar(1, 3)
      iex> Geex.Loop.Panes.bar_first(t.panes[1])
      3
      iex> Geex.Loop.Panes.bar_first(%{t.panes[1] | at: 1})
      nil
  """
  @spec scroll_bar(t(), pos_integer(), non_neg_integer()) :: t()
  def scroll_bar(t, id, first),
    do: update_in(t.panes[id], &Map.put(&1, :bar, {&1.at, first}))

  @doc "The tab pane's bar was scrolled to start at, or `nil` when it follows the shown tab."
  @spec bar_first(pane()) :: non_neg_integer() | nil
  def bar_first(%{bar: {at, first}, at: at}), do: first
  def bar_first(_pane), do: nil

  @doc "Whether `tab` is a preview."
  @spec preview?(tab() | nil) :: boolean()
  def preview?(%{view: :preview}), do: true
  def preview?(_tab), do: false

  defp source_of?(%{view: :preview}, _buffer), do: false
  defp source_of?(%{buffer: buffer}, buffer), do: true
  defp source_of?(_tab, _buffer), do: false

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
  Show `buffer` in the current pane: its source tab there if it has one, else a new tab at the
  end (with `cursor`), even where the pane has the file's preview, so an open lands on text.
  Returns the panes and whether the tab is new.
  """
  @spec show(t(), pid(), {non_neg_integer(), non_neg_integer()}) :: {t(), :new | :existing}
  def show(ps, buffer, cursor \\ {0, 0}) do
    %{tabs: tabs} = pane = ps.panes[ps.pane]

    case Enum.find_index(tabs, &source_of?(&1, buffer)) do
      nil ->
        pane = show_at(%{pane | tabs: tabs ++ [tab(buffer, cursor)]}, length(tabs))
        {put_in(ps.panes[ps.pane], pane), :new}

      i ->
        {put_in(ps.panes[ps.pane], show_at(pane, i)), :existing}
    end
  end

  @doc """
  Add `tab` to pane `id`, after the tab it shows, and show it there; the current pane, and
  whatever it shows, stay as they are (a preview opening beside its source, ADR-0043 §1).
  """
  @spec add_tab(t(), pos_integer(), tab()) :: t()
  def add_tab(ps, id, tab) do
    %{tabs: tabs, at: at} = ps.panes[id]
    at = if tabs == [], do: 0, else: at + 1
    put_in(ps.panes[id], %{tabs: List.insert_at(tabs, at, tab), at: at})
  end

  @doc """
  Split the current pane in two, `:rows` or `:cols`, the new pane after it holding only `tab`.
  Unlike `split/2`, the current pane stays current (a preview opening beside its source).
  """
  @spec split_beside(t(), :rows | :cols, tab()) :: t()
  def split_beside(ps, dir, tab) do
    id = ps.next

    %{
      ps
      | split: replace(ps.split, ps.pane, {dir, {:pane, ps.pane}, {:pane, id}, 0.5}),
        panes: Map.put(ps.panes, id, %{tabs: [tab], at: 0}),
        next: id + 1
    }
  end

  @doc "The pane after `id` in reading order, wrapping (`id` itself when it is the only one)."
  @spec next_pane(t(), pos_integer()) :: pos_integer()
  def next_pane(ps, id) do
    ids = ids(ps)
    i = Enum.find_index(ids, &(&1 == id)) || 0
    Enum.at(ids, rem(i + 1, length(ids)))
  end

  @doc """
  Close tab `i` of pane `id`; the current pane stays current unless it is the one that closes
  (left with no tabs, and not the only pane). The pane shows the tab it showed, or the one before
  when that was the tab closed.
  """
  @spec close_tab_at(t(), pos_integer(), non_neg_integer()) :: t()
  def close_tab_at(ps, id, i) do
    %{tabs: tabs, at: at} = ps.panes[id]

    cond do
      i >= length(tabs) -> ps
      i < at -> put_tabs(ps, id, List.delete_at(tabs, i), at - 1)
      i == at -> put_tabs(ps, id, List.delete_at(tabs, i), max(at - 1, 0))
      true -> put_tabs(ps, id, List.delete_at(tabs, i), at)
    end
  end

  @doc "Every preview tab of `buffer`, as `{pane id, index}`, in reading order."
  @spec previews(t(), pid()) :: [{pos_integer(), non_neg_integer()}]
  def previews(ps, buffer) do
    for id <- ids(ps),
        {t, i} <- Enum.with_index(ps.panes[id].tabs),
        preview?(t) and t.buffer == buffer,
        do: {id, i}
  end

  @doc """
  The pane to show `buffer` in without opening it again: the current pane when it has a source
  tab of it, else the first pane (in reading order) that shows one, else the first that has
  one in another tab; `nil` when no pane has it. A preview doesn't count.

      iex> alias Geex.Loop.Panes
      iex> {a, b} = {:c.pid(0, 1, 0), :c.pid(0, 2, 0)}
      iex> {ps, _} = Panes.show(Panes.new(), a)
      iex> ps = Panes.split(ps, :cols)
      iex> {ps, _} = Panes.show(ps, b)
      iex> ps = Panes.focus(ps, 1)
      iex> {Panes.holding(ps, a), Panes.holding(ps, b), Panes.holding(ps, :c.pid(0, 3, 0))}
      {1, 2, nil}
  """
  @spec holding(t(), pid()) :: pos_integer() | nil
  def holding(ps, buffer) do
    has? = fn id -> Enum.any?(ps.panes[id].tabs, &source_of?(&1, buffer)) end
    shows? = fn id -> (tab = shown(ps, id)) != nil and source_of?(tab, buffer) end

    cond do
      has?.(ps.pane) -> ps.pane
      id = Enum.find(ids(ps), shows?) -> id
      id = Enum.find(ids(ps), has?) -> id
      true -> nil
    end
  end

  @doc "Whether `buffer` has a source tab in any pane."
  @spec source?(t(), pid()) :: boolean()
  def source?(ps, buffer),
    do:
      Enum.any?(ps.panes, fn {_id, %{tabs: tabs}} -> Enum.any?(tabs, &source_of?(&1, buffer)) end)

  @doc "Update tab `i` of pane `id` with `fun`."
  @spec update_tab(t(), pos_integer(), non_neg_integer(), (tab() -> tab())) :: t()
  def update_tab(ps, id, i, fun) do
    case ps.panes[id] do
      %{tabs: tabs} = pane when i < length(tabs) ->
        put_in(ps.panes[id], %{pane | tabs: List.update_at(tabs, i, fun)})

      _ ->
        ps
    end
  end

  @doc "Show the current pane's tab `i` (0-based); out of range changes nothing."
  @spec select(t(), integer()) :: t()
  def select(ps, i) do
    %{tabs: tabs} = pane = ps.panes[ps.pane]
    if i >= 0 and i < length(tabs), do: put_in(ps.panes[ps.pane], show_at(pane, i)), else: ps
  end

  # Pane showing tab `at`: a scrolled tab bar lapses, so it follows the shown tab again (the
  # review of roadmap item 18.5: a scroll kept by `at` alone came back with the same tab).
  defp show_at(pane, at), do: pane |> Map.put(:at, at) |> Map.delete(:bar)

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
          | split: replace(ps.split, ps.pane, {dir, {:pane, ps.pane}, {:pane, id}, 0.5}),
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

  @doc """
  Close pane `id` and its tabs (ADR-0039's pane `×`). The pane that takes its space becomes
  current if it was. The only pane never closes.
  """
  @spec close_pane(t(), pos_integer()) :: t()
  def close_pane(ps, id) when is_map_key(ps.panes, id) do
    if map_size(ps.panes) == 1, do: ps, else: put_tabs(ps, id, [], 0)
  end

  @doc "Whether `buffer` has a source tab in a pane other than `id` (a preview doesn't count)."
  @spec in_other_pane?(t(), pid(), pos_integer()) :: boolean()
  def in_other_pane?(ps, buffer, id) do
    Enum.any?(ps.panes, fn {other, %{tabs: tabs}} ->
      other != id and Enum.any?(tabs, &source_of?(&1, buffer))
    end)
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

  @doc """
  Whether `buffer` has a source tab other than the current tab (in any pane). A preview doesn't
  count: closing a file's last source tab closes the file (ADR-0043 §1).
  """
  @spec elsewhere?(t(), pid()) :: boolean()
  def elsewhere?(ps, buffer) do
    Enum.any?(ps.panes, fn {id, %{tabs: tabs, at: at}} ->
      tabs
      |> Enum.with_index()
      |> Enum.any?(fn {t, i} -> source_of?(t, buffer) and not (id == ps.pane and i == at) end)
    end)
  end

  @doc """
  Set the ratio of the split at `path` (`Geex.Layout.handles/2`): dragging its handle, or `0.5`
  (even) for a double-click on it ([ADR-0039](../../../doc/adr/0039-mouse.md) step 3). A path
  that doesn't name a split changes nothing.
  """
  @spec set_ratio(t(), [:a | :b], float()) :: t()
  def set_ratio(ps, path, ratio), do: %{ps | split: put_ratio(ps.split, path, ratio)}

  defp put_ratio({dir, a, b, _r}, [], ratio), do: {dir, a, b, ratio}
  defp put_ratio({dir, a, b, r}, [:a | path], ratio), do: {dir, put_ratio(a, path, ratio), b, r}
  defp put_ratio({dir, a, b, r}, [:b | path], ratio), do: {dir, a, put_ratio(b, path, ratio), r}
  defp put_ratio(leaf, _path, _ratio), do: leaf

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
  defp leaves({_dir, a, b, _ratio}), do: leaves(a) ++ leaves(b)

  defp replace({:pane, id}, id, with), do: with
  defp replace({:pane, _} = leaf, _id, _with), do: leaf

  defp replace({dir, a, b, r}, id, with),
    do: {dir, replace(a, id, with), replace(b, id, with), r}

  # Remove pane `id`: its sibling takes the split's place. Returns the new split and the pane
  # that inherits the space (the sibling's first pane).
  defp remove({_dir, {:pane, id}, other, _r}, id), do: {other, hd(leaves(other))}
  defp remove({_dir, other, {:pane, id}, _r}, id), do: {other, hd(leaves(other))}

  defp remove({dir, a, b, r}, id) do
    if id in leaves(a) do
      {a2, heir} = remove(a, id)
      {{dir, a2, b, r}, heir}
    else
      {b2, heir} = remove(b, id)
      {{dir, a, b2, r}, heir}
    end
  end
end
