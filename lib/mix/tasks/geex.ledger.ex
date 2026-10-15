defmodule Mix.Tasks.Geex.Ledger do
  @shortdoc "List, forget or compact geex's per-file history ledgers"
  @moduledoc """
  Maintain the durable ledgers geex keeps for every file you edit in it
  ([ADR-0033](../../../doc/adr/0033-durable-ledger.md) §6), in `~/.local/state/geex/ledger/`
  (`$XDG_STATE_HOME/geex/ledger`).

      mix geex.ledger list
      mix geex.ledger forget PATH --yes
      mix geex.ledger compact PATH [--keep N]

  * `list` — every ledger: the file it belongs to, entries, size, last change, and flags:
    `open` (a running geex has it), `spooled N` (agent edits waiting for the next open),
    `orphan` (its file is gone or moved outside geex).
  * `forget PATH` — delete the ledger for `PATH` (and its spool and set-aside copies), e.g.
    after a secret got into the file's history. Without `--yes` it only says what it would
    delete.
  * `compact PATH` — rewrite the ledger as a checkpoint plus its last `N` commands (default
    1000). Who wrote each line is kept; undo before the checkpoint is not. The rewrite is
    replayed and checked before it replaces the file.

  `PATH` is the edited file's path, or a ledger key from `list` (for an orphan). `--dir DIR`
  points at another ledger directory. `forget` and `compact` refuse while a running geex has
  the file open.
  """
  use Mix.Task

  @default_keep 1000

  @impl true
  def run(args) do
    # Load the app's modules and config without starting it (no terminal, no listener).
    Mix.Task.run("app.config")

    {opts, argv} =
      OptionParser.parse!(args, strict: [dir: :string, keep: :integer, yes: :boolean])

    dir = opts[:dir] || Geex.Ledger.default_dir()

    case argv do
      ["list"] ->
        list(dir)

      ["forget", target] ->
        forget(ledger_file(dir, target), opts[:yes])

      ["compact", target] ->
        compact(ledger_file(dir, target), opts[:keep] || @default_keep)

      _ ->
        Mix.raise("usage: mix geex.ledger list | forget PATH [--yes] | compact PATH [--keep N]")
    end
  end

  defp list(dir) do
    case Geex.Ledger.list(dir) do
      [] ->
        IO.puts("no ledgers in #{dir}")

      ledgers ->
        IO.puts("#{length(ledgers)} ledger(s) in #{dir}\n")

        for l <- ledgers do
          flags =
            [l.open && "open", l.spooled > 0 && "spooled #{l.spooled}", l.orphan && "orphan"]
            |> Enum.filter(& &1)

          IO.puts("#{l.key}  #{l.path || "(no path)"}")

          IO.puts(
            "                  #{l.entries} entries, #{kb(l.bytes)}, changed #{when_(l.modified)}" <>
              if(flags == [], do: "", else: "  [" <> Enum.join(flags, ", ") <> "]")
          )
        end
    end
  end

  defp forget(file, yes?) do
    unless File.exists?(file), do: Mix.raise("no ledger at #{file}")

    if yes? do
      case Geex.Ledger.forget(file) do
        {:ok, removed} -> Enum.each(removed, &IO.puts("removed #{&1}"))
        {:error, reason} -> Mix.raise(refusal(reason))
      end
    else
      IO.puts("would delete #{file} (and its spool and set-aside copies); add --yes to do it")
    end
  end

  defp compact(file, keep) do
    unless File.exists?(file), do: Mix.raise("no ledger at #{file}")

    case Geex.Ledger.compact(file, keep) do
      {:ok, r} ->
        IO.puts(
          "compacted #{file}: #{kb(r.before)} -> #{kb(r.after)}; kept the last #{r.kept} " <>
            "command(s), folded #{r.dropped} into the checkpoint"
        )

        if r.stopped,
          do: IO.puts("note: replay had stopped early (#{r.stopped}); a copy was set aside")

      {:error, reason} ->
        Mix.raise(refusal(reason))
    end
  end

  # A path (expanded) or a 16-hex key from `list`.
  defp ledger_file(dir, target) do
    by_key = Path.join(dir, target <> ".jsonl")

    if Regex.match?(~r/\A[0-9a-f]{16}\z/, target) and File.exists?(by_key),
      do: by_key,
      else: Geex.Ledger.file(dir, Path.expand(target))
  end

  defp refusal({:locked, owner}),
    do: "a running geex has this file open (#{owner}); close it first"

  defp refusal(reason), do: "refused: #{inspect(reason)}"

  defp kb(bytes) when bytes < 1024, do: "#{bytes} B"
  defp kb(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp when_(posix) do
    posix |> DateTime.from_unix!() |> DateTime.to_string() |> String.slice(0, 16)
  end
end
