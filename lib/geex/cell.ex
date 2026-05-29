defmodule Geex.Cell do
  @moduledoc """
  A single terminal cell: one grapheme plus its style.

  `:default` for `fg`/`bg` means "use the terminal's default colour" and
  is distinct from any concrete colour — the renderer can skip emitting
  an SGR sequence when both sides are `:default`.

  Colours are kept abstract for now; concrete shapes (`{:ansi, 0..15}`,
  `{:xterm, 0..255}`, `{:rgb, r, g, b}`) land when the renderer learns
  to emit SGR.

  `attrs` is a list of style flags drawn from `t:attr/0`. Equality is
  by-membership at the API layer (`equal?/2`), since `[:bold, :italic]`
  and `[:italic, :bold]` paint identically.
  """

  defstruct char: " ", fg: :default, bg: :default, attrs: []

  @type colour :: :default | {:ansi, 0..15} | {:xterm, 0..255} | {:rgb, 0..255, 0..255, 0..255}
  @type attr :: :bold | :italic | :underline | :reverse | :dim

  @type t :: %__MODULE__{
          char: String.t(),
          fg: colour(),
          bg: colour(),
          attrs: [attr()]
        }

  @doc "The default blank cell — space, default colours, no attributes."
  @spec blank() :: t()
  def blank, do: %__MODULE__{}

  @doc """
  Order-independent equality on `attrs`. Two cells paint the same iff
  char/fg/bg match and their attr sets are equal.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.char == b.char and a.fg == b.fg and a.bg == b.bg and
      MapSet.new(a.attrs) == MapSet.new(b.attrs)
  end
end
