defmodule Geex.Command.Meta do
  @moduledoc """
  Provenance carried by every command (ADR-0005, mcp-ai-integration.md §7).

  Every `%Command{}` carries a `:meta` field of this shape, set at dispatch by
  whoever submitted the command. It rides *on the value*, so it survives undo
  history, replay, and (later) remote dispatch over External Term Format — no
  side ledger.

    * `actor`       — who authored it: `:human` | `{:llm, model}` |
                      `{:agent, id}` | `{:extension, id}` | `:external`
    * `at`          — when it was dispatched (stamped once, preserved on replay)
    * `prompt_hash` — for LLM-authored commands; `nil` for humans
    * `origin`      — `%{turn_id, seq}` linking a *sequence* of commands to one
                      agent turn (§13 composite provenance); `nil` for ad-hoc input

  `at` is stamped at creation and **preserved** when a recorded command is
  replayed — replay re-runs the same values, it does not re-stamp them. That is
  what makes replay deterministic (§15c).
  """

  defstruct actor: :human, at: nil, prompt_hash: nil, origin: nil

  @type actor ::
          :human
          | {:llm, String.t()}
          | {:agent, term()}
          | {:extension, term()}
          | :external

  @type origin :: nil | %{turn_id: String.t(), seq: non_neg_integer()}

  @type t :: %__MODULE__{
          actor: actor(),
          at: DateTime.t() | nil,
          prompt_hash: String.t() | nil,
          origin: origin()
        }

  @doc """
  Build provenance for `actor`. `:at` defaults to now (override for tests/replay).

      iex> m = Geex.Command.Meta.new(:human)
      iex> m.actor
      :human
  """
  @spec new(actor(), keyword()) :: t()
  def new(actor, opts \\ []) do
    %__MODULE__{
      actor: actor,
      at: Keyword.get(opts, :at) || DateTime.utc_now(),
      prompt_hash: Keyword.get(opts, :prompt_hash),
      origin: Keyword.get(opts, :origin)
    }
  end

  @doc "Provenance for a human edit."
  @spec human(keyword()) :: t()
  def human(opts \\ []), do: new(:human, opts)

  @doc "Provenance for an LLM edit by `model` (e.g. from an MCP tool call)."
  @spec llm(String.t(), keyword()) :: t()
  def llm(model, opts \\ []) when is_binary(model), do: new({:llm, model}, opts)
end
