defmodule Geex.Ledger.SpoolTest do
  # `Spool.chain/3`'s laws (ADR-0044 §8.2): credit only for an exact chain of hashes, from one
  # session, in time order, from the last known content to the disk; the longest such chain; and
  # nothing when there is none (sacred invariant 6: an actor only from an exact hash match). The
  # examples live in ledger_test.exs and hold_test.exs, beside the buffers that use them.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Geex.Gen
  alias Geex.Ledger.Spool

  defp hex(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  defp lf(text), do: String.replace(text, "\r\n", "\n")

  # The hashes a chain may start from: the synced text, and its LF form if it has a CRLF (how
  # Claude Code reports a CRLF file's prior text).
  defp starts(synced) do
    if String.contains?(synced, "\r\n"), do: [hex(synced), hex(lf(synced))], else: [hex(synced)]
  end

  # Entries over a few contents, so writes link up (and sometimes cycle): each one moves the
  # file from one content to another, sometimes reporting its `before` in LF form, from one of
  # two sessions, sometimes edited in the permission prompt. `tool_use` is the entry's index, so
  # a credit names the entries it used. The first element tells the same writes as text, so a
  # shrunk counterexample reads as contents rather than hashes.
  defp scenario do
    gen all(
          contents <- list_of(Gen.text(max_lines: 3), min_length: 2, max_length: 4),
          writes <-
            list_of(
              tuple({
                frequency([{2, constant(:follow)}, {1, non_negative_integer()}]),
                non_negative_integer(),
                frequency([{4, constant(:exact)}, {1, constant(:lf)}]),
                member_of(["s1", "s2"]),
                frequency([{4, constant(false)}, {1, constant(true)}])
              }),
              max_length: 12
            ),
          synced_at <- non_negative_integer(),
          disk <-
            one_of([
              map(non_negative_integer(), &{:content, &1}),
              map(Gen.text(max_lines: 3), &{:other, &1})
            ])
        ) do
      n = length(contents)
      at = fn i -> Enum.at(contents, rem(i, n)) end

      # `:follow` writes from where the previous write left the file (the synced content, for
      # the first), so chains form often; an index writes from anywhere.
      {written, _last} =
        writes
        |> Enum.with_index()
        |> Enum.map_reduce(synced_at, fn {{from, to, form, session, edited}, i}, previous ->
          from = if from == :follow, do: previous, else: from
          before = if form == :lf, do: lf(at.(from)), else: at.(from)

          entry = %{
            before: hex(before),
            sha256: hex(at.(to)),
            harness: "claude-code",
            session: session,
            turn: "t#{i}",
            tool_use: "u#{i}",
            user_modified: edited
          }

          story =
            "u#{i} #{session}: #{inspect(before)} -> #{inspect(at.(to))}" <>
              if(edited, do: " (edited)", else: "")

          {{story, entry}, to}
        end)

      {story, entries} = Enum.unzip(written)

      disk_text =
        case disk do
          {:content, i} -> at.(i)
          {:other, text} -> text
        end

      synced = at.(synced_at)
      story = ["synced #{inspect(synced)}", "disk #{inspect(disk_text)}" | story]
      {story, entries, synced, disk_text}
    end
  end

  # The naive oracle: the longest exact chain, by dynamic programming over the entries in time
  # order (each entry's longest chain is one more than the longest earlier chain from its session
  # ending at its `before`, or 1 if its `before` is a start). Returns the length, or nil.
  defp longest_chain(entries, synced, disk) do
    starts = starts(synced)
    disk = hex(disk)

    {_ends, best} =
      entries
      |> Enum.reject(&(&1.before == &1.sha256))
      |> Enum.reduce({[], nil}, fn e, {ends, best} ->
        earlier =
          for {len, f} <- ends, f.session == e.session, f.sha256 == e.before, do: len + 1

        candidates = if e.before in starts, do: [1 | earlier], else: earlier

        case candidates do
          [] ->
            {ends, best}

          _ ->
            len = Enum.max(candidates)
            best = if e.sha256 == disk, do: max(best || 0, len), else: best
            {[{len, e} | ends], best}
        end
      end)

    best
  end

  property "chain/3 credits the longest exact chain from one session, and nothing else" do
    check all({_story, entries, synced, disk} <- scenario()) do
      case {Spool.chain(entries, synced, disk), longest_chain(entries, synced, disk)} do
        {:none, nil} ->
          :ok

        {{:ok, {:agent, who}, tool_uses}, best} when is_integer(best) ->
          by_tool_use = Map.new(entries, &{&1.tool_use, &1})
          links = Enum.map(tool_uses, &Map.fetch!(by_tool_use, &1))
          [first | _] = links
          last = List.last(links)

          assert length(links) == best
          # in time order, each write once
          indices = Enum.map(tool_uses, fn "u" <> i -> String.to_integer(i) end)
          assert indices == Enum.sort(Enum.uniq(indices))
          # exact links: last known content -> ... -> disk, none of them a no-op
          assert first.before in starts(synced)
          assert last.sha256 == hex(disk)

          for [a, b] <- Enum.chunk_every(links, 2, 1, :discard),
              do: assert(a.sha256 == b.before)

          refute Enum.any?(links, &(&1.before == &1.sha256))
          # one harness and session, named with the last write's turn and tool call
          assert Enum.uniq_by(links, &{&1.harness, &1.session}) |> length() == 1
          assert {who.harness, who.session} == {first.harness, first.session}
          assert {who.turn, who.tool_use} == {last.turn, last.tool_use}
          assert Map.get(who, :user_modified, false) == Enum.any?(links, & &1.user_modified)

        other ->
          flunk("chain/3 and the oracle disagree: #{inspect(other)}")
      end
    end
  end

  # ADR-0044 §8.2's line: a chain that explains the disk exactly stops explaining it when the disk
  # differs by one byte.
  property "a chain that explains the disk explains nothing once the disk differs by a byte" do
    check all(
            texts <- list_of(Gen.text(max_lines: 3), min_length: 2, max_length: 5),
            session <- member_of(["s1", "s2"]),
            pos <- non_negative_integer(),
            byte <- integer(0..255)
          ) do
      [synced | _] = texts
      disk = List.last(texts)

      entries =
        texts
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.with_index()
        |> Enum.map(fn {[a, b], i} ->
          %{
            before: hex(a),
            sha256: hex(b),
            harness: "claude-code",
            session: session,
            turn: "t#{i}",
            tool_use: "u#{i}"
          }
        end)

      # Every write a no-op, or the texts coming back to where they started, leaves nothing to
      # explain or nothing that differs; those are the oracle property's cases.
      if Enum.any?(entries, &(&1.before != &1.sha256)) and disk != synced do
        assert {:ok, {:agent, %{session: ^session}}, _} = Spool.chain(entries, synced, disk)
      end

      # (unless the changed disk happens to be another write's result: then it is explained)
      off = one_byte_off(disk, pos, byte)

      unless hex(off) in Enum.map(entries, & &1.sha256),
        do: assert(Spool.chain(entries, synced, off) == :none)
    end
  end

  # `text` with one byte changed (or, for the empty text, one byte added).
  defp one_byte_off("", _pos, byte), do: <<byte>>

  defp one_byte_off(text, pos, byte) do
    i = rem(pos, byte_size(text))
    <<head::binary-size(i), old, rest::binary>> = text
    <<head::binary, if(byte == old, do: rem(byte + 1, 256), else: byte), rest::binary>>
  end
end
