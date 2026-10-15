defmodule Geex.Ledger.Spool do
  @moduledoc """
  Credit for agent edits made while a file wasn't open in geex (ADR-0033 decision F).

  The attestation payload (`integrations/captainhook/geex-attest.sh`) appends an attestation no
  running geex took to the file's spool, `<ledger dir>/<key>.spool.jsonl`, but only for a file
  geex keeps a ledger for. Each line is the attestation plus an `at` time: hashes and ids, never
  content.

  When geex reopens the file and finds the disk changed, `chain/3` decides, by exact hashes
  only, whether the spool explains the whole change:

    * **one write:** an entry whose `before` is the last known content (the replayed synced
      text, or that text with each `"\\r\\n"` as `"\\n"`, how Claude Code reports a CRLF file)
      and whose `sha256` is the disk;
    * **a chain:** entries that link exactly, last known → `e1.sha256 = e2.before` → … → disk,
      **all from one harness and session**.

  A chain can start at any entry whose `before` is the last known content, so one session
  changing a line and changing it back doesn't stop another session's later write from being
  credited. A write whose `before` and `sha256` are equal changes nothing and is skipped.

  The whole gap is credited to that session; the actor carries the last write's turn and tool
  call, and the chain's tool calls are listed. If you edited any of those writes in the
  permission prompt, the actor says so (`user_modified: true`, ADR-0034 §8). Anything else (a missing link, two sessions)
  explains nothing, and the gap stays `:external`. A chain through a CRLF file breaks after its
  first link (the disk keeps `"\\r\\n"`, the next `before` doesn't) and stays `:external` too.

  The spool is discarded once a reopen has looked at it: whatever it didn't explain describes
  a state the file has moved past.
  """

  alias Geex.Ledger.Restore

  @type entry :: %{
          before: String.t(),
          sha256: String.t(),
          harness: String.t(),
          session: String.t(),
          turn: String.t() | nil,
          tool_use: String.t() | nil,
          user_modified: boolean()
        }

  @doc "The spool file for a ledger file."
  @spec file(Path.t()) :: Path.t()
  def file(ledger_file), do: String.replace_suffix(ledger_file, ".jsonl", ".spool.jsonl")

  @doc "The spooled entries, oldest first. Lines that aren't a usable attestation are skipped."
  @spec read(Path.t()) :: [entry()]
  def read(ledger_file) do
    case File.read(file(ledger_file)) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&entry/1)

      {:error, _} ->
        []
    end
  end

  @doc "Remove the spool."
  @spec discard(Path.t()) :: :ok
  def discard(ledger_file) do
    File.rm(file(ledger_file))
    :ok
  end

  @doc """
  The session that explains the change from `synced` to `disk`, if the spool shows one:
  `{:ok, actor, tool_uses}`, or `:none`. Pure.

  Entries are walked in time order; when several complete chains exist, the longest wins (the
  first found, among equals).

      iex> e = %{before: Geex.Ledger.Restore.sha256("a"), sha256: Geex.Ledger.Restore.sha256("b"),
      ...>       harness: "claude-code", session: "s1", turn: "t1", tool_use: "u1"}
      iex> Geex.Ledger.Spool.chain([e], "a", "b")
      {:ok, {:agent, %{harness: "claude-code", session: "s1", turn: "t1", tool_use: "u1"}}, ["u1"]}
      iex> Geex.Ledger.Spool.chain([e], "a", "c")
      :none
  """
  @spec chain([entry()], String.t(), String.t()) ::
          {:ok, Geex.Command.Meta.actor(), [String.t()]} | :none
  def chain(entries, synced, disk) do
    starts =
      if String.contains?(synced, "\r\n"),
        do: [Restore.sha256(synced), Restore.sha256(String.replace(synced, "\r\n", "\n"))],
        else: [Restore.sha256(synced)]

    disk = Restore.sha256(disk)

    entries
    |> Enum.reject(&(&1.before == &1.sha256))
    |> Enum.reduce({%{}, nil}, &link(&1, &2, starts, disk))
    |> elem(1)
    |> credit()
  end

  # The longest chain (links newest first) ending at each {content hash, harness, session}, built
  # in time order, so a chain only ever extends with later entries; and the longest complete one.
  # Keeping only the longest per end bounds the work by the number of entries.
  defp link(e, {chains, best}, starts, disk) do
    who = {e.harness, e.session}
    from = Map.get(chains, {e.before, who}, if(e.before in starts, do: []))

    case from && [e | from] do
      nil ->
        {chains, best}

      links ->
        chains = Map.update(chains, {e.sha256, who}, links, &longer(&1, links))
        best = if e.sha256 == disk, do: longer(best, links), else: best
        {chains, best}
    end
  end

  # The existing one unless the new one is longer.
  defp longer(nil, links), do: links
  defp longer(kept, links), do: if(length(links) > length(kept), do: links, else: kept)

  defp credit(nil), do: :none

  defp credit([last | _] = links) do
    edited? = Enum.any?(links, &(Map.get(&1, :user_modified) == true))
    who = Geex.Attest.who(Map.put(last, :user_modified, edited?))
    {:ok, {:agent, who}, links |> Enum.reverse() |> Enum.map(& &1.tool_use)}
  end

  defp entry(line) do
    with {:ok,
          %{"before" => before, "sha256" => sha256, "harness" => harness, "session" => session} =
            m}
         when is_binary(before) and is_binary(sha256) and is_binary(harness) and
                is_binary(session) <-
           JSON.decode(line) do
      [
        %{
          before: before,
          sha256: sha256,
          harness: harness,
          session: session,
          turn: string_or_nil(m["turn"]),
          tool_use: string_or_nil(m["tool_use"]),
          user_modified: m["user_modified"] == true
        }
      ]
    else
      _ -> []
    end
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil
end
