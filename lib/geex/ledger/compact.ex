defmodule Geex.Ledger.Compact do
  @moduledoc """
  Compaction as a rewrite (ADR-0033 §6). Pure.

  Cutting a ledger's old lines off doesn't work: a kept `undo` could refer to a command that
  was cut, and replay would fail. So a compacted ledger is written from the restored history
  value instead:

    1. a `checkpoint`: the text as it was before the last `keep` commands, with the blame it had
       (who wrote each line survives compaction), and the next reconcile group id;
    2. those last `keep` commands, as `cmd` entries, with their final actors (attestations
       already applied);
    3. an entry that puts `synced` where it was (a `sync`, or an empty `group` with the disk text
       when the buffer held unsaved edits);
    4. a `close`, so the new ledger is verified on its first replay.

  Lost on purpose: undo past the checkpoint, the redo stack, and the older commands' own
  records (their times, ids and order). `check/2` confirms the rewrite restores to the same
  text, blame, synced text and group counter before the caller replaces the file.
  """

  alias Geex.{Blame, EditorState, History}
  alias Geex.Ledger.Restore

  @doc "The entries of the compacted ledger for `history` at `path`, keeping `keep` commands."
  @spec entries(History.t(), String.t(), non_neg_integer(), String.t()) :: [tuple()]
  def entries(%History{} = h, path, keep, geex) when keep >= 0 do
    commands = History.commands_oldest_first(h)
    {dropped, kept} = Enum.split(commands, max(length(commands) - keep, 0))
    {:ok, base, base_blame} = Blame.replay(h.base, dropped, h.base_blame)
    text = EditorState.text(base)

    checkpoint =
      {:checkpoint,
       %{
         path: path,
         text: text,
         blame: base_blame,
         synced: text,
         next_group: h.next_group,
         geex: geex
       }}

    synced =
      if History.text(h) == h.synced,
        do: {:sync, Restore.sha256(h.synced)},
        else: {:group, [], h.synced}

    close =
      {:close,
       %{text_sha256: Restore.sha256(History.text(h)), synced_sha256: Restore.sha256(h.synced)}}

    [checkpoint | Enum.map(kept, &{:cmd, &1})] ++ [synced, close]
  end

  @doc """
  Whether `restored` (the compacted ledger, replayed) matches `live`: the same text, blame,
  synced text and next group id, and its commands are the newest of `live`'s.
  """
  @spec check(History.t(), History.t()) :: :ok | {:error, String.t()}
  def check(%History{} = restored, %History{} = live) do
    kept = History.commands_oldest_first(restored)
    newest = live |> History.commands_oldest_first() |> Enum.take(-length(kept))

    cond do
      History.text(restored) != History.text(live) -> {:error, "text differs"}
      restored.blame != live.blame -> {:error, "blame differs"}
      restored.synced != live.synced -> {:error, "synced text differs"}
      restored.next_group != live.next_group -> {:error, "group counter differs"}
      kept != newest -> {:error, "kept commands differ"}
      true -> :ok
    end
  end
end
