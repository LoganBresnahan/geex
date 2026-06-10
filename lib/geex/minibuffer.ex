defmodule Geex.Minibuffer do
  @moduledoc """
  The minibuffer — the bottom-row command input surface
  ([ADR-0028](../../doc/adr/0028-editor-shell-and-minibuffer.md)).

  A small, **pure** struct the editor loop drives: a `mode`, the `input` string, and a
  grapheme-indexed `cursor`. It is inactive by default; the loop `open/1`s it for a mode,
  routes keystrokes to it (`insert/2`, `backspace/1`, `left/1`, `right/1`) while it is
  `active?/1`, renders `prompt/1 <> value/1` over the status row, and `close/1`s it on
  submit or cancel.

  Modes grow with the command surface — `:command` (typed verbs / a bare line number) and
  `:grid` (coordinate commands, [ADR-0027](../../doc/adr/0027-grid-command-addressing.md) —
  the loop shows the display-column ruler + grid-line overlay while it is open, so the `x`
  the user types is a display column). Incremental search, the palette, and the fuzzy finder
  are the next modes.
  """

  defstruct mode: :inactive, input: "", cursor: 0

  @type mode :: :inactive | :command | :grid
  @type t :: %__MODULE__{mode: mode(), input: String.t(), cursor: non_neg_integer()}

  @doc "A closed (inactive) minibuffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Open the minibuffer in `mode` with an empty input."
  @spec open(mode()) :: t()
  def open(mode \\ :command) when mode != :inactive,
    do: %__MODULE__{mode: mode, input: "", cursor: 0}

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
  def prompt(%__MODULE__{mode: :command}), do: ":"
  def prompt(%__MODULE__{mode: :grid}), do: "grid:"
  def prompt(%__MODULE__{}), do: ""

  @doc "Insert grapheme(s) `g` at the cursor, advancing it past them."
  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{input: input, cursor: cursor} = mb, g) when is_binary(g) do
    {before, rest} = split(input, cursor)
    %{mb | input: before <> g <> rest, cursor: cursor + length(String.graphemes(g))}
  end

  @doc "Delete the grapheme before the cursor (a no-op at the start)."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{cursor: 0} = mb), do: mb

  def backspace(%__MODULE__{input: input, cursor: cursor} = mb) do
    {before, rest} = split(input, cursor)
    kept = before |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
    %{mb | input: kept <> rest, cursor: cursor - 1}
  end

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
