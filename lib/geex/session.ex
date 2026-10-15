defmodule Geex.Session do
  @moduledoc """
  Geex-level state holder: the **cross-buffer / global** state and the active-buffer
  pointer (ADR-0014).

  v0.1 state:
    * `:view`       — active `Geex.View` (cursor, selection, scroll, `buffer_pid`).
                      The `buffer_pid` is the active buffer; cursor/selection/scroll
                      are view-local and ephemeral (ADR-0014 §2).
    * `:clipboard`  — placeholder; the clipboard becomes a sibling `Geex.Clipboard`
                      subsystem with its own ring history (ADR-0015).
    * `:minibuffer` — `%{mode, input, cursor}` for command-line entry.
    * `:layout`     — placeholder; meaningful in v0.3 when panes split.
    * `:recent`     — the buffers that have been active, most recent first (ADR-0034:
                      the `buffers` picker, and where `close_active/0` goes next). Each is
                      monitored, and dropped when it ends.
    * `:cursors`    — each inactive buffer's last cursor, restored when it is switched back
                      to (a buffer seen for the first time starts at the top).
    * `:dir` / `:root` — the directory geex was started in (the one named, or the first
                      file's) and its git top level, or `dir` itself outside a repository
                      (ADR-0034 §5). The edits pane lists files under `root`; a relative `open`
                      from a pathless buffer resolves from `dir`. `nil` until `set_start/1`.

  Dispatch lives in `Geex.Dispatch`. The per-buffer `Geex.Buffer` process owns the
  `EditorState` and the one undo history and applies commands via `Geex.Dispatch.run/1`;
  Session holds only this cross-buffer state. `snapshot/0` is the read-only headless
  query surface (§15b): it merges the view-local cursor with the active buffer's
  recorded snapshot. See `doc/adr/0014` and `doc/adr/0015`.
  """

  use GenServer
  require Logger

  alias Geex.{Buffer, BufferSupervisor, View}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Make `pid` (or `nil`) the active buffer the view points at."
  @spec set_active_buffer(pid() | nil) :: :ok
  def set_active_buffer(pid) when is_pid(pid) or is_nil(pid),
    do: GenServer.call(__MODULE__, {:set_active_buffer, pid})

  @doc """
  Set the view-local cursor to `{line, col}` (0-based, `col` grapheme-indexed).
  View-local and ephemeral (ADR-0014 §2) — not a recorded edit, not in history; the
  interactive loop (`Geex.Loop`) drives it as you type and move.
  """
  @spec set_cursor({non_neg_integer(), non_neg_integer()}) :: :ok
  def set_cursor({line, col} = cursor) when is_integer(line) and is_integer(col),
    do: GenServer.call(__MODULE__, {:set_cursor, cursor})

  @doc """
  Open the file at `path` and make it the **active** buffer (ADR-0019).

  Find-or-start: `path` is normalized (`Path.expand/1`) and a buffer registered
  under it is reused if already open (preserving any unsaved in-memory edits), else
  a new buffer is started — loading the file's contents, or a fresh empty buffer if
  the file does not yet exist (created on first save). Returns `{:ok, pid}` or
  `{:error, reason}` (e.g. `{:error, {:load_error, posix}}` for an unreadable file,
  `{:error, :max_children}` past the open-buffer ceiling). Opening is a lifecycle
  *operation*, not a recorded edit (ADR-0003): it never enters a buffer's undo history.

  Dedup is by the *lexical* expanded path, so one file reached via two spellings (a
  symlink or hard link) currently yields two independent buffers. The active buffer
  pid is not monitored: if it dies, the pointer goes stale until the next `open_file`
  (a call into the dead buffer is contained as a `-32603` at the MCP boundary, never a
  Session crash); a buffer is `:temporary`, so a re-open of its path starts fresh.
  """
  @spec open_file(String.t()) :: {:ok, pid()} | {:error, term()}
  def open_file(path) when is_binary(path),
    do: GenServer.call(__MODULE__, {:open_file, path})

  @doc """
  Create a new file at `path` on disk with optional initial `content` (ADR-0019).

  A pure **disk** operation: it does **not** open a buffer (call `open_file/1` to edit
  through geex) and is not a recorded edit. Refuses if `path` already exists — either as
  a file on disk *or* as an open buffer — returning `{:error, :eexist}` (use
  `open_file` + edit + `save_file/0` to modify an existing file). Other failures surface
  the raw posix reason (e.g. `{:error, :enoent}` when the parent directory is missing —
  parents are not created). Returns `{:ok, expanded_path}`.
  """
  @spec create_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_file(path, content \\ "") when is_binary(path) and is_binary(content),
    do: GenServer.call(__MODULE__, {:create_file, path, content})

  @doc """
  Delete `path` from disk and evict any open buffer for it (ADR-0019).

  Removes the file (`File.rm`), then — if a buffer is open for that path — terminates it
  and clears the active pointer if it was active. Discarding a buffer with unsaved
  in-memory edits is reported (the `discarded?` flag), never silent. Refuses with
  `{:error, :enoent}` if the file does not exist on disk (to drop a never-saved buffer
  with no backing file, use `close_file/1`). Not a recorded edit. Returns
  `{:ok, {expanded_path, discarded?}}`.
  """
  @spec delete_file(String.t()) :: {:ok, {String.t(), boolean()}} | {:error, term()}
  def delete_file(path) when is_binary(path),
    do: GenServer.call(__MODULE__, {:delete_file, path})

  @doc """
  Rename / move the file at `from` to `to` on disk, re-keying any open buffer (ADR-0019).

  Renames on disk (`File.rename`), then — if a buffer is open for `from` — re-keys it to
  `to` (`Geex.Buffer.rename/2`): its unsaved edits and undo history are preserved and now
  target the new path, and the active-buffer pid is unchanged (it is the same process). The
  re-keyed buffer carries its `synced` disk baseline along, so the reconcile floor (ADR-0017)
  sees the moved file as unchanged from that baseline and never adopts the moved-but-stale
  on-disk bytes back over those unsaved edits — no rename-specific suppression needed. Refuses
  if `from` and `to` are the same path, or if `to` already exists (on disk or as an open
  buffer) — geex does not clobber or merge. A `from` with neither a file on disk nor an open
  buffer surfaces `{:error, :enoent}`; but a buffer opened on a not-yet-saved path is re-keyed
  in memory (a later `save_file` writes it to `to`). Not a recorded edit. Returns
  `{:ok, {from_expanded, to_expanded}}`.
  """
  @spec rename_file(String.t(), String.t()) :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def rename_file(from, to) when is_binary(from) and is_binary(to),
    do: GenServer.call(__MODULE__, {:rename_file, from, to})

  @doc """
  Close an open buffer, freeing it — the file on disk is left untouched (ADR-0019).

  With a `path`, closes the buffer open for it; with `nil`, closes the **active** buffer.
  Terminates the buffer process and clears the active pointer if it was active. Discarding
  unsaved in-memory edits is reported (`discarded?`), never silent — call `save_file/0`
  first to keep them. Returns `{:error, :no_such_buffer}` if no matching buffer is open.
  Not a recorded edit; the backing file is **not** deleted (that is `delete_file/1`).
  Returns `{:ok, {label, discarded?}}` where `label` is the buffer's path (or
  `"active buffer"` for a pathless scratch buffer).
  """
  @spec close_file(String.t() | nil) :: {:ok, {String.t(), boolean()}} | {:error, :no_such_buffer}
  def close_file(path \\ nil) when is_binary(path) or is_nil(path),
    do: GenServer.call(__MODULE__, {:close_file, path})

  @doc """
  The open buffers that have been active, most recent first (the active one leads):
  `[%{pid, path, dirty, behind}]`, `path` `nil` for a scratch buffer (ADR-0034). A buffer that
  died is left out.
  """
  @spec buffers() :: [
          %{pid: pid(), path: String.t() | nil, dirty: boolean(), behind: map() | nil}
        ]
  def buffers, do: GenServer.call(__MODULE__, :buffers)

  @doc """
  Close the active buffer and switch to the one before it, or to a new empty scratch buffer
  when none is left (ADR-0034). Refuses a buffer with unsaved edits (`{:error, :dirty}`):
  save them, or undo them, first. Returns `{:ok, label}` (the closed buffer's path, or
  `"[scratch]"`), `{:error, :dirty}`, or `{:error, :no_active_buffer}`. Not
  `close_file/1`: that one (the MCP tool's) discards and leaves no buffer active.
  """
  @spec close_active() :: {:ok, String.t()} | {:error, :dirty | :no_active_buffer}
  def close_active, do: GenServer.call(__MODULE__, :close_active)

  @doc """
  Record where geex was started (ADR-0034 §5): `path` is the directory named, or a file (its
  directory is used). Sets `dir`, and `root` = `git -C dir rev-parse --show-toplevel`, or `dir`
  outside a repository. Returns `%{dir, root}`.
  """
  @spec set_start(String.t()) :: %{dir: String.t(), root: String.t()}
  def set_start(path) when is_binary(path) do
    full = Path.expand(path)
    dir = if File.dir?(full), do: full, else: Path.dirname(full)
    GenServer.call(__MODULE__, {:set_start, %{dir: dir, root: git_root(dir) || dir}})
  end

  @doc "Where geex was started: `%{dir, root}`, each `nil` before `set_start/1`."
  @spec start() :: %{dir: String.t() | nil, root: String.t() | nil}
  def start, do: GenServer.call(__MODULE__, :start)

  @doc "The active buffer pid, or `:error` if none is active."
  @spec active_buffer() :: {:ok, pid()} | :error
  def active_buffer, do: GenServer.call(__MODULE__, :active_buffer)

  @doc """
  Subscribe `pid` (default: caller) to **view** changes. When the active buffer
  pointer moves (a file opened, switched, or closed) the subscriber receives:

      {:geex_active_buffer, pid | nil}

  so the editor loop (`Geex.Loop`) can re-attach its render to the new buffer. When
  the **cursor** is set by someone *other than the subscriber* (an agent's `line`
  view action, ADR-0030) it receives:

      {:geex_cursor, {line, col}}

  so the move is visible on screen without waiting for an unrelated event (the
  setter itself is deliberately not echoed — the loop already repaints its own
  moves). Returns the current active buffer (`pid` or `nil`) so the subscriber can
  attach immediately. The subscriber is monitored and dropped on exit.
  """
  @spec subscribe(pid()) :: pid() | nil
  def subscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc """
  Read-only snapshot for headless inspection (§15b): the active buffer's recorded
  state plus the view-local `:cursor`. `{:error, :no_active_buffer}` if none active.
  """
  @spec snapshot() :: {:ok, map()} | {:error, :no_active_buffer}
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(_opts) do
    state = %{
      view: %View{},
      clipboard: %{},
      minibuffer: %{mode: :inactive, input: "", cursor: 0},
      layout: nil,
      subscribers: %{},
      recent: [],
      cursors: %{},
      dir: nil,
      root: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_active_buffer, pid}, _from, state) do
    {:reply, :ok, put_active(state, pid)}
  end

  def handle_call({:set_cursor, cursor}, {caller, _ref}, state) do
    # Tell subscribers the cursor moved — **except the caller**, who already knows
    # (the loop sets the cursor on every keystroke and repaints itself; echoing it
    # back would double every repaint). This is what makes an *agent's* cursor move
    # (the `line` view action over MCP, ADR-0030) visible on screen: the loop hears
    # {:geex_cursor, cursor} and repaints.
    msg = {:geex_cursor, cursor}
    for {_ref, pid} <- state.subscribers, pid != caller, do: send(pid, msg)
    {:reply, :ok, put_in(state.view.cursor, cursor)}
  end

  def handle_call({:open_file, path}, _from, state) do
    # Serialized inside this GenServer, so the find-or-start is race-free even if
    # two harness calls open the same path at once.
    full = Path.expand(path)

    case find_or_start_buffer(full) do
      {:ok, pid} ->
        # Start watching for out-of-band writes to this file (ADR-0017). A no-op when
        # the reconciler is gated off.
        Geex.Reconcile.watch(full)
        # Start a highlight reactor for this buffer (ADR-0022). A no-op when gated
        # off, the language is unsupported, or one is already running.
        Geex.Highlight.Reactor.watch(pid, full)
        {:reply, {:ok, pid}, put_active(state, pid)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:create_file, path, content}, _from, state) do
    full = Path.expand(path)

    reply =
      cond do
        # "create" means *new*: refuse if it already exists on disk or as an open buffer
        # (don't clobber a file or shadow a buffer's in-memory content).
        File.exists?(full) -> {:error, :eexist}
        match?({:ok, _}, BufferSupervisor.whereis(full)) -> {:error, :eexist}
        true -> with(:ok <- File.write(full, content), do: {:ok, full})
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_file, path}, _from, state) do
    full = Path.expand(path)

    case File.rm(full) do
      :ok ->
        # The watcher sees this deletion, but on_disk_change skips a `:enoent` read, so
        # the eviction below — not a bogus reconcile-to-empty — is what closes the buffer.
        {discarded?, state} =
          case BufferSupervisor.whereis(full) do
            {:ok, pid} -> {dirty?(pid), drop_buffer(pid, state)}
            :error -> {false, state}
          end

        {:reply, {:ok, {full, discarded?}}, state}

      {:error, _posix} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:rename_file, from, to}, _from, state) do
    f = Path.expand(from)
    t = Path.expand(to)

    {reply, state} =
      cond do
        f == t ->
          {{:error, :same_path}, state}

        File.exists?(t) or match?({:ok, _}, BufferSupervisor.whereis(t)) ->
          {{:error, :destination_exists}, state}

        true ->
          case File.rename(f, t) do
            :ok ->
              {{:ok, {f, t}}, rekey_buffer(f, t, state)}

            # A never-saved buffer has no file on disk yet (`open_file` on a missing path is
            # a valid empty buffer, created on first save — ADR-0019), so `File.rename` fails
            # `:enoent` — but the *buffer* is real and renamable: re-key it in-memory so a
            # later `save_file` writes to the new path. With no open buffer there is genuinely
            # nothing at `from`, so the posix error stands (matching the buffer-less case).
            {:error, :enoent} ->
              case BufferSupervisor.whereis(f) do
                {:ok, _pid} -> {{:ok, {f, t}}, rekey_buffer(f, t, state)}
                :error -> {{:error, :enoent}, state}
              end

            {:error, _posix} = error ->
              {error, state}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:close_file, path}, _from, state) do
    case resolve_to_close(path, state) do
      {:ok, pid, label} ->
        {discarded?, label} = buffer_status(pid, label)
        state = drop_buffer(pid, state)
        {:reply, {:ok, {label, discarded?}}, state}

      :error ->
        {:reply, {:error, :no_such_buffer}, state}
    end
  end

  def handle_call({:set_start, %{dir: dir, root: root} = start}, _from, state),
    do: {:reply, start, %{state | dir: dir, root: root}}

  def handle_call(:start, _from, state), do: {:reply, %{dir: state.dir, root: state.root}, state}

  def handle_call(:buffers, _from, state) do
    listed =
      for pid <- state.recent, snap = safe_status(pid), do: Map.put(snap, :pid, pid)

    {:reply, listed, state}
  end

  def handle_call(:close_active, _from, state) do
    case state.view.buffer_pid do
      nil ->
        {:reply, {:error, :no_active_buffer}, state}

      pid ->
        case safe_status(pid) do
          %{dirty: true} ->
            {:reply, {:error, :dirty}, state}

          status ->
            label = (status && status.path) || "[scratch]"
            state = drop_buffer(pid, state)

            next =
              case Enum.find(state.recent, &(&1 != pid and safe_status(&1))) do
                nil -> start_scratch()
                other -> other
              end

            {:reply, {:ok, label}, put_active(state, next)}
        end
    end
  end

  def handle_call(:active_buffer, _from, state) do
    reply = if pid = state.view.buffer_pid, do: {:ok, pid}, else: :error
    {:reply, reply, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, state.view.buffer_pid, %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
  end

  def handle_call(:snapshot, _from, state) do
    reply =
      case state.view.buffer_pid do
        nil ->
          {:error, :no_active_buffer}

        pid ->
          # Guarded like dirty?/buffer_status: a stale dead pid (the pointer is
          # deliberately unmonitored) must degrade to "no active buffer", not take
          # the Session down. The merged cursor is **clamped to the text** here — the
          # view cursor is stored unvalidated (set_cursor can race a buffer
          # switch/shrink, and the pointer move keeps the old cursor), so the point
          # of *read* is where every consumer is guaranteed an in-range caret.
          case safe_buffer_snapshot(pid) do
            {:ok, buffer} ->
              {:ok, Map.put(buffer, :cursor, clamp_cursor(state.view.cursor, buffer.lines))}

            :error ->
              {:error, :no_active_buffer}
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{subscribers: subs} = state)
      when is_map_key(subs, ref) do
    {:noreply, %{state | subscribers: Map.delete(subs, ref)}}
  end

  # A buffer in the recent list ended: forget it (and its cursor). The active pointer is left
  # as it is, as before (see `open_file/1`).
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{state | recent: List.delete(state.recent, pid), cursors: Map.delete(state.cursors, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Reuse the buffer already open for this (normalized) path, else start one. The
  # `:already_started` race (registry rejects a duplicate name) collapses back to
  # the existing pid, so concurrent opens converge on one buffer per path.
  defp find_or_start_buffer(path) do
    case BufferSupervisor.whereis(path) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case BufferSupervisor.start_buffer(path) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = error -> error
        end
    end
  end

  # Resolve the buffer `close_file` should drop: the active one (nil), or the buffer
  # registered for an explicit path. `label` is carried for the result message — nil for
  # the active buffer, filled in from its snapshot path later.
  defp resolve_to_close(nil, state) do
    case state.view.buffer_pid do
      pid when is_pid(pid) -> {:ok, pid, nil}
      nil -> :error
    end
  end

  defp resolve_to_close(path, _state) when is_binary(path) do
    case BufferSupervisor.whereis(Path.expand(path)) do
      {:ok, pid} -> {:ok, pid, path}
      :error -> :error
    end
  end

  # If a buffer is open for `from`, re-key it to `to` (preserving its edits + history)
  # and start watching the destination. The active-buffer pid is unchanged (same process),
  # so the pointer needs no update. A re-key failure is logged, not fatal: the disk file
  # already moved, and the buffer's stale path is recoverable by a re-open.
  defp rekey_buffer(from, to, state) do
    with {:ok, pid} <- BufferSupervisor.whereis(from) do
      case safe_rename(pid, to) do
        :ok ->
          Geex.Reconcile.watch(to)
          # Re-evaluate highlighting for the new path: the grammar follows the new
          # extension (or stops if unsupported). A no-op when gated off (ADR-0022).
          Geex.Highlight.Reactor.rewatch(pid, to)

        {:error, reason} ->
          Logger.warning(
            "geex: renamed #{from} -> #{to} on disk but could not re-key its buffer " <>
              "(#{inspect(reason)}); the buffer still targets the old path"
          )
      end
    end

    state
  end

  # The buffer can die between the `whereis` and this call (it is `:temporary`); the disk
  # rename has *already committed*, so a buffer death must degrade to the logged,
  # stale-path-recoverable-by-reopen branch above — never crash the serialized Session
  # (matching the `catch :exit` discipline of `dirty?`/`buffer_status`/`evict`).
  defp safe_rename(pid, to) do
    Buffer.rename(pid, to)
  catch
    :exit, _ -> {:error, :buffer_down}
  end

  # Evict `pid`: release its path registration synchronously (so a re-open/re-create of
  # the path right after this sees a clean registry, not the dying pid via the monitor's
  # async cleanup), terminate it, and clear the active pointer if it pointed here.
  defp drop_buffer(pid, state) do
    evict(pid)

    state = %{
      state
      | recent: List.delete(state.recent, pid),
        cursors: Map.delete(state.cursors, pid)
    }

    if state.view.buffer_pid == pid, do: put_active(state, nil), else: state
  end

  # Update the active-buffer pointer and notify subscribers when it actually changes. The
  # buffer being left keeps its cursor; the one switched to gets its own back (ADR-0034).
  defp put_active(state, pid) do
    if state.view.buffer_pid == pid do
      state
    else
      state = remember_cursor(state)
      {cursor, cursors} = Map.pop(state.cursors, pid, {0, 0})
      state = %{state | cursors: cursors, recent: to_front(state.recent, pid)}
      state = %{state | view: %{state.view | buffer_pid: pid, cursor: cursor}}
      msg = {:geex_active_buffer, pid}
      Enum.each(Map.values(state.subscribers), &send(&1, msg))
      state
    end
  end

  defp remember_cursor(%{view: %{buffer_pid: old, cursor: cursor}} = state) when is_pid(old),
    do: put_in(state.cursors[old], cursor)

  defp remember_cursor(state), do: state

  defp to_front(recent, nil), do: recent

  defp to_front(recent, pid) do
    unless pid in recent, do: Process.monitor(pid)
    [pid | List.delete(recent, pid)]
  end

  # A new empty scratch buffer, supervised like any other (so its crash isn't ours).
  defp start_scratch do
    {:ok, pid} = BufferSupervisor.start_scratch()
    pid
  end

  # The path, dirty flag and behind mark, or `nil` for a buffer that died.
  defp safe_status(pid) do
    Buffer.status(pid)
  catch
    :exit, _ -> nil
  end

  # The git work tree's top level, or nil (not a repository, or no git). Git's stderr is
  # dropped: in the TUI the terminal belongs to the renderer.
  defp git_root(dir) do
    case System.find_executable("git") do
      nil ->
        nil

      git ->
        script = ~s|exec "$0" -C "$1" rev-parse --show-toplevel 2>/dev/null|

        case System.cmd("sh", ["-c", script, git, dir]) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end
    end
  end

  # Unregister-then-terminate, tolerant of two edge cases a *serialized* Session must not
  # crash or lie on:
  #   * the buffer already died (it is `:temporary`, and the active pid is unmonitored —
  #     see `open_file/1`): an unguarded `GenServer.call` into a dead pid exits `:noproc`
  #     and would take the whole Session (and its view/clipboard/minibuffer state) down.
  #     The siblings `dirty?`/`buffer_status` already `catch :exit` for exactly this; do
  #     the same here. A dead buffer needs no unregister — its entry clears via the
  #     monitor's `:DOWN` — so swallowing the exit is correct.
  #   * the buffer is not a `BufferSupervisor` child (a directly-started pathless scratch
  #     buffer): `terminate/1` then returns `{:error, :not_found}` and the process would be
  #     left ALIVE while we report it "closed" (and, if dirty, "discarded unsaved edits") —
  #     a double lie that also leaks the process. Stop it directly so "closed" is honest.
  defp evict(pid) do
    Buffer.unregister(pid)

    case BufferSupervisor.terminate(pid) do
      :ok -> :ok
      {:error, :not_found} -> GenServer.stop(pid, :shutdown)
    end
  catch
    :exit, _ -> :ok
  end

  # Whether `pid`'s buffer holds unsaved edits — for the "discarded unsaved edits" notice.
  # Guarded: a buffer dying between resolution and the call reports clean, never crashes.
  defp dirty?(pid) do
    Buffer.snapshot(pid).dirty
  catch
    :exit, _ -> false
  end

  # One snapshot read for both the dirty flag and a display label (the buffer's path, or a
  # placeholder for a pathless scratch buffer / a buffer that just died).
  defp buffer_status(pid, label) do
    snapshot = Buffer.snapshot(pid)
    {snapshot.dirty, label || snapshot.path || "active buffer"}
  catch
    :exit, _ -> {false, label || "buffer"}
  end

  # The full snapshot, guarded the same way: a dead/stale active buffer reads as absent.
  defp safe_buffer_snapshot(pid) do
    {:ok, Buffer.snapshot(pid)}
  catch
    :exit, _ -> :error
  end

  # Clamp a stored {line, col} to a valid caret in `lines` — the stored view cursor can be
  # out of range (a set_cursor racing a shrink; a buffer switch keeping the old position).
  defp clamp_cursor({line, col}, lines) do
    line = line |> max(0) |> min(length(lines) - 1)
    col = col |> max(0) |> min(lines |> Enum.at(line, "") |> String.length())
    {line, col}
  end
end
