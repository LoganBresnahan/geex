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
    * `dirty` — whether the text differs from disk as far as the buffer knows: every edit,
      undo and redo recomputes it against `synced`, so typing a space and deleting it leaves
      the buffer clean (roadmap item 18.2).
    * `seq` — a **monotonic** change clock, bumped by every transition that can change the
      text. Unlike the command count it never goes backwards on undo, so the highlight
      reactor orders its overlays by it (ADR-0031).
    * `next_group` — the id the next reconcile group gets. `group/3` stamps it, so ids come
      from the history itself and survive a restart through the ledger (ADR-0033 §2).
    * `next_step` — the undo step id the next group gets (`meta.step`, ADR-0031's 2026-11-12
      amendment). Not written to the ledger: replaying the groups stamps them again.
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
    next_group: 1,
    next_step: 1
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
          next_group: pos_integer(),
          next_step: pos_integer()
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
  Apply one command and record it. A fresh edit clears the redo future; it is dirty unless it
  brought the text back to `synced`.
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
           dirty: differs?(editor, h.synced),
           seq: h.seq + 1,
           # A command replayed from a compacted ledger keeps its group's step; later ids pass it.
           next_step: max(h.next_step, (step_of(command) || 0) + 1)
       }}
    end
  end

  @doc """
  Apply `commands` in order as one atomic group: all of them land, or none do (the first
  error is returned). Each is recorded as its own entry, stamped with one undo step id
  (`meta.step`), so `undo_step/1` and `redo_step/1` move them together (ADR-0031's 2026-11-12
  amendment); `undo/1` and `redo/1` still walk one at a time, as the ledger replays them.

  `baseline` is the disk text the buffer is now in sync with (reconcile passes the bytes it
  read), or `nil`. With one, `synced` becomes it and `dirty` is recomputed, so a merge that
  keeps your unsaved edits stays dirty, and `commands` may be empty (disk changed to what the
  buffer already holds). Without one (a revert, ADR-0033 §7), `synced` stays and `dirty` is
  recomputed against it, so a revert back to the saved text is clean (roadmap item 18.2). An empty group
  keeps the redo future; a non-empty one clears it.

  Commands that carry a reconcile stamp get this history's `next_group` as their group id,
  whatever id they arrived with, so ids are durable and never collide across restarts.

  `keep_steps: true` is the ledger's replay (`Geex.Ledger.Restore`): commands keep the step id
  the ledger recorded, so a restored history is the live one; a group recorded before steps
  existed gets a fresh one.
  """
  @spec group(t(), [struct()], String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def group(%__MODULE__{} = h, commands, baseline, opts \\ []) when is_list(commands) do
    {commands, next_group} = stamp_group(commands, h.next_group)

    {commands, next_step} =
      if opts[:keep_steps],
        do: keep_steps(commands, h.next_step),
        else: stamp_step(commands, h.next_step)

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
          nil -> {h.synced, differs?(editor, h.synced)}
          baseline -> {baseline, differs?(editor, baseline)}
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
           next_group: next_group,
           next_step: next_step
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
  Undo the newest **step**: every command sharing the newest command's `meta.step` (one group,
  ADR-0031's 2026-11-12 amendment), or the newest command alone when it has none. Never half a
  step. Returns the new history and the undone commands in the order they were undone (newest
  first), or `{:error, :nothing_to_undo}`. The same history as that many `undo/1`s, its change
  clock (`seq`) advanced as far, so a ledger that replays them one by one lands on it.

      iex> h = Geex.History.new("ab")
      iex> human = &Geex.Command.put_meta(&1, Geex.Command.Meta.human())
      iex> {:ok, c1} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "x"})
      iex> {:ok, c2} = Geex.Commands.Insert.parse(%{line: 0, col: 0, text: "y"})
      iex> {c1, c2} = {human.(c1), human.(c2)}
      iex> {:ok, h} = Geex.History.group(h, [c1, c2], nil)
      iex> {:ok, h, undone} = Geex.History.undo_step(h)
      iex> {Geex.History.text(h), length(undone)}
      {"ab", 2}
      iex> {:ok, h, redone} = Geex.History.redo_step(h)
      iex> {Geex.History.text(h), length(redone)}
      {"yxab", 2}
  """
  @spec undo_step(t()) :: {:ok, t(), [struct()]} | {:error, :nothing_to_undo}
  def undo_step(%__MODULE__{commands: []}), do: {:error, :nothing_to_undo}

  def undo_step(%__MODULE__{commands: [newest | _] = commands} = h) do
    {taken, rest} = take_step(commands, step_of(newest))

    case Blame.replay(h.base, Enum.reverse(rest), h.base_blame) do
      {:ok, editor, blame} ->
        h = revert(h, editor, blame, rest, Enum.reverse(taken) ++ h.redo)
        {:ok, %{h | seq: h.seq - 1 + length(taken)}, taken}

      {:error, _reason} ->
        {:error, :nothing_to_undo}
    end
  end

  @doc """
  Redo the newest undone **step**: every command on top of the redo stack sharing its
  `meta.step`, re-applied in their order, or the one alone. Returns the new history and the
  redone commands in the order they were applied, `{:error, :nothing_to_redo}`, or the first
  error with nothing changed.
  """
  @spec redo_step(t()) :: {:ok, t(), [struct()]} | {:error, term()}
  def redo_step(%__MODULE__{redo: []}), do: {:error, :nothing_to_redo}

  def redo_step(%__MODULE__{redo: [first | _] = redo} = h) do
    {taken, rest_redo} = take_step(redo, step_of(first))

    applied =
      Enum.reduce_while(taken, {:ok, h.editor, h.blame}, fn command, {:ok, editor, blame} ->
        case Dispatch.apply_command(command, editor) do
          {:ok, next} -> {:cont, {:ok, next, advance(blame, editor, next, command)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, editor, blame} <- applied do
      h = revert(h, editor, blame, Enum.reverse(taken) ++ h.commands, rest_redo)
      {:ok, %{h | seq: h.seq - 1 + length(taken)}, taken}
    end
  end

  # The run of `commands` at the top sharing `step`; a `nil` step is a run of one.
  defp take_step([command | rest], nil), do: {[command], rest}

  defp take_step(commands, step),
    do: Enum.split_while(commands, &(step_of(&1) == step))

  # Every recorded command carries a `Meta` (ADR-0005); one built bare (a test's) has no step.
  defp step_of(%{meta: %Meta{step: step}}), do: step
  defp step_of(_command), do: nil

  @doc """
  Relabel every command of reconcile `group` (and the lines they last wrote) with `actor`:
  an attestation took effect (ADR-0032). That includes the group's undone commands waiting on
  the redo stack, so a redo brings them back credited and the group never ends up half
  attested (BUG-8, found by the history property, ADR-0044). And the group's lines in
  `base_blame`, which a compacted ledger's checkpoint carries for commands it folded in, so the
  blame an undo rebuilds from it keeps them credited (BUG-9). Replay is unaffected: `meta`
  never feeds `run/2`.
  """
  @spec attest(t(), pos_integer(), Meta.actor()) :: t()
  def attest(%__MODULE__{} = h, group, actor) do
    relabel = fn command ->
      if in_group?(command, group), do: put_actor(command, actor), else: command
    end

    %{
      h
      | commands: Enum.map(h.commands, relabel),
        redo: Enum.map(h.redo, relabel),
        blame: Blame.relabel(h.blame, group, actor),
        base_blame: Blame.relabel(h.base_blame, group, actor)
    }
  end

  @doc "Disk now holds the current text (a save, or reconcile adopting it): clean."
  @spec sync(t()) :: t()
  def sync(%__MODULE__{} = h), do: %{h | synced: text(h), dirty: false}

  @doc "The reconcile stamp of the newest applied reconcile group, or `nil` (ADR-0032)."
  @spec newest_group(t()) :: map() | nil
  def newest_group(%__MODULE__{commands: commands}),
    do: Enum.find_value(commands, fn command -> command.meta.reconcile end)

  @doc """
  The reconcile stamps a late attestation may match, in the order to try them (ADR-0032's
  2026-11-09 amendment): the newest **undone** group, whose commands wait on the redo stack, then
  the newest applied group (`newest_group/1`); one entry when they are the same group, none
  when there is no reconcile group. The undone one comes first because it is the newer write:
  everything on the redo stack was applied after everything still applied.

      iex> h = Geex.History.new("a")
      iex> Geex.History.attestable_groups(h)
      []
  """
  @spec attestable_groups(t()) :: [map()]
  def attestable_groups(%__MODULE__{redo: redo} = h) do
    # The redo stack is newest-undone first, so its oldest write first: the newest write is last.
    undone = redo |> Enum.reverse() |> Enum.find_value(fn command -> command.meta.reconcile end)

    [undone, newest_group(h)]
    |> Enum.filter(&match?(%{group: group} when is_integer(group), &1))
    |> Enum.uniq_by(& &1.group)
  end

  @doc """
  Whether every command of reconcile `group`, applied or undone, is still the anonymous
  `:external`.
  """
  @spec unattested?(t(), pos_integer()) :: boolean()
  def unattested?(%__MODULE__{commands: commands, redo: redo}, group) do
    (commands ++ redo)
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

  # A replayed group's recorded step ids, the counter moved past them; a group recorded without
  # one (an older ledger) is stamped as a live one is.
  defp keep_steps(commands, id) do
    case Enum.find_value(commands, &step_of/1) do
      nil -> stamp_step(commands, id)
      step -> {commands, max(id, step + 1)}
    end
  end

  # Give a group's commands one undo step id. An empty group takes none.
  defp stamp_step([], id), do: {[], id}

  defp stamp_step(commands, id) do
    stamped =
      Enum.map(commands, fn
        %{meta: %Meta{} = meta} = command -> %{command | meta: %{meta | step: id}}
        command -> command
      end)

    {stamped, id + 1}
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
        dirty: differs?(editor, h.synced),
        seq: h.seq + 1
    }
  end

  # Whether the editor's text differs from `synced`. The sizes first, which costs no copy: they
  # differ for almost every keystroke, and only equal sizes join the text to compare it.
  defp differs?(editor, synced) do
    size = editor |> EditorState.lines() |> Enum.reduce(-1, &(&2 + byte_size(&1) + 1))
    size != byte_size(synced) or EditorState.text(editor) != synced
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
