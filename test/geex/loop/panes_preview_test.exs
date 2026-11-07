defmodule Geex.Loop.PanesPreviewTest do
  # Preview tabs in the pure panes model (ADR-0043 §1), each case one of the review's
  # (doc/research/adr-0043-review.md): a preview isn't one of its buffer's views (F2, F20), an
  # open lands on text (F3), a preview has no cursor (F4), and it opens beside its source without
  # moving focus (F8, F21).
  use ExUnit.Case, async: true

  alias Geex.Loop.Panes

  setup do
    [a, b, c] = for _ <- 1..3, do: spawn(fn -> :ok end)
    %{a: a, b: b, c: c}
  end

  defp open(ps, buf), do: ps |> Panes.show(buf) |> elem(0)

  test "F4: a preview tab has its buffer, a row scroll and the pane it came from, no cursor",
       ctx do
    assert Panes.tab(ctx.a) |> Map.fetch!(:view) == :source
    tab = Panes.preview_tab(ctx.a, 1)
    assert tab == %{buffer: ctx.a, view: :preview, scroll: 0, from: 1}
    assert Panes.preview?(tab)
    refute Panes.preview?(Panes.tab(ctx.a))
  end

  test "add_tab/3 puts a tab after the one a pane shows, shows it, and moves no focus", ctx do
    ps = Panes.new() |> open(ctx.a) |> open(ctx.b) |> Panes.select(0)
    ps = Panes.split_beside(ps, :cols, Panes.tab(ctx.c))
    assert ps.pane == 1
    assert Panes.ids(ps) == [1, 2]
    assert Panes.shown(ps, 2).buffer == ctx.c

    ps2 = Panes.add_tab(ps, 2, Panes.preview_tab(ctx.a, 1))
    assert ps2.pane == 1
    assert Enum.map(ps2.panes[2].tabs, & &1.buffer) == [ctx.c, ctx.a]
    assert Panes.shown(ps2, 2) == Panes.preview_tab(ctx.a, 1)

    # In the current pane, after the shown tab (a, not at the end).
    ps3 = Panes.add_tab(ps, 1, Panes.preview_tab(ctx.a, 1))

    assert Enum.map(ps3.panes[1].tabs, &{&1.buffer, &1.view}) ==
             [{ctx.a, :source}, {ctx.a, :preview}, {ctx.b, :source}]

    assert Panes.current(ps3).view == :preview
  end

  test "split_beside/3 makes a pane after the current one holding the tab, focus unchanged",
       ctx do
    ps = Panes.new() |> open(ctx.a)
    ps = Panes.split_beside(ps, :cols, Panes.preview_tab(ctx.a, 1))
    assert ps.split == {:cols, {:pane, 1}, {:pane, 2}, 0.5}
    assert ps.pane == 1
    assert Panes.current(ps).view == :source
    assert Panes.shown(ps, 2).view == :preview
  end

  test "next_pane/2 is the next pane in reading order, wrapping", ctx do
    ps = Panes.new() |> open(ctx.a)
    assert Panes.next_pane(ps, 1) == 1
    ps = ps |> Panes.split(:cols) |> Panes.split(:rows)
    assert Panes.ids(ps) == [1, 2, 3]
    assert Panes.next_pane(ps, 1) == 2
    assert Panes.next_pane(ps, 3) == 1
  end

  test "close_tab_at/3 closes a pane's tab without changing the current pane", ctx do
    ps = Panes.new() |> open(ctx.a) |> Panes.split_beside(:cols, Panes.tab(ctx.b))
    ps = Panes.add_tab(ps, 2, Panes.preview_tab(ctx.a, 1))
    ps = Panes.close_tab_at(ps, 2, 1)
    assert ps.pane == 1
    assert Enum.map(ps.panes[2].tabs, & &1.buffer) == [ctx.b]
    # Closing it shows the tab it opened after.
    assert Panes.shown(ps, 2).buffer == ctx.b

    # A pane left with none closes; the current one stays current.
    ps = Panes.close_tab_at(ps, 2, 0)
    assert Panes.ids(ps) == [1]
    assert ps.pane == 1
  end

  describe "F2/F20: only source tabs are a buffer's views" do
    test "elsewhere?/2 and in_other_pane?/3 don't count previews", ctx do
      ps = Panes.new() |> open(ctx.a) |> Panes.split_beside(:cols, Panes.preview_tab(ctx.a, 1))
      refute Panes.elsewhere?(ps, ctx.a)
      refute Panes.in_other_pane?(ps, ctx.a, 1)

      ps = Panes.add_tab(ps, 1, Panes.preview_tab(ctx.a, 1))
      refute Panes.elsewhere?(Panes.select(ps, 0), ctx.a)
      assert Panes.source?(ps, ctx.a)
    end

    test "buffers/1 and drop_buffer/2 still include them, so a buffer ending takes its previews",
         ctx do
      ps = Panes.new() |> open(ctx.b) |> Panes.split_beside(:cols, Panes.preview_tab(ctx.a, 1))
      assert MapSet.member?(Panes.buffers(ps), ctx.a)
      assert Panes.previews(ps, ctx.a) == [{2, 0}]
      ps = Panes.drop_buffer(ps, ctx.a)
      assert Panes.ids(ps) == [1]
      assert Panes.previews(ps, ctx.a) == []
    end
  end

  describe "F3: opening the file lands on text" do
    test "show/3 finds the source tab, never a preview", ctx do
      ps = Panes.new() |> open(ctx.a) |> Panes.add_tab(1, Panes.preview_tab(ctx.a, 1))
      assert Panes.current(ps).view == :preview
      {ps, :existing} = Panes.show(ps, ctx.a)
      assert Panes.current(ps).view == :source
    end

    test "in a pane where the file has only a preview, a source tab is added and shown", ctx do
      ps = Panes.new() |> open(ctx.b) |> Panes.split_beside(:cols, Panes.preview_tab(ctx.a, 1))
      ps = Panes.focus(ps, 2)
      {ps, :new} = Panes.show(ps, ctx.a, {4, 0})

      assert Enum.map(ps.panes[2].tabs, &{&1.buffer, &1.view}) ==
               [{ctx.a, :preview}, {ctx.a, :source}]

      assert %{view: :source, cursor: {4, 0}} = Panes.current(ps)
    end
  end

  test "a split from a preview copies the preview", ctx do
    ps = Panes.new() |> open(ctx.a) |> Panes.add_tab(1, Panes.preview_tab(ctx.a, 1))
    ps = Panes.split(ps, :rows)
    assert Panes.current(ps) == Panes.preview_tab(ctx.a, 1)
  end
end
