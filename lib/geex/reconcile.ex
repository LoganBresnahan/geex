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
      pid and the new disk text, **echo-suppress by content comparison** — disk text
      equal to the buffer's `EditorState` means this was geex's own `save/1` (or a
      no-op), so ignore it; otherwise synthesize a minimal `%Command{}` (a
      whole-buffer `replace` to the disk content, tagged `actor: :external`),
      dispatch it into *that* buffer's one undo history, and mark the buffer synced
      (it now equals disk). Reconcile only reads disk and dispatches in-memory
      commands — it never writes disk, so it cannot echo or loop. It contains a
      `:exit` from a buffer that died under it, so one buffer's death never crashes
      the reconciler.

    * **The watcher — the GenServer** watches the directory of each open buffer (via
      the `:file_system` library) and turns a `{:file_event, _, {path, _}}` into a
      `reconcile/2` call, resolving the buffer by path through `Geex.Registry`. Watch
      and resolution both key on the lexical (`Path.expand`-ed) path, matching the
      buffer-dedup identity (ADR-0019); symlinked aliases aren't canonicalized. A
      worker that ends (its `:stop`, or a trapped `:EXIT`) frees its directory so the
      next open re-watches it. If the platform watch backend is unavailable
      (`inotify-tools` not installed) the watcher degrades to a logged no-op; the
      core is unaffected. (A burst of `:modified` events for one write reconciles once
      then content-compares to `:ignored`; a non-atomic mid-write read is adopted as
      `:external` and corrected by the settling event — coarse but undoable, never
      silently lost. Close-event filtering / debounce is a later refinement.)

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
  buffer's current `EditorState`:

    * **equal** → `:ignored` (echo-suppression: geex's own save or a no-op);
    * **differ** → synthesize an `:external` whole-buffer `replace` and dispatch it
      into `pid`'s history, returning `{:reconciled, snapshot}`;
    * a dispatch failure → `{:error, reason}`.
  """
  @spec reconcile(pid(), String.t()) ::
          :ignored | {:reconciled, map()} | {:error, term()}
  def reconcile(pid, disk_text) when is_pid(pid) and is_binary(disk_text) do
    snapshot = Buffer.snapshot(pid)

    if snapshot.text == disk_text do
      :ignored
    else
      command = external_replace(snapshot, disk_text)

      case Buffer.dispatch(pid, command) do
        {:ok, _new_snapshot} ->
          # The buffer now equals disk, so it is in sync — clear the dirty flag that
          # dispatch/2 set (it can't know this command's result happens to match disk).
          synced = Buffer.mark_synced(pid)
          Logger.info("geex reconcile: external change to #{snapshot.path || "buffer"}")
          {:reconciled, synced}

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
  defp external_replace(snapshot, disk_text) do
    last_line = max(length(snapshot.lines) - 1, 0)
    last_col = snapshot.lines |> List.last() |> Kernel.||("") |> String.length()

    {:ok, command} =
      Replace.parse(%{
        start_line: 0,
        start_col: 0,
        end_line: last_line,
        end_col: last_col,
        text: disk_text
      })

    Command.put_meta(command, Meta.new(:external))
  end

  # --- watcher GenServer ---

  @impl true
  def init(_opts) do
    # Trap exits: `FileSystem.start_link/1` links the watcher to us, and a backend that
    # dies must not take the reconciler down — handle_info({:EXIT, …}) cleans it up.
    Process.flag(:trap_exit, true)
    {:ok, %{watched: MapSet.new(), watchers: %{}}}
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

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    on_disk_change(Path.expand(path))
    {:noreply, state}
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

  # Read the changed file and reconcile its buffer — but only if that path is an open
  # buffer (the Registry is the source of truth). A transient read error or a deletion
  # (`:enoent`) is skipped rather than reconciled to empty.
  defp on_disk_change(path) do
    with {:ok, pid} <- BufferSupervisor.whereis(path),
         {:ok, disk_text} <- File.read(path) do
      reconcile(pid, disk_text)
    else
      _ -> :ignored
    end
  end

  defp start_watcher(dir, state) do
    case start_filesystem(dir) do
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
