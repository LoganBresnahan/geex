defmodule Geex.Reconcile do
  @moduledoc """
  The reconcile floor (ADR-0017): when something writes an open buffer's backing
  file **behind geex's back**, geex diffs the disk against its `EditorState` and
  replays the change as a provenance-tagged `%Command{}` — so undo / replay /
  provenance still apply. The file-watcher is just **another transport producing
  commands**, like the minibuffer or the MCP server (ADR-0003).

  This is **Rung 0**, the always-on floor under every enforcement rung
  ([ADR-0016](../../doc/adr/0016-external-harness-integration.md)): the only thing
  that covers a harness shelling out to a script that writes disk, and the
  best-effort / ungateable harnesses. It works with *any* writer — a harness, a
  human in another terminal, `git checkout`.

  ## Two layers (like `Geex.MCP.Protocol`)

    * **The core — `reconcile/2`** (no watcher, directly testable): given a buffer
      pid and the new disk text, **echo-suppress by baseline comparison** — disk text
      equal to the buffer's `synced` baseline (the content it last loaded / saved /
      adopted) means the file is unchanged from geex's last sync — its own `save/1`, a
      no-op, or unsaved edits sitting on top of an otherwise-unchanged file — so ignore
      it; otherwise synthesize a minimal `%Command{}` (a whole-buffer `replace` to the
      disk content, tagged `actor: :external`), dispatch it into *that* buffer's one undo
      history, and re-baseline the buffer (it now equals disk). Comparing against the
      baseline, not the live (possibly dirty) text, is what keeps an event for an
      *unchanged* file from reverting unsaved edits — and it makes geex's own
      `Geex.Session.rename_file/2` echo-suppress for free (the re-keyed buffer carries its
      baseline). Reconcile only reads disk and dispatches in-memory commands — it never
      writes disk, so it cannot echo or loop. It contains a `:exit` from a buffer that
      died under it, so one buffer's death never crashes the reconciler.

    * **The watcher — the GenServer** watches the directory of each open buffer (via
      the `:file_system` library) and turns a `{:file_event, _, {path, _}}` into a
      `reconcile/2` call, resolving the buffer by path through `Geex.Registry`. Watch
      and resolution both key on the lexical (`Path.expand`-ed) path, matching the
      buffer-dedup identity (ADR-0019); symlinked aliases aren't canonicalized. A
      worker that ends (its `:stop`, or a trapped `:EXIT`) frees its directory so the
      next open re-watches it. If the platform watch backend is unavailable
      (`inotify-tools` not installed) the watcher degrades to a logged no-op; the
      core is unaffected. Events for one path are settled: the file is read once the
      path has been quiet for `settle_ms` (default 50ms, `:settle_ms`
      option / `:reconcile_settle_ms` app env), so a burst for one write reconciles once
      and a non-atomic write is not read half-done. A write that outlasts the quiet
      period is still adopted in pieces, each undoable, never silently lost. The
      change is recorded as **one `replace` per changed hunk** (`Geex.Edit.LineDiff`),
      dispatched as one atomic group stamped with a shared group id and the sha256 of
      the disk bytes read (ADR-0032). geex's *own* writes — a `save/1`, or a `Geex.Session.rename_file/2`
      whose re-keyed buffer carries its baseline along — leave disk equal to that baseline,
      so their events baseline-compare to `:ignored` with no rename-specific handling.)

  ## Honesty (ADR-0012 / ADR-0017)

  Out-of-band edits are tagged `:external`, never fabricated as `{:llm, _}` or
  `:human` — a disk write is a *result* stripped of intent. The reconciled command
  is a state-equivalent diff, so provenance is **honest but coarse**: it records
  *what* changed and *that it was external*, at save-granularity, not keystrokes.
  Surfaced never silent: a reconcile logs, and the `:external` command stands in the
  queryable history. geex-as-observer (disk is truth, geex follows) is the default;
  conflict-aware "file changed, reload?" merge UX (geex-as-primary) is deferred — but
  even an overwrite of unsaved edits is recorded as one `:external` command and is
  therefore **undoable**, never silently lost.

  Reconcile targets a *specific* buffer (the one whose file changed, which may not be
  the active one), so it uses the per-buffer dispatch primitive `Geex.Buffer.dispatch/2`
  that `Geex.Dispatch.run/1` itself wraps — the same gather → apply → scatter → record
  chokepoint, just without run/1's active-buffer resolution.
  """

  use GenServer
  require Logger

  alias Geex.Command.Meta
  alias Geex.Commands.Replace
  alias Geex.{Buffer, BufferSupervisor, Command}
  alias Geex.Edit.{LineDiff, Merge}

  @default_settle_ms 50
  @stale_retries 3

  # --- public API ---

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Begin watching `path`'s directory for out-of-band writes. Idempotent per directory.
  A no-op (returns `:ok`) when the reconciler isn't running (feature-gated off), so
  callers — `Geex.Session.open_file/1` — need no liveness check.
  """
  @spec watch(GenServer.server(), String.t()) :: :ok
  def watch(server \\ __MODULE__, path) when is_binary(path) do
    if alive?(server), do: GenServer.cast(server, {:watch, Path.expand(path)})
    :ok
  end

  @doc """
  The reconcile **core** (directly testable, no watcher). Compares `disk_text` to the
  buffer's **`synced` baseline** — the disk content it is in sync with, *not* its live
  (possibly dirty) text:

    * **equal** → `:ignored` (the file is unchanged from geex's last sync: its own
      `save/1`, a no-op, or unsaved edits sitting on top of an otherwise-unchanged file);
    * **differ** → a genuine external change, recorded as one `:external` group of hunk
      `replace`s (ADR-0032), returning `{:reconciled, snapshot}`:
      * a **clean** buffer adopts `disk_text`;
      * a **dirty** buffer is three-way merged (`Geex.Edit.Merge`: base = `synced`, ours =
        the buffer, theirs = disk). The disk change always lands; your unsaved hunks that
        don't overlap it are kept (the buffer stays dirty); an overlapping one takes the
        disk version, stays one undo away, and the human gets a notice
        (`{:geex_buffer_notice, …}`) saying how many were replaced;
    * a dispatch failure → `{:error, reason}`.

  The hunks are computed from a snapshot and applied with `expect_seq`, so an edit landing
  in between makes the buffer refuse (`:stale`) and reconcile retries on a fresh snapshot.

  Comparing against the baseline (not the live text) is what makes a dirty buffer's unsaved
  edits survive an event for an *unchanged* file — including the destination event from
  geex's own `Geex.Session.rename_file/2`, whose re-keyed buffer carries its baseline along,
  so the move never looks like an external change (no rename-specific suppression needed).
  """
  @spec reconcile(pid(), String.t()) ::
          :ignored | {:reconciled, map()} | {:error, term()}
  def reconcile(pid, disk_text) when is_pid(pid) and is_binary(disk_text),
    do: reconcile(pid, disk_text, @stale_retries)

  defp reconcile(pid, disk_text, retries) do
    snapshot = Buffer.snapshot(pid)

    if snapshot.synced == disk_text do
      :ignored
    else
      {target, conflicts} =
        if snapshot.text == snapshot.synced,
          do: {disk_text, 0},
          else: Merge.merge(snapshot.synced, snapshot.text, disk_text)

      commands = external_commands(snapshot.text, target, snapshot.synced, disk_text)

      opts =
        [baseline: disk_text, expect_seq: snapshot.seq] ++
          if conflicts > 0, do: [notice: conflict_notice(conflicts)], else: []

      case Buffer.dispatch_group(pid, commands, opts) do
        {:ok, new_snapshot} ->
          Logger.info(
            "geex reconcile: external change to #{snapshot.path || "buffer"}" <>
              attributed(new_snapshot, commands) <>
              if(conflicts > 0, do: " (#{conflicts} unsaved hunk(s) took disk)", else: "")
          )

          {:reconciled, new_snapshot}

        {:error, :stale} when retries > 0 ->
          reconcile(pid, disk_text, retries - 1)

        {:error, reason} = error ->
          Logger.warning("geex reconcile: failed to apply external change: #{inspect(reason)}")
          error
      end
    end
  catch
    # The target buffer may die between resolution and the call (it is `:temporary`).
    # A dead buffer is not the watcher's problem — contain the exit so one buffer's
    # death can't crash the reconciler and cascade-kill every linked file-watcher.
    :exit, reason ->
      Logger.warning("geex reconcile: buffer #{inspect(pid)} unavailable (#{inspect(reason)})")
      {:error, {:buffer_down, reason}}
  end

  # A whole-buffer replace: the range spans the entire current buffer, the text is the
  # full disk content. Coarse but always state-equivalent — the lossy diff→command step
  # ADR-0017 flags, isolated here so a finer line-level diff (the ADR-0020 myers work)
  # can replace it without touching the watcher or the echo-suppression.
  @doc """
  The commands that record an out-of-band disk change: one `:external` `replace` per changed
  hunk taking `buffer_text` to `target` (bottom-up, so each stays valid after the ones before
  it), all stamped with one reconcile group (ADR-0032): the sha256 of `baseline` (the synced disk
  bytes the write replaced), of `disk_text` (the bytes read), and, when the baseline holds
  `"\\r\\n"`, of the baseline with each `"\\r\\n"` as `"\\n"` (how Claude Code reports a CRLF
  file). The group id itself is assigned by the buffer's history as the group is recorded.
  If the line diff can't reproduce `target` exactly, one whole-text replace is used. Pure.

  Used by `reconcile/2`, and by a buffer reopening a file that changed while geex was closed
  (ADR-0033).
  """
  @spec external_commands(String.t(), String.t(), String.t(), String.t()) :: [struct()]
  def external_commands(buffer_text, target, baseline, disk_text) do
    meta =
      Meta.new(:external,
        reconcile: %{
          # Assigned by the buffer's history as the group is recorded (`Geex.History.group/3`),
          # so ids are durable across restarts (ADR-0033).
          group: nil,
          before_sha256: sha256(baseline),
          before_sha256_lf: lf_sha256(baseline),
          sha256: sha256(disk_text)
        }
      )

    spans =
      case LineDiff.spans(buffer_text, target) do
        {:ok, spans} -> spans
        :error -> [whole_text_span(buffer_text, target)]
      end

    Enum.map(spans, &replace_command(&1, meta))
  end

  # Name the agent when a waiting attestation was consumed as the group was recorded.
  defp attributed(_snapshot, []), do: ""

  defp attributed(snapshot, _commands) do
    case List.last(snapshot.history).meta.actor do
      {:agent, %{harness: harness, session: session}} -> " (attested: #{harness} session #{session})"
      _ -> ""
    end
  end

  defp conflict_notice(1),
    do: "disk changed: 1 of your unsaved hunks took the disk version (Alt+Z restores yours)"

  defp conflict_notice(n),
    do: "disk changed: #{n} of your unsaved hunks took the disk version (Alt+Z restores yours)"

  # Lowercase hex, 64 chars — the attestation contract's format (what `sha256sum` prints).
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # One left-to-right pass of "\r\n" -> "\n", as Claude Code does it (a lone "\r" stays;
  # "\r\r\n" becomes "\r\n"). Verified live on 2.1.299.
  defp lf_sha256(bytes) do
    if String.contains?(bytes, "\r\n"), do: bytes |> String.replace("\r\n", "\n") |> sha256()
  end

  defp whole_text_span(buffer_text, disk_text) do
    lines = String.split(buffer_text, "\n")
    last = length(lines) - 1
    {{{0, 0}, {last, lines |> List.last() |> String.length()}}, disk_text}
  end

  defp replace_command({{{sl, sc}, {el, ec}}, text}, meta) do
    {:ok, command} =
      Replace.parse(%{start_line: sl, start_col: sc, end_line: el, end_col: ec, text: text})

    Command.put_meta(command, meta)
  end

  # --- watcher GenServer ---

  @impl true
  def init(opts) do
    # Trap exits: `FileSystem.start_link/1` links the watcher to us, and a backend that
    # dies must not take the reconciler down — handle_info({:EXIT, …}) cleans it up.
    Process.flag(:trap_exit, true)

    # `:start_watcher` (dir -> {:ok, pid} | :ignore | {:error, _}) is the backend seam;
    # the default is the real `:file_system` worker. Tests inject a stub so the degrade
    # path doesn't depend on whether this host has inotify-tools installed.
    start_watcher = Keyword.get(opts, :start_watcher, &start_filesystem/1)

    # `:settle_ms` — the per-path quiet period before reading a changed file (0 = read on
    # the event itself). See `handle_info/2` for why it exists.
    settle_ms =
      Keyword.get_lazy(opts, :settle_ms, fn ->
        Application.get_env(:geex, :reconcile_settle_ms, @default_settle_ms)
      end)

    {:ok,
     %{
       watched: MapSet.new(),
       watchers: %{},
       start_watcher: start_watcher,
       settle_ms: settle_ms,
       settling: %{}
     }}
  end

  @impl true
  def handle_cast({:watch, path}, state) do
    dir = Path.dirname(path)

    if MapSet.member?(state.watched, dir) do
      {:noreply, state}
    else
      {:noreply, start_watcher(dir, state)}
    end
  end

  # Write completion (ADR-0032 amendment item 4). A non-atomic write fires several events
  # and can be read half-written; on the primary agent path that would record a half-edit
  # hunk. `file_system` reports both MODIFY and CLOSE_WRITE as `:modified`, so "the write
  # finished" can't be read off the event — instead wait until a path has been quiet for
  # `settle_ms`, then read it once. Each event re-arms the path's timer; a stale timer
  # message is recognized by its ref and dropped.
  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, %{settle_ms: 0} = state) do
    on_disk_change(Path.expand(path))
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    path = Path.expand(path)
    ref = make_ref()
    Process.send_after(self(), {:settled, path, ref}, state.settle_ms)
    {:noreply, %{state | settling: Map.put(state.settling, path, ref)}}
  end

  def handle_info({:settled, path, ref}, state) do
    case state.settling do
      %{^path => ^ref} ->
        on_disk_change(path)
        {:noreply, %{state | settling: Map.delete(state.settling, path)}}

      _superseded ->
        {:noreply, state}
    end
  end

  # A watcher told us it stopped. This is the *authoritative* signal: the `:file_system`
  # worker survives a normal backend (inotifywait) exit — it forwards `:stop` but does
  # NOT exit — so we cannot rely on a following {:EXIT, …}. Drop it here, freeing its
  # directory so the next open re-watches it (else that dir would silently, permanently
  # stop reconciling).
  def handle_info({:file_event, watcher, :stop}, state),
    do: {:noreply, drop_watcher(state, watcher, :stopped)}

  # An abnormal worker death arrives as a linked EXIT (we trap exits).
  def handle_info({:EXIT, pid, reason}, state),
    do: {:noreply, drop_watcher(state, pid, reason)}

  def handle_info(_msg, state), do: {:noreply, state}

  # Forget a watcher and free its directory for re-watching. Harmless for a pid we
  # don't track (e.g. a duplicate :stop then EXIT for the same worker).
  defp drop_watcher(state, watcher, reason) do
    case Map.pop(state.watchers, watcher) do
      {nil, _} ->
        state

      {dir, watchers} ->
        Logger.warning(
          "geex reconcile: watcher for #{dir} ended (#{inspect(reason)}); " <>
            "it will be re-watched on the next open of a file there"
        )

        %{state | watchers: watchers, watched: MapSet.delete(state.watched, dir)}
    end
  end

  # Read the changed file and reconcile its buffer — but only if that path is an open buffer
  # (the Registry is the source of truth). A transient read error or a deletion (`:enoent`) is
  # skipped rather than reconciled to empty. `reconcile/2` itself decides external-vs-echo by
  # comparing disk against the buffer's `synced` baseline, so the watcher needs no per-event
  # bookkeeping — an unchanged file (geex's own save/rename, or a spurious event) compares
  # equal and is ignored without reverting any unsaved edits.
  defp on_disk_change(path) do
    with {:ok, pid} <- BufferSupervisor.whereis(path),
         {:ok, disk_text} <- File.read(path) do
      reconcile(pid, disk_text)
    else
      _ -> :ignored
    end
  end

  defp start_watcher(dir, state) do
    case state.start_watcher.(dir) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)

        %{
          state
          | watched: MapSet.put(state.watched, dir),
            watchers: Map.put(state.watchers, watcher, dir)
        }

      # `:ignore` (backend can't bootstrap — e.g. inotify-tools missing) or `{:error, _}`:
      # degrade to a no-op so out-of-band writes simply aren't auto-reconciled. The
      # reconcile core still works when invoked directly.
      other ->
        Logger.warning(
          "geex reconcile: cannot watch #{dir} (#{inspect(other)}); " <>
            "out-of-band writes there won't be auto-reconciled"
        )

        state
    end
  end

  defp start_filesystem(dir) do
    FileSystem.start_link(dirs: [dir])
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp alive?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp alive?(server) when is_pid(server), do: Process.alive?(server)
end
