defmodule Geex.Loop.Settings do
  @moduledoc """
  The settings view, `Alt+Y` ([ADR-0040](../../../doc/adr/0040-bare-geex-and-the-catalog.md) §7):
  a full-screen view with four tabs.

    * **Languages** — the catalog's grammars: name, size, and installed, available, an update,
      or installing. Enter (or a click) installs or updates one.
    * **Themes** — the built-in terminal theme, the catalog's and the installed ones. Moving
      the highlight previews a theme live; Enter (or a click) chooses it, installing it first
      if it isn't yet, and geex keeps the choice (`Geex.Settings`). Leaving without choosing
      puts the theme back.
    * **Keys** — every key (`Geex.Loop.KeyHelp`); typing filters it.
    * **General** — the mouse, whether the tree and the edits pane start shown, and where
      geex keeps its settings, packages and caches.

  Esc or `Alt+Y` closes it; Tab, Left and Right move between tabs; Up, Down, `Alt+W` and
  `Alt+S` move the highlight; the mouse clicks tabs and rows and scrolls (ADR-0039).

  This module is the view's state, how a key or a click changes it (`key/3`, `click/4`), which
  rows it shows (`rows/2`) and how it is drawn (`draw/4`). What an action does to the editor
  (an install, a theme, the mouse) is the loop's, from the action `key/3` returns.
  """

  alias Geex.{Catalog, Cell, Installed, Screen, Width}
  alias Geex.Loop.KeyHelp

  @tabs [:languages, :themes, :keys, :general]
  @labels %{languages: "Languages", themes: "Themes", keys: "Keys", general: "General"}

  defstruct tab: :languages, sel: 0, top: 0, query: "", message: nil

  @type tab :: :languages | :themes | :keys | :general
  @type t :: %__MODULE__{
          tab: tab(),
          sel: non_neg_integer(),
          top: non_neg_integer(),
          query: String.t(),
          message: String.t() | nil
        }

  @type action ::
          :none
          | :close
          | :quit
          | {:install, String.t()}
          | {:preview_theme, String.t()}
          | {:choose_theme, String.t()}
          | {:toggle, :mouse | :tree | :edits}

  @doc """
  The view, opened on `tab`; with `select`, that row's name highlighted (the language a file
  just opened needs, say).
  """
  @spec open(tab(), map(), String.t() | nil) :: t()
  def open(tab \\ :languages, ctx \\ %{}, select \\ nil) do
    view = %__MODULE__{tab: tab}
    rows = rows(view, ctx)
    sel = Enum.find_index(rows, &(&1[:name] == select)) || current_row(rows)
    %{view | sel: sel}
  end

  # On Themes, the theme in use; elsewhere, the top.
  defp current_row(rows), do: Enum.find_index(rows, &(&1[:current] == true)) || 0

  ## Rows

  @doc """
  The rows the view's tab shows, each a map with `:name` (what an action names, if anything),
  `:cells` (the columns drawn) and, on Themes, `:current`. `ctx` is what the editor knows:
  `:theme_id`, `:mouse`, `:tree_shown`, `:edits_shown`, `:installing` (a set of names).
  """
  @spec rows(t(), map()) :: [map()]
  def rows(%__MODULE__{tab: :languages}, ctx) do
    installing = Map.get(ctx, :installing, MapSet.new())

    for e <- Catalog.grammars() do
      status =
        cond do
          e["name"] in installing -> "installing…"
          pkg = Installed.grammar(e["name"]) -> package_status(pkg)
          true -> "available"
        end

      %{name: e["name"], cells: [e["display"], kb(e["size"]), status], status: status}
    end
  end

  def rows(%__MODULE__{tab: :themes}, ctx) do
    installing = Map.get(ctx, :installing, MapSet.new())
    current = Map.get(ctx, :theme_id)
    catalog = Map.new(Catalog.themes(), &{&1["name"], &1})
    installed = Map.new(Installed.themes(), &{&1["name"], &1})
    names = Geex.Theme.names() |> Enum.concat(Map.keys(catalog)) |> Enum.uniq()

    for name <- names do
      status =
        cond do
          name == Geex.Theme.Terminal.name() -> "built in: your terminal's colours"
          name in installing -> "installing…"
          pkg = installed[name] -> package_status(pkg)
          true -> "available"
        end

      display = (catalog[name] || installed[name] || %{})["display"]
      label = if is_binary(display), do: display, else: name

      %{
        name: name,
        cells: [label, status, if(name == current, do: "✓ in use", else: "")],
        status: status,
        current: name == current
      }
    end
  end

  def rows(%__MODULE__{tab: :keys, query: query}, _ctx) do
    for {group, keys, what} <- KeyHelp.search(query), do: %{name: nil, cells: [keys, what, group]}
  end

  # What geex starts with, as `settings.json` keeps it (`ctx.saved`): not this session's state,
  # which `mouse`, `Alt+T` and `Alt+L` change without keeping. A tree or edits pane left unset
  # shows when the terminal is wide enough.
  def rows(%__MODULE__{tab: :general}, ctx) do
    saved = Map.get(ctx, :saved, %{})

    at_start = fn key, unset ->
      case saved[key] do
        true -> "on"
        false -> "off"
        _ -> unset
      end
    end

    [
      %{
        name: :mouse,
        cells: ["Mouse", at_start.("mouse", "on"), "at start; Enter turns it over"]
      },
      %{
        name: :tree,
        cells: ["File tree", at_start.("tree", "auto"), "at start (auto: wide terminals)"]
      },
      %{
        name: :edits,
        cells: ["Edits pane", at_start.("edits", "auto"), "at start (auto: wide terminals)"]
      },
      %{name: nil, cells: ["Settings", tilde(Geex.Settings.path()), ""], left_cut: 1},
      %{name: nil, cells: ["Packages", tilde(Installed.root()), ""], left_cut: 1},
      %{
        name: nil,
        cells: ["Compiled grammars", tilde(Geex.Highlight.Grammars.cache_dir() || "(off)"), ""],
        left_cut: 1
      }
    ]
  end

  # `~` for the home directory, so a path fits.
  defp tilde(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end

  defp package_status(pkg),
    do: if(Installed.update?(pkg), do: "update available", else: "installed")

  defp kb(size) when is_integer(size), do: "#{div(size + 1023, 1024)} KB"
  defp kb(_), do: ""

  ## Keys

  @doc """
  A key in the view: the view as it is now, and what the editor should do. `rows` are the
  rows shown, `h` the screen's height (for scrolling).
  """
  @spec key(t(), tuple(), [map()], pos_integer()) :: {t(), action()}
  def key(view, event, rows, h) do
    case event do
      {:key, :esc} ->
        {view, :close}

      {:alt, c} when c in [?y, ?Y] ->
        {view, :close}

      {:ctrl, c} when c in [?x, ?q, ?c] ->
        {view, :quit}

      {:key, :tab} ->
        {switch(view, +1), :none}

      {:key, :right} ->
        {switch(view, +1), :none}

      {:key, :left} ->
        {switch(view, -1), :none}

      {:key, :up} ->
        move(view, -1, rows, h)

      {:key, :down} ->
        move(view, +1, rows, h)

      {:alt, c} when c in [?w, ?W] ->
        move(view, -1, rows, h)

      {:alt, c} when c in [?s, ?S] ->
        move(view, +1, rows, h)

      {:key, :enter} ->
        {view, act(view, rows)}

      {:key, :backspace} when view.tab == :keys ->
        {search(view, String.slice(view.query, 0..-2//1)), :none}

      {:char, g} when view.tab == :keys ->
        {search(view, view.query <> g), :none}

      _ ->
        {view, :none}
    end
  end

  defp switch(view, step) do
    i = Enum.find_index(@tabs, &(&1 == view.tab))
    tab = Enum.at(@tabs, Integer.mod(i + step, length(@tabs)))
    %{view | tab: tab, sel: 0, top: 0, message: nil}
  end

  @doc """
  After a tab change (or rows that moved): highlight the row named `name`, else on Themes the
  theme in use, else the top. The caller passes the new tab's rows.
  """
  @spec reselect(t(), [map()], term()) :: t()
  def reselect(view, rows, name \\ nil) do
    sel =
      (name && Enum.find_index(rows, &(&1[:name] == name))) || current_row(rows)

    %{view | sel: sel, top: 0}
  end

  defp search(view, query), do: %{view | query: query, sel: 0, top: 0}

  defp move(view, step, rows, h) do
    sel = max(min(view.sel + step, length(rows) - 1), 0)
    view = scroll(%{view | sel: sel}, h)
    {view, preview(view, rows)}
  end

  # On Themes, the highlighted theme is shown as you move.
  defp preview(%{tab: :themes, sel: sel}, rows) do
    case Enum.at(rows, sel) do
      %{name: name, status: status} when status not in ["available", "installing…"] ->
        {:preview_theme, name}

      _ ->
        :none
    end
  end

  defp preview(_view, _rows), do: :none

  defp act(%{sel: sel} = view, rows) do
    case {view.tab, Enum.at(rows, sel)} do
      {:languages, %{name: name, status: status}}
      when status in ["available", "update available"] ->
        {:install, name}

      {:themes, %{name: name}} ->
        {:choose_theme, name}

      {:general, %{name: id}} when id in [:mouse, :tree, :edits] ->
        {:toggle, id}

      _ ->
        :none
    end
  end

  # Keep the highlight within the list's rows on screen.
  defp scroll(view, h) do
    n = list_height(h)

    cond do
      view.sel < view.top -> %{view | top: view.sel}
      view.sel >= view.top + n -> %{view | top: view.sel - n + 1}
      true -> view
    end
  end

  @doc "Say `message` on the view's message line."
  @spec say(t(), String.t() | nil) :: t()
  def say(view, message), do: %{view | message: message}

  ## The mouse

  @doc """
  A press at `{x, y}`: a tab (switch to it), or a row (highlight it, and act as Enter does), or
  the wheel (`:up`/`:down`, scroll the highlight). Returns the view and the action.
  """
  @spec mouse(t(), map(), [map()], {pos_integer(), pos_integer()}) :: {t(), action()}
  def mouse(view, %{action: :wheel, button: button}, rows, {_w, h}) when button in [:up, :down] do
    {view, action} = move(view, if(button == :up, do: -3, else: 3), rows, h)
    {view, action}
  end

  def mouse(view, %{action: :press, button: :left, x: x, y: y}, rows, {w, h}) do
    cond do
      y == 0 ->
        case Enum.find(tab_spans(w), fn {_tab, x0, x1} -> x >= x0 and x < x1 end) do
          {tab, _, _} -> {%{view | tab: tab, sel: 0, top: 0, message: nil}, :none}
          nil -> {view, :none}
        end

      y >= 2 and y < 2 + list_height(h) and view.top + y - 2 < length(rows) ->
        view = %{view | sel: view.top + y - 2}
        action = act(view, rows)
        action = if action == :none, do: preview(view, rows), else: action
        {view, action}

      true ->
        {view, :none}
    end
  end

  def mouse(view, _event, _rows, _size), do: {view, :none}

  ## Drawing

  # The rows a list has: the screen less the tabs, the rule, the message and the help line. None
  # on a screen too short for them; then a click lands on no row.
  defp list_height(h), do: max(h - 4, 0)

  # Each tab's label on the top row: `{tab, x0, x1}`.
  defp tab_spans(_w) do
    {spans, _x} =
      Enum.map_reduce(@tabs, 1, fn tab, x ->
        width = Width.string(" #{@labels[tab]} ")
        {{tab, x, x + width}, x + width + 1}
      end)

    spans
  end

  @doc """
  Draw the view over the whole `w` × `h` screen in `palette`'s colours. The highlighted row and
  the current tab use the palette's active-line colour (or its `mark`).
  """
  @spec draw(t(), [map()], Geex.Theme.Palette.t(), {pos_integer(), pos_integer()}) :: Screen.t()
  def draw(view, rows, pal, {w, h}) do
    plain = %Cell{char: " ", fg: pal.fg, bg: pal.bg}
    dim = %Cell{fg: pal.line_number, bg: pal.bg}
    picked = %Cell{fg: pal.fg, bg: pal.active_line_bg, attrs: pal.mark}

    screen = Screen.fill_rect(Screen.new(w, h), 0, 0, w, h, plain)

    screen =
      Enum.reduce(tab_spans(w), screen, fn {tab, x, _}, acc ->
        style =
          if tab == view.tab, do: %Cell{fg: pal.fg, bg: pal.bg, attrs: [:reverse]}, else: dim

        Screen.draw_text(acc, x, 0, " #{@labels[tab]} ", style)
      end)

    rule =
      if view.tab == :keys,
        do: " Search: " <> view.query <> "▏",
        else: String.duplicate("─", w)

    screen = Screen.draw_text(screen, 0, 1, clip(rule, w), dim)
    # Columns as wide as their cells, a path's aside (it is cut to fit instead).
    widths =
      case Enum.reject(rows, & &1[:left_cut]) do
        [] -> column_widths(rows, w)
        sized -> column_widths(sized, w)
      end

    # The highlight stays on screen, even after the terminal shrank.
    %{top: top} = scroll(view, h)

    screen =
      rows
      |> Enum.with_index()
      |> Enum.slice(top, list_height(h))
      |> Enum.with_index(2)
      |> Enum.reduce(screen, fn {{row, i}, y}, acc ->
        style = if i == view.sel, do: picked, else: %Cell{fg: pal.fg, bg: pal.bg}

        line =
          row.cells
          |> fit_left(row[:left_cut], widths, w - 1)
          |> Enum.zip(widths)
          |> Enum.map_join("  ", fn {cell, width} -> pad(cell, width) end)

        acc
        |> Screen.fill_rect(0, y, w, 1, %{style | char: " "})
        |> Screen.draw_text(1, y, clip(line, w - 1), style)
      end)

    screen =
      if view.message,
        do:
          Screen.draw_text(screen, 1, h - 2, clip(view.message, w - 1), %Cell{
            fg: pal.cursor,
            bg: pal.bg
          }),
        else: screen

    Screen.draw_text(screen, 0, h - 1, clip(help(view.tab), w), %Cell{
      fg: pal.fg,
      bg: pal.bg,
      attrs: [:reverse]
    })
    |> Screen.fill_rect(Width.string(clip(help(view.tab), w)), h - 1, w, 1, %Cell{
      char: " ",
      fg: pal.fg,
      bg: pal.bg,
      attrs: [:reverse]
    })
  end

  defp help(:languages), do: " Enter installs or updates · Tab, ←, → tabs · Esc or Alt+Y closes "
  defp help(:themes), do: " ↑ ↓ preview · Enter chooses · Esc puts it back · Tab, ←, → tabs "
  defp help(:keys), do: " type to search · Tab, ←, → tabs · Esc or Alt+Y closes "
  defp help(:general), do: " Enter turns it on or off · Tab, ←, → tabs · Esc or Alt+Y closes "

  # Each column as wide as its widest cell, the last taking what's left.
  defp column_widths([], _w), do: []

  defp column_widths(rows, _w) do
    rows
    |> Enum.map(& &1.cells)
    |> Enum.zip_with(& &1)
    |> Enum.map(fn column -> column |> Enum.map(&Width.string/1) |> Enum.max() end)
  end

  defp pad(text, width), do: text <> String.duplicate(" ", max(width - Width.string(text), 0))

  # A cell that must keep its end (a path's file name): cut from the left, with "…", to what the
  # line leaves it.
  defp fit_left(cells, nil, _widths, _w), do: cells

  defp fit_left(cells, i, widths, w) do
    # What the line leaves the cell: the columns before it, and the separators around it.
    before = widths |> Enum.take(i) |> Enum.sum()
    room = max(w - before - 2 * i, 1)

    List.update_at(cells, i, fn cell ->
      if Width.string(cell) <= room, do: cell, else: "…" <> take_end(cell, room - 1)
    end)
  end

  defp take_end(text, n) do
    text
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.reduce_while({"", 0}, fn g, {acc, used} ->
      gw = Width.string(g)
      if used + gw > n, do: {:halt, {acc, used}}, else: {:cont, {g <> acc, used + gw}}
    end)
    |> elem(0)
  end

  defp clip(text, w) do
    if Width.string(text) <= w, do: text, else: take(text, w)
  end

  defp take(text, w) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, n} ->
      gw = Width.string(g)
      if n + gw > w, do: {:halt, {acc, n}}, else: {:cont, {acc <> g, n + gw}}
    end)
    |> elem(0)
  end
end
