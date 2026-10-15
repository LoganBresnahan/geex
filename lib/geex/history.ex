defmodule Geex.History do
  @moduledoc """
  A buffer's history as a pure value: the document, the one undo history, and everything
  derived from or kept in step with it ([ADR-0033](`e:doc/adr/0033-durable-ledger.md`) §3).

  `Geex.Buffer` holds one of these and applies every transition through the functions here;
  the durable ledger replays a file's recorded transitions through the **same** functions, so
  a restored history is the value the live buffer had. Every function is `value -> value`.

  Fields:

    * `base` — the loaded `EditorState`. Undo replays `base` plus the remaining commands
      (ADR-0031), the §15c replay backbone.
    * `base_blame` — who wrote each line of `base`: all unwritten for a loaded file; for a
      compacted ledger, the blame its checkpoint carries, so undo keeps it (ADR-0033 §6).
    * `editor` — the current `EditorState`.
    * `commands` — the applied commands, **newest first** (O(1) prepend);
      `commands_oldest_first/1` for callers.
    * `redo` — undone commands, newest first: the redo future. A new edit clears it.
    * `blame` — who last wrote each line (`Geex.Blame`): advanced by every applied command,
      rebuilt on undo, relabelled by an attestation.
    * `synced` — the disk text the buffer is in sync with (its baseline). Reconcile compares
      disk against this, not the possibly dirty text.
    * `dirty` — whether the text differs from disk as far as the buffer knows. A forward edit
      is always dirty; undo/redo recompute it against `synced`.
    * `seq` — a **monotonic** change clock, bumped by every transition that can change the
      text. Unlike the command count it never goes backwards on undo, so the highlight
      reactor orders its overlays by it (ADR-0031).
    * `next_group` — the id the next reconcile group gets. `group/3` stamps it, so ids come
      from the history itself and survive a restart through the ledger (ADR-0033 §2).
  """

  alias Geex.{Blame, Dispatch, EditorState}
  alias Geex.Command.Meta

  @enforce_keys [:base, :editor, :synced, :blame]
  defstruct [
    :base,
    :base_blame,
    :editor,
    :synced,
    :blame,
    commands: [],
    redo: [],
    dirty: false,
    seq: 0,
    next_group: 1
  ]

  @type t :: %__MODULE__{
          base: EditorState.t(),
          base_blame: Blame.t(),
          editor: EditorState.t(),
          synced: String.t(),
          blame: Blame.t(),
          commands: [struct()],
          redo: [struct()],
          dirty: boolean(),
          seq: non_neg_integer(),
          next_group: pos_integer()
        }

  @doc """
  A fresh history for a document loaded as `text`: clean, nothing recorded.

      iex> h = Geex.History.new("a\\nb")
      iex> {Geex.History.text(h), h.dirty, h.commands}
      {"a\\nb", false, []}
  """
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text) do
    editor = EditorState.new(text)
    blame = Blame.new(EditorState.lines(editor))
    %__MODULE__{base: editor, base_blame: blame, editor: editor, synced: text, blame: blame}
  end

  @doc """
  A history that starts from a compacted ledger's checkpoint (ADR-0033 §6): `text` with the
  blame it had, the disk text it was synced with, and the next reconcile group id. Nothing
  before it can be undone; who wrote each line is kept.
  """
  @spec from_checkpoint(String.t(), Blame.t(), String.t(), pos_integer()) :: t()
  def from_checkpoint(text, blame, synced, next_group) do
    editor = EditorState.new(text)

    %__MODULE__{
      base: editor,
      base_blame: blame,
      editor: editor,
      synced: synced,
      dirty: text != synced,
      blame: blame,
      next_group: next_group
    }
  end

  @doc "The current text."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{editor: editor}), do: EditorState.text(editor)

  @doc "The applied commands, oldest first."
  @spec commands_oldest_first(t()) :: [struct()]
  def commands_oldest_first(%__MODULE__{commands: commands}), do: Enum.reverse(commands)

  @doc """
  Apply one command and record it. A fresh edit clears the redo future and is always dirty.
  Returns the new history, or the command's error with nothing changed.
  """
  @spec dispatch(t(), struct()) :: {:ok, t()} | {:error, term()}
  def dispatch(%__MODULE__{} = h, command) do
    with {:ok, editor} <- Dispatch.apply_command(command, h.editor) do
      {:ok,
       %{
         h
         | editor: editor,
           commands: [command | h.commands],
           blame: advance(h.blame, h.editor, editor, command),
           redo: [],
           dirty: true,
           seq: h.seq + 1
       }}
    end
  end

  @doc """
  Apply `commands` in order as one atomic group: all of them land, or none do (the first
  error is returned). Each is recorded as its own entry, so undo walks back one at a time.

  `baseline` is the disk text the buffer is now in sync with (reconcile passes the bytes it
  read), or `nil`. With one, `synced` becomes it and `dirty` is recomputed, so a merge that
  keeps your unsaved edits stays dirty, and `commands` may be empty (disk changed to what the
  buffer already holds). Without one, the history is simply marked dirty. An empty group
  keeps the redo future; a non-empty one clears it.

  Commands that carry a reconcile stamp get this history's `next_group` as their group id,
  whatever id they arrived with, so ids are durable and never collide across restarts.
  """
  @spec group(t(), [struct()], String.t() | nil) :: {:ok, t()} | {:error, term()}
  def group(%__MODULE__{} = h, commands, baseline) when is_list(commands) do
    {commands, next_group} = stamp_group(commands, h.next_group)

    applied =
      Enum.reduce_while(commands, {:ok, h.editor, h.blame}, fn command, {:ok, editor, blame} ->
        case Dispatch.apply_command(command, editor) do
          {:ok, next} -> {:cont, {:ok, next, advance(blame, editor, next, command)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, editor, blame} <- applied do
      {synced, dirty} =
        case baseline do
          nil -> {h.synced, true}
          baseline -> {baseline, EditorState.text(editor) != baseline}
        end

      {:ok,
       %{
         h
         | editor: editor,
           blame: blame,
           commands: Enum.reverse(commands) ++ h.commands,
           redo: if(commands == [], do: h.redo, else: []),
           synced: synced,
           dirty: dirty,
           seq: h.seq + 1,
           next_group: next_group
       }}
    end
  end

  @doc """
  Undo the newest command: it moves onto the redo stack, and `base` plus the remaining
  commands are replayed to rebuild the document and its blame (ADR-0031). Returns the new
  history and the undone command, or `{:error, :nothing_to_undo}`.
  """
  @spec undo(t()) :: {:ok, t(), struct()} | {:error, :nothing_to_undo}
  def undo(%__MODULE__{commands: []}), do: {:error, :nothing_to_undo}

  def undo(%__MODULE__{commands: [command | rest]} = h) do
    # These all applied once, so replay can't fail; a (theoretically impossible) failure
    # changes nothing. Blame.replay folds Dispatch.apply_command/2 exactly as
    # Dispatch.replay/2 does, rebuilding the blame alongside.
    case Blame.replay(h.base, Enum.reverse(rest), h.base_blame) do
      {:ok, editor, blame} -> {:ok, revert(h, editor, blame, rest, [command | h.redo]), command}
      {:error, _reason} -> {:error, :nothing_to_undo}
    end
  end

  @doc """
  Redo the newest undone command: re-applied to the current document (which, after the
  matching undo, is the state it was first applied to) and moved back onto the history.
  Returns the new history and the command, `{:error, :nothing_to_redo}`, or its error.
  """
  @spec redo(t()) :: {:ok, t(), struct()} | {:error, term()}
  def redo(%__MODULE__{redo: []}), do: {:error, :nothing_to_redo}

  def redo(%__MODULE__{redo: [command | rest_redo]} = h) do
    with {:ok, editor} <- Dispatch.apply_command(command, h.editor) do
      blame = advance(h.blame, h.editor, editor, command)
      {:ok, revert(h, editor, blame, [command | h.commands], rest_redo), command}
    end
  end

  @doc """
  Relabel every command of reconcile `group` (and the lines they last wrote) with `actor`:
  an attestation took effect (ADR-0032). Replay is unaffected: `meta` never feeds `run/2`.
  """
  @spec attest(t(), pos_integer(), Meta.actor()) :: t()
  def attest(%__MODULE__{} = h, group, actor) do
    commands =
      Enum.map(h.commands, fn command ->
        if in_group?(command, group), do: put_actor(command, actor), else: command
      end)

    %{h | commands: commands, blame: Blame.relabel(h.blame, group, actor)}
  end

  @doc "Disk now holds the current text (a save, or reconcile adopting it): clean."
  @spec sync(t()) :: t()
  def sync(%__MODULE__{} = h), do: %{h | synced: text(h), dirty: false}

  @doc "The reconcile stamp of the newest reconcile group, or `nil` (ADR-0032)."
  @spec newest_group(t()) :: map() | nil
  def newest_group(%__MODULE__{commands: commands}),
    do: Enum.find_value(commands, fn command -> command.meta.reconcile end)

  @doc "Whether every command of reconcile `group` is still the anonymous `:external`."
  @spec unattested?(t(), pos_integer()) :: boolean()
  def unattested?(%__MODULE__{commands: commands}, group) do
    commands
    |> Enum.filter(&in_group?(&1, group))
    |> Enum.all?(&(&1.meta.actor == :external))
  end

  @doc "`command` with its actor replaced."
  @spec put_actor(struct(), Meta.actor()) :: struct()
  def put_actor(command, actor), do: %{command | meta: %{command.meta | actor: actor}}

  # Give a reconcile group's commands this history's next id; a group without a reconcile
  # stamp (a revert, a plain batch) leaves the counter alone.
  defp stamp_group(commands, id) do
    if Enum.any?(commands, &match?(%{meta: %Meta{reconcile: %{}}}, &1)) do
      stamped =
        Enum.map(commands, fn
          %{meta: %Meta{reconcile: %{} = stamp} = meta} = command ->
            %{command | meta: %{meta | reconcile: %{stamp | group: id}}}

          command ->
            command
        end)

      {stamped, id + 1}
    else
      {commands, id}
    end
  end

  defp in_group?(command, group),
    do: match?(%{reconcile: %{group: ^group}}, command.meta)

  # An undo/redo: swap in the rebuilt editor and blame, set the command and redo stacks, bump
  # the change clock (an undo is a forward step on it, though it lowers the command count), and
  # recompute `dirty` against the synced baseline, since an undo can land exactly on it.
  defp revert(h, editor, blame, commands, redo) do
    %{
      h
      | editor: editor,
        blame: blame,
        commands: commands,
        redo: redo,
        dirty: EditorState.text(editor) != h.synced,
        seq: h.seq + 1
    }
  end

  defp advance(blame, before, after_editor, command) do
    Blame.step(
      blame,
      EditorState.lines(before),
      EditorState.lines(after_editor),
      Blame.writer(command)
    )
  end
end
