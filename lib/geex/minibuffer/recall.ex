defmodule Geex.Minibuffer.Recall do
  @moduledoc """
  The minibuffer's history ([ADR-0042](../../../doc/adr/0042-shell-commands.md)): what was
  entered, newest first, walked with Up and Down. Pure, apart from `load/1` and `save/2`.

  Every line entered in the `:command` and `:grid` modes is kept, each mode in its own list: a
  `!` command, a verb, a line number. Entering one again moves it to the front. Up from the line
  being typed shows the newest entry, and Down past the newest gives back what was being typed.

  **Kept** in `$XDG_STATE_HOME/geex/history.json` (default `~/.local/state/geex/`), `0600` in a
  `0700` directory: `{"command": [...], "grid": [...]}`, newest first, 500 entries each at
  most. A file that won't read is ignored and replaced on the next save.
  """

  @max 500

  defstruct entries: [], at: nil, draft: ""

  @type t :: %__MODULE__{entries: [String.t()], at: non_neg_integer() | nil, draft: String.t()}

  @doc "A history holding `entries`, newest first."
  @spec new([String.t()]) :: t()
  def new(entries \\ []), do: %__MODULE__{entries: Enum.take(entries, @max)}

  @doc """
  Keep `line` as the newest entry (a blank one isn't kept), and stop walking.

      iex> r = Geex.Minibuffer.Recall.new(["b", "a"]) |> Geex.Minibuffer.Recall.push("a")
      iex> r.entries
      ["a", "b"]
  """
  @spec push(t(), String.t()) :: t()
  def push(%__MODULE__{} = r, line) do
    entries =
      if String.trim(line) == "",
        do: r.entries,
        else: Enum.take([line | List.delete(r.entries, line)], @max)

    %__MODULE__{entries: entries}
  end

  @doc """
  One entry older than the one shown: `{recall, text}`, with `typed` (the input now) kept to come
  back to. At the oldest, it stays there.

      iex> alias Geex.Minibuffer.Recall
      iex> {r, "b"} = Recall.older(Recall.new(["b", "a"]), "draft")
      iex> {r, "a"} = Recall.older(r, "b")
      iex> {r, "a"} = Recall.older(r, "a")
      iex> {r, "b"} = Recall.newer(r)
      iex> {_r, "draft"} = Recall.newer(r)
  """
  @spec older(t(), String.t()) :: {t(), String.t()} | :none
  def older(%__MODULE__{entries: []}, _typed), do: :none

  def older(%__MODULE__{at: nil} = r, typed), do: {%{r | at: 0, draft: typed}, hd(r.entries)}

  def older(%__MODULE__{at: at} = r, _typed) do
    at = min(at + 1, length(r.entries) - 1)
    {%{r | at: at}, Enum.at(r.entries, at)}
  end

  @doc "One entry newer: past the newest, what was being typed. `:none` when not walking."
  @spec newer(t()) :: {t(), String.t()} | :none
  def newer(%__MODULE__{at: nil}), do: :none
  def newer(%__MODULE__{at: 0} = r), do: {%{r | at: nil}, r.draft}
  def newer(%__MODULE__{at: at} = r), do: {%{r | at: at - 1}, Enum.at(r.entries, at - 1)}

  @doc "Stop walking (the minibuffer closed, or the line was edited)."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = r), do: %{r | at: nil, draft: ""}

  @doc "`$XDG_STATE_HOME/geex/history.json`."
  @spec default_file() :: Path.t()
  def default_file, do: Path.join(Geex.state_dir(), "history.json")

  @doc "Each mode's entries from `file`: `%{\"command\" => [...], ...}`; empty when unreadable."
  @spec load(Path.t()) :: %{String.t() => [String.t()]}
  def load(file) do
    with {:ok, body} <- File.read(file),
         {:ok, %{} = map} <- JSON.decode(body) do
      for {mode, list} when is_list(list) <- map,
          into: %{},
          do: {mode, list |> Enum.filter(&is_binary/1) |> Enum.take(@max)}
    else
      _ -> %{}
    end
  end

  @doc "Write each mode's entries to `file`: private, whole or not at all (a temp file renamed)."
  @spec save(Path.t(), %{String.t() => [String.t()]}) :: :ok | {:error, term()}
  def save(file, lists) do
    dir = Path.dirname(file)
    tmp = file <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- IO.binwrite(io, JSON.encode!(lists)),
         :ok <- File.close(io) do
      File.rename(tmp, file)
    else
      error ->
        File.rm(tmp)
        error
    end
  end
end
