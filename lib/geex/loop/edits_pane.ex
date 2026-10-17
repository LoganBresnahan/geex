defmodule Geex.Loop.EditsPane do
  @moduledoc """
  The edits pane's content ([ADR-0034](../../../doc/adr/0034-panes-tree-edits-hold.md) §6), as
  values: which entries it lists, and each visible row as text. Pure; `Geex.Loop` paints it.

  Entries, top to bottom: one **disk is newer** row per open buffer that is behind, then the
  `Geex.Edits` rows newest first. Only files under `root` are listed (all of them when `root`
  is `nil`). A row reads `file  who  HH:MM`: the file relative to `root`, who wrote it
  (`claude-code/7ccbf3d1`, the status-line author's form; `you`; or `outside`), and when geex
  learned of it.
  """

  @type entry :: %{
          kind: :behind | :edit,
          path: String.t(),
          who: String.t(),
          time: String.t(),
          row: map() | nil
        }

  @doc """
  The entries for `buffers` (`Geex.Session.buffers/0`) and `rows` (`Geex.Edits.rows/0`).

      iex> at = ~N[2026-10-15 17:21:00]
      iex> rows = [%{path: "/r/lib/a.ex", who: :you, at: at, sha256: nil, tool_use: nil},
      ...>         %{path: "/elsewhere/b.ex", who: :outside, at: at, sha256: "x", tool_use: nil}]
      iex> [e] = Geex.Loop.EditsPane.entries([], rows, "/r")
      iex> {e.kind, e.who, e.time}
      {:edit, "you", "17:21"}
  """
  @spec entries([map()], [map()], String.t() | nil) :: [entry()]
  def entries(buffers, rows, root) do
    behind =
      for %{path: path, behind: %{at: at}} <- buffers, is_binary(path), under?(path, root) do
        %{kind: :behind, path: path, who: "disk is newer", time: hhmm(local(at)), row: nil}
      end

    edits =
      for r <- rows, under?(r.path, root) do
        %{kind: :edit, path: r.path, who: who(r.who), time: hhmm(r.at), row: r}
      end

    behind ++ edits
  end

  @doc """
  The `n` rows to show in a pane `w` columns wide, from entry `start` (by default scrolled so
  entry `sel` is visible): `[{text, entry, selected?}]`. The selected row starts with `▸` when
  `focused?`.

      iex> e = %{kind: :edit, path: "/r/lib/a.ex", who: "you", time: "17:21", row: nil}
      iex> [{text, ^e, true}] = Geex.Loop.EditsPane.lines([e], "/r", 30, 5, 0, true)
      iex> text
      "▸ lib/a.ex  you         17:21"
  """
  @spec lines(
          [entry()],
          String.t() | nil,
          non_neg_integer(),
          non_neg_integer(),
          integer(),
          boolean(),
          non_neg_integer() | nil
        ) ::
          [{String.t(), entry(), boolean()}]
  def lines(entries, root, w, n, sel, focused?, start \\ nil) do
    names = Enum.map(entries, &relative(&1.path, root))
    name_w = names |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) |> min(div(w, 2))
    who_w = entries |> Enum.map(&String.length(&1.who)) |> Enum.max(fn -> 0 end) |> min(36)
    start = start || sel |> Kernel.-(n - 1) |> max(0) |> min(max(length(entries) - n, 0))

    entries
    |> Enum.zip(names)
    |> Enum.with_index()
    |> Enum.slice(start, max(n, 0))
    |> Enum.map(fn {{entry, name}, i} ->
      selected? = i == sel
      marker = if selected? and focused?, do: "▸ ", else: "  "
      left = marker <> fit(name, name_w) <> "  " <> fit(entry.who, who_w)
      pad = max(w - String.length(left) - String.length(entry.time) - 1, 1)
      {left <> String.duplicate(" ", pad) <> entry.time, entry, selected?}
    end)
  end

  @doc "`path` relative to `root` when under it; else `~`-relative, or as is."
  @spec relative(String.t(), String.t() | nil) :: String.t()
  def relative(path, root) do
    cond do
      is_binary(root) and under?(path, root) ->
        Path.relative_to(path, root)

      String.starts_with?(path, System.user_home!() <> "/") ->
        "~/" <> Path.relative_to(path, System.user_home!())

      true ->
        path
    end
  end

  defp under?(_path, nil), do: true
  defp under?(path, root), do: String.starts_with?(path, String.trim_trailing(root, "/") <> "/")

  defp who(:you), do: "you"
  defp who(:outside), do: "outside"

  defp who({:agent, %{harness: harness, session: session} = who}),
    do:
      harness <>
        "/" <>
        String.slice(session, 0, 8) <>
        if(who[:user_modified], do: ", edited by you", else: "")

  # Pad, or cut with an ellipsis, to exactly `w` graphemes.
  defp fit(text, w) do
    if String.length(text) > w,
      do: String.slice(text, 0, max(w - 1, 0)) <> "…",
      else: String.pad_trailing(text, w)
  end

  defp hhmm(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  # A UTC time (the buffer's behind mark) as local wall-clock time.
  defp local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end
end
