defmodule Geex.Loop.Output do
  @moduledoc """
  The output pane's content ([ADR-0042](../../../doc/adr/0042-shell-commands.md)): a shell
  command's output as lines, its state, and where the pane is looking. Pure; the loop feeds it
  the runner's chunks and draws `rows/2`.

  - **Lines** arrive in chunks that can split a line, an escape sequence or a UTF-8 character, so
    a line is cleaned (`Geex.Shell.Text.clean/1`) once its newline arrives. The unfinished last
    line is shown cleaned as it stands. Only the newest `max` lines are kept.
  - **Following.** While the highlight is on the last line, it stays there as lines arrive. Moving
    it up stops that; moving it back to the last line starts it again.
  - **Status:** `:running`, `{:exit, code}`, `:needs_tty` (stopped: it switched to the
    alternate screen), or `:overflow` (stopped: it printed faster than it could be read).
  - **Links** (ADR-0042's 2026-11-23 amendment): each finished line goes once to a resolver off
    the loop (`take_unsent/1`, one batch in flight at a time), which answers where the line
    points if it names a file (`put_links/3`). Lines are numbered from the first ever added, so
    an answer for a line trimmed meanwhile is dropped. Drawing, a click and `Alt+N`
    (`next_link/2`) only look the answers up.
  """

  alias Geex.Shell.Text

  @max 5000

  defstruct cmd: "",
            kind: :show,
            # Newest first, cleaned; `count` of them.
            lines: [],
            count: 0,
            partial: "",
            status: :running,
            started: 0,
            ms: nil,
            sel: 0,
            top: 0,
            follow: true,
            max: @max,
            # A project search's results (ADR-0053 §6): `%{query, mode}`, and `capped` once the
            # first `max` lines came and the rest went unread.
            search: nil,
            capped: false,
            # Links: `dropped` lines trimmed so far (line `i` is number `i + dropped`); `sent` and
            # `answered` how many, counted from the first, went to the resolver and came back;
            # `links` the answers that name a file, by number; `at` the line `Alt+N` (or Enter, or
            # a click) last opened, nil before any.
            # `id` the pane's id, given by the loop: the resolver's answers carry it.
            id: 0,
            dropped: 0,
            sent: 0,
            answered: 0,
            links: %{},
            at: nil

  @type status :: :running | {:exit, integer()} | :needs_tty | :overflow
  @type t :: %__MODULE__{
          cmd: String.t(),
          kind: :show | :pipe,
          lines: [String.t()],
          count: non_neg_integer(),
          partial: binary(),
          status: status(),
          started: integer(),
          ms: non_neg_integer() | nil,
          sel: non_neg_integer(),
          top: non_neg_integer(),
          follow: boolean(),
          max: pos_integer(),
          search: %{query: String.t(), mode: :search_project | :search_all} | nil,
          capped: boolean(),
          id: non_neg_integer(),
          dropped: non_neg_integer(),
          sent: non_neg_integer(),
          answered: non_neg_integer(),
          links: %{non_neg_integer() => link()},
          at: non_neg_integer() | nil
        }

  @typedoc """
  Where a line points, as the resolver found it: the span drawn as a link (`at`, `len`, bytes of
  the line), the file in full and as the line names it, and the line and column (1-based; `col`
  nil when the line names none).
  """
  @type link :: %{
          at: non_neg_integer(),
          len: pos_integer(),
          full: String.t(),
          path: String.t(),
          line: pos_integer(),
          col: pos_integer() | nil
        }

  @doc "A pane for `cmd` (`:show` for `!`, `:pipe` for a `|` whose stderr it shows), started `now` (ms)."
  @spec new(String.t(), :show | :pipe, integer(), keyword()) :: t()
  def new(cmd, kind, now, opts \\ []) do
    %__MODULE__{
      cmd: cmd,
      kind: kind,
      started: now,
      max: Keyword.get(opts, :max, @max),
      search: Keyword.get(opts, :search)
    }
  end

  @doc """
  Add a chunk of raw output.

      iex> o = Geex.Loop.Output.new("ls", :show, 0) |> Geex.Loop.Output.append("a\\nb")
      iex> Geex.Loop.Output.rows(o, 5)
      ["a", "b"]
      iex> o |> Geex.Loop.Output.append("c\\n") |> Geex.Loop.Output.rows(5)
      ["a", "bc"]
  """
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = out, chunk) do
    [partial | done] = (out.partial <> chunk) |> :binary.split("\n", [:global]) |> Enum.reverse()
    out = Enum.reduce(Enum.reverse(done), out, &push(&2, Text.clean(&1)))
    %{out | partial: partial} |> trim() |> follow()
  end

  @doc """
  Add a batch from the runner (`Geex.Shell`): complete `lines`, already cleaned, oldest first,
  and the unfinished line as it stands.

      iex> o = Geex.Loop.Output.new("ls", :show, 0) |> Geex.Loop.Output.add(["a", "b"], "c")
      iex> Geex.Loop.Output.rows(o, 5)
      ["a", "b", "c"]
  """
  @spec add(t(), [String.t()], String.t()) :: t()
  def add(%__MODULE__{} = out, lines, partial) do
    out = Enum.reduce(lines, out, &push(&2, &1))
    %{out | partial: partial} |> trim() |> follow()
  end

  @doc "The command ended with `status` (an exit code, `:needs_tty` or `:overflow`), `now` (ms)."
  @spec finish(t(), {:exit, integer()} | :needs_tty | :overflow, integer()) :: t()
  def finish(%__MODULE__{} = out, status, now) do
    out = if out.partial == "", do: out, else: push(%{out | partial: ""}, Text.clean(out.partial))
    %{out | status: status, ms: max(now - out.started, 0)} |> trim() |> follow()
  end

  @doc "Every line shown, the unfinished one last."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{count: count, partial: ""}), do: count
  def size(%__MODULE__{count: count}), do: count + 1

  @doc "Line `i` (0-based, oldest first), or nil."
  @spec line(t(), integer()) :: String.t() | nil
  def line(%__MODULE__{} = out, i) do
    cond do
      i < 0 or i >= size(out) -> nil
      i == out.count -> Text.clean(out.partial)
      true -> Enum.at(out.lines, out.count - 1 - i)
    end
  end

  @doc "The `n` lines from `top`, oldest first."
  @spec rows(t(), non_neg_integer()) :: [String.t()]
  def rows(%__MODULE__{} = out, n) do
    top = first_row(out)
    for i <- top..(top + n - 1)//1, text = line(out, i), do: text
  end

  @doc "The line `rows/2` starts from."
  @spec first_row(t()) :: non_neg_integer()
  def first_row(%__MODULE__{} = out), do: min(out.top, max(size(out) - 1, 0))

  @doc """
  The display columns line `i`'s link covers, `{from, to}` (`to` excluded), counted from the
  row's start as it is drawn, or nil when the line has none.

      iex> link = %{at: 4, len: 6, full: "/r/a.ex", path: "a.ex", line: 1, col: nil}
      iex> o = Geex.Loop.Output.new("x", :show, 0) |> Geex.Loop.Output.add(["日 a.ex:1 x"], "")
      iex> o |> Geex.Loop.Output.put_links(0, [link]) |> Geex.Loop.Output.link_cols(0)
      {3, 9}
  """
  @spec link_cols(t(), integer()) :: {non_neg_integer(), non_neg_integer()} | nil
  def link_cols(%__MODULE__{} = out, i) do
    with %{at: at, len: len} <- link(out, i),
         text when is_binary(text) <- line(out, i),
         true <- at + len <= byte_size(text) do
      from = Geex.Width.string(binary_part(text, 0, at))
      {from, from + Geex.Width.string(binary_part(text, at, len))}
    else
      _ -> nil
    end
  end

  @doc """
  Move the highlight by `delta` lines (clamped). It follows the output again once on the last
  line.
  """
  @spec move(t(), integer()) :: t()
  def move(%__MODULE__{} = out, delta) do
    last = max(size(out) - 1, 0)
    sel = (out.sel + delta) |> max(0) |> min(last)
    %{out | sel: sel, follow: sel == last}
  end

  @doc "Scroll so the highlight is in a window of `rows` lines; following, to the bottom."
  @spec settle(t(), non_neg_integer()) :: t()
  def settle(%__MODULE__{} = out, rows) do
    rows = max(rows, 1)
    last = max(size(out) - 1, 0)

    top =
      cond do
        out.follow -> last - rows + 1
        out.sel < out.top -> out.sel
        out.sel >= out.top + rows -> out.sel - rows + 1
        true -> out.top
      end

    %{out | top: top |> min(max(size(out) - rows, 0)) |> max(0)}
  end

  @doc """
  The pane's title text: the command, then how long it has run, or how it ended.

      iex> o = Geex.Loop.Output.new("mix test", :show, 0)
      iex> Geex.Loop.Output.title(o, 3_400)
      "! mix test · running 3s"
      iex> Geex.Loop.Output.title(Geex.Loop.Output.finish(o, {:exit, 1}, 1_340), 9_000)
      "! mix test · exit 1 · 1.3s"
  """
  @spec title(t(), integer()) :: String.t()
  def title(%__MODULE__{search: %{query: q, mode: mode}} = out, now) do
    name = if mode == :search_all, do: "search-all", else: "search-project"
    head = "#{name} “#{Text.clean(q)}”"

    case out.status do
      :running -> "#{head} · running #{div(max(now - out.started, 0), 1000)}s"
      {:exit, 1} when out.count == 0 -> "#{head} · no matches · #{seconds(out.ms)}"
      _ when out.capped -> "#{head} · the first #{out.max} lines · #{seconds(out.ms)}"
      {:exit, 0} -> "#{head} · #{lines(size(out))} · #{seconds(out.ms)}"
      {:exit, code} -> "#{head} · exit #{code} · #{seconds(out.ms)}"
      :needs_tty -> "#{head} · stopped"
      :overflow -> "#{head} · stopped: too much output"
    end
  end

  def title(%__MODULE__{} = out, now) do
    sigil = if out.kind == :pipe, do: "|", else: "!"

    case out.status do
      :running -> "#{sigil} #{out.cmd} · running #{div(max(now - out.started, 0), 1000)}s"
      {:exit, code} -> "#{sigil} #{out.cmd} · exit #{code} · #{seconds(out.ms)}"
      :needs_tty -> "#{sigil} #{out.cmd} · stopped"
      :overflow -> "#{sigil} #{out.cmd} · stopped: too much output"
    end
  end

  @doc """
  The finished lines not yet sent to the resolver, and the pane marking them sent:
  `{out, first, lines}`, `first` the number of the first. Nothing while a batch is out (one at a
  time keeps what waits on the resolver bounded by the pane's lines), and never a line already
  trimmed.

      iex> o = Geex.Loop.Output.new("ls", :show, 0) |> Geex.Loop.Output.add(["a", "b"], "c")
      iex> {o, 0, ["a", "b"]} = Geex.Loop.Output.take_unsent(o)
      iex> {_, 2, []} = Geex.Loop.Output.take_unsent(Geex.Loop.Output.add(o, ["c"], ""))
      iex> o |> Geex.Loop.Output.put_links(0, [nil, nil]) |> Geex.Loop.Output.add(["c"], "")
      ...> |> Geex.Loop.Output.take_unsent() |> elem(2)
      ["c"]
  """
  @spec take_unsent(t()) :: {t(), non_neg_integer(), [String.t()]}
  def take_unsent(%__MODULE__{} = out) do
    first = max(out.sent, out.dropped)
    last = out.dropped + out.count

    if pending?(out) or first >= last do
      {out, first, []}
    else
      # The unsent are the newest: `lines` is kept newest first.
      lines = out.lines |> Enum.take(last - first) |> Enum.reverse()
      {%{out | sent: last, answered: max(out.answered, first)}, first, lines}
    end
  end

  @doc "Whether a batch sent to the resolver hasn't been answered yet."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{sent: sent, answered: answered}), do: answered < sent

  @doc """
  The resolver's `answers` for the lines numbered from `first`, in order: a link, or nil for a
  line that names no file. Answers for lines trimmed meanwhile are dropped.
  """
  @spec put_links(t(), non_neg_integer(), [link() | nil]) :: t()
  def put_links(%__MODULE__{} = out, first, answers) do
    links =
      answers
      |> Enum.with_index(first)
      |> Enum.reduce(out.links, fn
        {nil, _n}, acc -> acc
        {_link, n}, acc when n < out.dropped -> acc
        {link, n}, acc -> Map.put(acc, n, link)
      end)

    %{out | links: links, answered: max(out.answered, first + length(answers))}
  end

  @doc "Where line `i` (0-based, oldest first) points, or nil: none, or not answered yet."
  @spec link(t(), integer()) :: link() | nil
  def link(%__MODULE__{} = out, i) when i >= 0, do: Map.get(out.links, i + out.dropped)
  def link(_out, _i), do: nil

  @doc "Whether line `i` has been answered (it names a file or it doesn't)."
  @spec answered?(t(), integer()) :: boolean()
  def answered?(%__MODULE__{} = out, i),
    do: i >= 0 and i < out.count and i + out.dropped < out.answered

  @doc "Whether any line kept points at a file."
  @spec links?(t()) :: boolean()
  def links?(%__MODULE__{links: links}), do: map_size(links) > 0

  @doc """
  The next line that points at a file after `from`'s, wrapping, with whether it wrapped:
  `{i, wrapped?}`, or nil when none does. `from` is the line last opened; before any (nil), the
  highlight's line when the highlight was moved there, else the top. One stop per line (ADR-0053,
  Q13).

      iex> link = %{at: 0, len: 6, full: "/r/a.ex", path: "a.ex", line: 1, col: nil}
      iex> o = Geex.Loop.Output.new("x", :show, 0) |> Geex.Loop.Output.add(["a.ex:1", "-", "a.ex:1"], "")
      iex> o = Geex.Loop.Output.put_links(o, 0, [link, nil, link])
      iex> Geex.Loop.Output.next_link(o, nil)
      {0, false}
      iex> Geex.Loop.Output.next_link(o, 0)
      {2, false}
      iex> Geex.Loop.Output.next_link(o, 2)
      {0, true}
  """
  @spec next_link(t(), non_neg_integer() | nil) :: {non_neg_integer(), boolean()} | nil
  def next_link(%__MODULE__{} = out, at) do
    n = max(size(out), 1)

    from =
      cond do
        at -> at
        out.follow -> -1
        true -> out.sel - 1
      end

    Enum.find_value(1..n//1, fn k ->
      i = Integer.mod(from + k, n)
      if link(out, i), do: {i, i <= from}
    end)
  end

  defp lines(1), do: "1 line"
  defp lines(n), do: "#{n} lines"

  defp seconds(ms) when ms < 10_000, do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  defp seconds(ms), do: "#{div(ms, 1000)}s"

  defp push(out, text), do: %{out | lines: [text | out.lines], count: out.count + 1}

  # Drop the oldest lines past `max`, in one go once a tenth over, so a flood isn't trimmed on
  # every line. The highlight and window keep their lines.
  defp trim(%__MODULE__{count: count, max: max} = out) when count > max + div(max, 10) do
    gone = count - max
    lines = Enum.take(out.lines, max)
    dropped = out.dropped + gone
    links = Map.reject(out.links, fn {n, _} -> n < dropped end)
    at = out.at && if(out.at >= gone, do: out.at - gone)

    %{
      out
      | lines: lines,
        count: max,
        sel: max(out.sel - gone, 0),
        top: max(out.top - gone, 0),
        dropped: dropped,
        links: links,
        at: at
    }
  end

  defp trim(out), do: out

  defp follow(%__MODULE__{follow: true} = out), do: %{out | sel: max(size(out) - 1, 0)}
  defp follow(out), do: out
end
