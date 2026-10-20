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
            max: @max

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
          max: pos_integer()
        }

  @doc "A pane for `cmd` (`:show` for `!`, `:pipe` for a `|` whose stderr it shows), started `now` (ms)."
  @spec new(String.t(), :show | :pipe, integer(), keyword()) :: t()
  def new(cmd, kind, now, opts \\ []),
    do: %__MODULE__{cmd: cmd, kind: kind, started: now, max: Keyword.get(opts, :max, @max)}

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
    top = min(out.top, max(size(out) - 1, 0))
    for i <- top..(top + n - 1)//1, text = line(out, i), do: text
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
  def title(%__MODULE__{} = out, now) do
    sigil = if out.kind == :pipe, do: "|", else: "!"

    case out.status do
      :running -> "#{sigil} #{out.cmd} · running #{div(max(now - out.started, 0), 1000)}s"
      {:exit, code} -> "#{sigil} #{out.cmd} · exit #{code} · #{seconds(out.ms)}"
      :needs_tty -> "#{sigil} #{out.cmd} · stopped"
      :overflow -> "#{sigil} #{out.cmd} · stopped: too much output"
    end
  end

  defp seconds(ms) when ms < 10_000, do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  defp seconds(ms), do: "#{div(ms, 1000)}s"

  defp push(out, text), do: %{out | lines: [text | out.lines], count: out.count + 1}

  # Drop the oldest lines past `max`, in one go once a tenth over, so a flood isn't trimmed on
  # every line. The highlight and window keep their lines.
  defp trim(%__MODULE__{count: count, max: max} = out) when count > max + div(max, 10) do
    gone = count - max
    lines = Enum.take(out.lines, max)
    %{out | lines: lines, count: max, sel: max(out.sel - gone, 0), top: max(out.top - gone, 0)}
  end

  defp trim(out), do: out

  defp follow(%__MODULE__{follow: true} = out), do: %{out | sel: max(size(out) - 1, 0)}
  defp follow(out), do: out
end
