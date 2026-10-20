defmodule Geex.Minibuffer do
  @moduledoc """
  The minibuffer — the bottom-row command input surface
  ([ADR-0028](../../doc/adr/0028-editor-shell-and-minibuffer.md)).

  A small, **pure** struct the editor loop drives: a `mode`, the `input` string, and a
  grapheme-indexed `cursor`. It is inactive by default; the loop `open/1`s it for a mode,
  routes keystrokes to it (`insert/2`, `backspace/1`, `left/1`, `right/1`) while it is
  `active?/1`, renders `prompt/1 <> value/1` over the status row, and `close/1`s it on
  submit or cancel.

  Modes grow with the command surface — `:command` (typed verbs / a bare line number), `:grid`
  (coordinate commands, [ADR-0027](../../doc/adr/0027-grid-command-addressing.md) — the loop shows
  the display-column ruler + grid-line overlay while it is open, so the `x` the user types is a
  display column), and `:palette` (the command palette, [ADR-0028](../../doc/adr/0028-editor-shell-and-minibuffer.md)
  §3 — the `input` is a fuzzy filter over `Geex.Command.Catalog` and `sel` is the highlighted
  candidate row), `:buffers` (the open buffers, the same way), and `:files` (the fuzzy file
  finder, `Alt+O` — the input filters the root's files through `Geex.Finder`), `:confirm` (a y/n
  question, before a file operation deletes something or makes a missing directory) and `:ask` (a
  path typed under a question, the tree's `r`; ADR-0019's 2026-10-19 amendment). Both carry their
  question in `ask`, shown as the prompt. Incremental search is the next mode.

  `sel` is the only non-text state: the palette's highlighted-candidate index. Editing the input
  resets it to `0` (the top match) — the loop owns moving it (it knows the candidate count to
  clamp against), the struct just carries and resets it.
  """

  defstruct mode: :inactive, input: "", cursor: 0, sel: 0, ask: nil

  @type mode :: :inactive | :command | :grid | :palette | :buffers | :files | :confirm | :ask
  @type t :: %__MODULE__{
          mode: mode(),
          input: String.t(),
          cursor: non_neg_integer(),
          sel: non_neg_integer(),
          ask: String.t() | nil
        }

  @doc "A closed (inactive) minibuffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Open the minibuffer in `mode`, optionally **pre-filled** with `input` (cursor at its end) —
  the palette uses this to drop into `:command` mode with a verb already typed (e.g. `line `)
  when a picked command still needs an argument.
  """
  @spec open(mode(), String.t()) :: t()
  def open(mode \\ :command, input \\ "") when mode != :inactive and is_binary(input),
    do: %__MODULE__{mode: mode, input: input, cursor: length(String.graphemes(input))}

  @doc """
  Open the minibuffer to ask `question`: `:confirm` (y/n) or `:ask` (a typed answer, pre-filled
  with `input`). The question is the prompt.

      iex> mb = Geex.Minibuffer.ask(:confirm, "delete a.ex? (y/n) ")
      iex> Geex.Minibuffer.prompt(mb)
      "delete a.ex? (y/n) "
  """
  @spec ask(:confirm | :ask, String.t(), String.t()) :: t()
  def ask(mode, question, input \\ "") when mode in [:confirm, :ask] and is_binary(question),
    do: %{open(mode, input) | ask: question}

  @doc "Whether the minibuffer is capturing input."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{mode: :inactive}), do: false
  def active?(%__MODULE__{}), do: true

  @doc "Close the minibuffer (back to inactive)."
  @spec close(t()) :: t()
  def close(%__MODULE__{}), do: %__MODULE__{}

  @doc "The current input string."
  @spec value(t()) :: String.t()
  def value(%__MODULE__{input: input}), do: input

  @doc "The prompt shown before the input, per mode."
  @spec prompt(t()) :: String.t()
  def prompt(%__MODULE__{mode: :command}), do: "geex:"
  def prompt(%__MODULE__{mode: :grid}), do: "grid:"
  def prompt(%__MODULE__{mode: :palette}), do: "palette:"
  def prompt(%__MODULE__{mode: :buffers}), do: "buffer:"
  def prompt(%__MODULE__{mode: :files}), do: "open:"
  def prompt(%__MODULE__{mode: mode, ask: ask}) when mode in [:confirm, :ask], do: ask
  def prompt(%__MODULE__{}), do: ""

  @doc """
  Insert grapheme(s) `g` at the cursor, advancing it past them. Editing the input changes the
  candidate set, so the palette's highlight resets to the top match (`sel: 0`).
  """
  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{input: input, cursor: cursor} = mb, g) when is_binary(g) do
    {before, rest} = split(input, cursor)
    %{mb | input: before <> g <> rest, cursor: cursor + length(String.graphemes(g)), sel: 0}
  end

  @doc "Delete the grapheme before the cursor (a no-op at the start); resets the palette highlight."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{cursor: 0} = mb), do: mb

  def backspace(%__MODULE__{input: input, cursor: cursor} = mb) do
    {before, rest} = split(input, cursor)
    kept = before |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
    %{mb | input: kept <> rest, cursor: cursor - 1, sel: 0}
  end

  @doc "Set the palette's highlighted-candidate index (the loop clamps it to the candidate count)."
  @spec select(t(), non_neg_integer()) :: t()
  def select(%__MODULE__{} = mb, i) when is_integer(i) and i >= 0, do: %{mb | sel: i}

  @doc "Move the cursor one grapheme left (clamped to the start)."
  @spec left(t()) :: t()
  def left(%__MODULE__{cursor: cursor} = mb), do: %{mb | cursor: max(cursor - 1, 0)}

  @doc "Move the cursor one grapheme right (clamped to the input end)."
  @spec right(t()) :: t()
  def right(%__MODULE__{input: input, cursor: cursor} = mb),
    do: %{mb | cursor: min(cursor + 1, length(String.graphemes(input)))}

  defp split(input, cursor) do
    {before, rest} = input |> String.graphemes() |> Enum.split(cursor)
    {Enum.join(before), Enum.join(rest)}
  end
end
