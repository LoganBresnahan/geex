defmodule Geex.EditorState do
  @moduledoc """
  The recorded, replayable, buffer-scoped state a command runs against (ADR-0014).

  This is the dispatch "world." Today it is `{doc}`; it grows to `{doc, marks, …}`
  as real recorded buffer state appears. A command's pure runner operates on an
  `%EditorState{}` and returns `{:ok, state} | {:error, reason}` — the widening of
  v0.1's `run(command, doc)`.

  What is **not** here, by design:

    * **cursor / selection / scroll** — view-local and ephemeral, they live on
      `Geex.View`. A cursor-relative edit bakes resolved absolute coordinates into
      the command at dispatch, so the recorded state and `replay/2` stay pure
      (ADR-0014 §2).
    * **the clipboard** — a sibling `Geex.Clipboard` subsystem with its own ring
      history (ADR-0015). Two stores, two histories, by design.

  Keeping this struct to exactly "the replay-able buffer state" is what makes
  `Geex.Dispatch.replay/2` a deterministic, no-LLM regression backbone (§15c).
  """

  alias Geex.Buffer.Doc

  defstruct doc: %Doc{}

  @type t :: %__MODULE__{doc: Doc.t()}

  @doc "Build an EditorState from text (one empty line for empty text)."
  @spec new(String.t()) :: t()
  def new(text \\ "") when is_binary(text), do: %__MODULE__{doc: Doc.new(text)}

  @doc "Wrap an existing `Doc`."
  @spec from_doc(Doc.t()) :: t()
  def from_doc(%Doc{} = doc), do: %__MODULE__{doc: doc}

  @doc "The buffer document."
  @spec doc(t()) :: Doc.t()
  def doc(%__MODULE__{doc: doc}), do: doc

  @doc "Render the buffer to a single string."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{doc: doc}), do: Doc.text(doc)

  @doc "The buffer's lines."
  @spec lines(t()) :: [String.t()]
  def lines(%__MODULE__{doc: doc}), do: doc.lines

  @doc "Number of lines in the buffer."
  @spec line_count(t()) :: non_neg_integer()
  def line_count(%__MODULE__{doc: doc}), do: Doc.line_count(doc)

  @doc """
  Thread a `Doc -> {:ok, Doc} | {:error, reason}` operation back into the state.

  This is how an edit command updates the world: it runs a pure `Doc` op and the
  result (ok or error) flows straight out as the command's `run/2` return.

      run cmd, state do
        EditorState.update_doc(state, &Doc.insert(&1, {cmd.line, cmd.col}, cmd.text))
      end
  """
  @spec update_doc(t(), (Doc.t() -> {:ok, Doc.t()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def update_doc(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    case fun.(state.doc) do
      {:ok, %Doc{} = doc} -> {:ok, %{state | doc: doc}}
      {:error, _reason} = error -> error
    end
  end
end
