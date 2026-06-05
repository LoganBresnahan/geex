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

  Dispatch lives in `Geex.Dispatch`. The per-buffer `Geex.Buffer` process owns the
  `EditorState` and the one undo history and applies commands via `Geex.Dispatch.run/1`;
  Session holds only this cross-buffer state. `snapshot/0` is the read-only headless
  query surface (§15b): it merges the view-local cursor with the active buffer's
  recorded snapshot. See `doc/adr/0014` and `doc/adr/0015`.
  """

  use GenServer

  alias Geex.{BufferSupervisor, View}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Make `pid` (or `nil`) the active buffer the view points at."
  @spec set_active_buffer(pid() | nil) :: :ok
  def set_active_buffer(pid) when is_pid(pid) or is_nil(pid),
    do: GenServer.call(__MODULE__, {:set_active_buffer, pid})

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

  @doc "The active buffer pid, or `:error` if none is active."
  @spec active_buffer() :: {:ok, pid()} | :error
  def active_buffer, do: GenServer.call(__MODULE__, :active_buffer)

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
      layout: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_active_buffer, pid}, _from, state) do
    {:reply, :ok, put_in(state.view.buffer_pid, pid)}
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
        {:reply, {:ok, pid}, put_in(state.view.buffer_pid, pid)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:active_buffer, _from, state) do
    reply = if pid = state.view.buffer_pid, do: {:ok, pid}, else: :error
    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state) do
    reply =
      case state.view.buffer_pid do
        nil ->
          {:error, :no_active_buffer}

        pid ->
          buffer = Geex.Buffer.snapshot(pid)
          {:ok, Map.put(buffer, :cursor, state.view.cursor)}
      end

    {:reply, reply, state}
  end

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
end
