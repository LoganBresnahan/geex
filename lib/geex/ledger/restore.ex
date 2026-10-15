defmodule Geex.Ledger.Restore do
  @moduledoc """
  Rebuild a buffer's `Geex.History` from its ledger lines (ADR-0033 §3, §5). Pure.

  Every entry is folded through the same `Geex.History` transitions the live buffer ran, so the
  result is the value the buffer had. Replay is checked, not assumed: a `sync` or `close` entry
  carries hashes, and the replayed text must match them.

  Where replay can't go on, it stops and says where:

    * an entry that won't decode, or a transition that fails, stops **just before** that entry;
    * a hash that doesn't match stops at the **last verified point** (the previous `sync` or
      `close`, or the `open` entry), since everything after it is suspect.

  The caller gets the history and path at the stopping point, the byte offset to cut the file
  back to, and `clean`: whether the last entry it applied was a `close` (false after a crash).
  """

  alias Geex.History
  alias Geex.Ledger.Codec

  @type result :: %{
          history: History.t(),
          path: String.t(),
          entries: non_neg_integer(),
          valid_bytes: non_neg_integer(),
          stopped: nil | String.t(),
          clean: boolean()
        }

  @doc """
  Fold `lines`, each `{line_without_newline, byte_offset_after_its_newline}`, oldest first.
  The first line is an `open` entry, or a compacted ledger's `checkpoint`; `{:error, reason}`
  when it is neither.
  """
  @spec restore([{String.t(), non_neg_integer()}]) :: {:ok, result()} | {:error, String.t()}
  def restore([{first, first_end} | rest]) do
    case Codec.decode(first) do
      {:ok, {:open, %{path: path, base: base}}} ->
        start(History.new(base), path, first_end, rest)

      {:ok, {:checkpoint, c}} ->
        history = History.from_checkpoint(c.text, c.blame, c.synced, c.next_group)
        start(history, c.path, first_end, rest)

      {:ok, _other} ->
        {:error, "the first entry is not an open or checkpoint entry"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def restore([]), do: {:error, "empty ledger"}

  defp start(history, path, first_end, rest) do
    start = %{
      history: history,
      path: path,
      entries: 1,
      valid_bytes: first_end,
      clean: false
    }

    {:ok, fold(rest, start, start)}
  end

  defp fold([], acc, _verified), do: Map.put(acc, :stopped, nil)

  defp fold([{line, line_end} | rest], acc, verified) do
    with {:ok, entry} <- Codec.decode(line),
         {:ok, history, path, check} <- step(entry, acc.history, acc.path) do
      acc = %{
        acc
        | history: history,
          path: path,
          entries: acc.entries + 1,
          valid_bytes: line_end,
          clean: match?({:close, _}, entry)
      }

      case check do
        :unchecked -> fold(rest, acc, verified)
        :verified -> fold(rest, acc, acc)
        {:mismatch, what} -> Map.put(verified, :stopped, "#{what} hash mismatch")
      end
    else
      {:error, reason} -> Map.put(acc, :stopped, reason)
    end
  end

  defp step({:cmd, command}, h, path), do: ok(History.dispatch(h, command), path)

  defp step({kind, commands, baseline}, h, path) when kind in [:group, :gap] do
    case baseline do
      :none ->
        ok(History.group(h, commands, nil), path)

      :result ->
        ok(with({:ok, h} <- History.group(h, commands, nil), do: {:ok, History.sync(h)}), path)

      text ->
        ok(History.group(h, commands, text), path)
    end
  end

  defp step(:undo, h, path), do: ok(History.undo(h), path)
  defp step(:redo, h, path), do: ok(History.redo(h), path)

  defp step({:attest, group, actor}, h, path),
    do: {:ok, History.attest(h, group, actor), path, :unchecked}

  defp step({:rename, new_path}, h, _path), do: {:ok, h, new_path, :unchecked}

  defp step({:sync, sha256}, h, path) do
    if sha256(History.text(h)) == sha256,
      do: {:ok, History.sync(h), path, :verified},
      else: {:ok, h, path, {:mismatch, "sync"}}
  end

  defp step({:close, %{text_sha256: text, synced_sha256: synced}}, h, path) do
    cond do
      sha256(History.text(h)) != text -> {:ok, h, path, {:mismatch, "close text"}}
      sha256(h.synced) != synced -> {:ok, h, path, {:mismatch, "close synced"}}
      true -> {:ok, h, path, :verified}
    end
  end

  defp step({:open, _}, _h, _path), do: {:error, "a second open entry"}
  defp step({:checkpoint, _}, _h, _path), do: {:error, "a checkpoint after the first line"}

  defp ok({:ok, h}, path), do: {:ok, h, path, :unchecked}
  defp ok({:ok, h, _command}, path), do: {:ok, h, path, :unchecked}
  defp ok({:error, reason}, _path), do: {:error, "replay failed: #{inspect(reason)}"}

  @doc "Lowercase hex sha256, the hash every ledger entry and attestation uses."
  @spec sha256(binary()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
