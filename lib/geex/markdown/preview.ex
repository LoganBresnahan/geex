defmodule Geex.Markdown.Preview do
  @moduledoc """
  The markdown preview's process, one per buffer with a preview open
  ([ADR-0043](../../../doc/adr/0043-markdown-preview.md) §2, §3). It renders the **file on
  disk**, never the buffer, off the key loop: reading, parsing, highlighting and layout run in a
  spawned, monitored worker, as the highlight reactor's pass does (ADR-0022, ADR-0035).

  **Ownership.** A `:temporary` child of `Geex.Markdown.PreviewSupervisor`, registered as
  `{:markdown_preview, buffer}` in `Geex.Registry` and started idempotently (`attach/2`). It
  monitors its buffer and its subscribers; when the buffer or its last subscriber goes it
  unregisters first, then stops, so a restarted loop leaves no orphan and a quick reopen can't
  subscribe to a process that is stopping.

  **Triggers.** It reads the file again when a subscriber arrives, when the buffer's synced
  text moves (`{:geex_buffer_synced, buffer, sha256}`), when the disk moves ahead
  (`{:geex_buffer_behind, …}`), and on `reread/1` (an install of a grammar a code block names).
  It ignores the other buffer messages, every keystroke's change among them. A read whose hash
  it last rendered is parsed no further.

  **A read caught mid-write.** A read is drawn only when its sha256 is the hash the buffer last
  gave for the disk: behind's while behind, else the synced text's (`Geex.Buffer.status/1`). On
  a mismatch it reads again after `:settle_ms` (reconcile's 50 ms); the third mismatch is drawn,
  marked `:changing`. Renders are sent as they finish.

  **Merging work.** Pending work is one request: a re-read once any trigger has arrived, the
  widths not laid out yet, and the latest save anchor (§6). Each part stays pending until a
  render started after it arrived has run, so a width change never replaces a pending re-read.
  Nothing runs while no width is wanted.

  **What subscribers get**, one message per render:

      {:geex_preview, buffer, %{render: n, rows: %{width => %{rows: rows, lines: lines}},
                                status: status, anchor: line | nil, remap: map | nil,
                                hash: sha256 | nil, from: sha256 | nil, languages: [name]}}

  `rows` holds the widths this render laid out: a width missing from it keeps its old rows.
  `lines` is `Geex.Markdown.Place.lines/2`, computed here, not in the loop. `remap` is the
  `Geex.Markdown.Place.line_map/2` from the last rendered text, `nil` when the text didn't
  change. `hash` is the sha256 of the text these rows draw, and `from` the hash of the text the
  remap maps from (the same hash when the text didn't change, `nil` with no remap), so a
  subscriber applies the remap only to rows of that text. `status` is `:ok`, `:changing`, `{:read, posix}` (no rows: the file isn't readable),
  `{:unavailable, why}` (`Geex.Markdown.handles/1`) or `{:failed, reason}` (a crashed render;
  rows keep the last ones). Rows carry roles and capture names, never colours, so a theme change
  only redraws.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Geex.Buffer
  alias Geex.Markdown
  alias Geex.Markdown.Place

  @settle_ms 50
  @tries 3

  ## Public API

  @doc """
  Start a preview for `buffer` (options: `:buffer`, and for tests `:read`, a
  `fn path -> {:ok, bytes} | {:error, posix} end`, and `:settle_ms`).
  """
  def start_link(opts) do
    buffer = Keyword.fetch!(opts, :buffer)
    GenServer.start_link(__MODULE__, opts, name: via(buffer))
  end

  defp via(buffer), do: {:via, Registry, {Geex.Registry, {:markdown_preview, buffer}}}

  @doc "The running preview for `buffer`, or `:error`."
  @spec lookup(pid()) :: {:ok, pid()} | :error
  def lookup(buffer) do
    case Registry.lookup(Geex.Registry, {:markdown_preview, buffer}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  The preview for `buffer`, started under `Geex.Markdown.PreviewSupervisor` if none runs, with
  `sub` subscribed. If the one found is stopping (the subscribe exits), one is started again.
  """
  @spec attach(pid(), pid()) :: {:ok, pid()} | {:error, term()}
  def attach(buffer, sub \\ self()), do: attach(buffer, sub, 2)

  defp attach(_buffer, _sub, 0), do: {:error, :stopping}

  defp attach(buffer, sub, tries) do
    spec = {__MODULE__, buffer: buffer}

    pid =
      case DynamicSupervisor.start_child(Geex.Markdown.PreviewSupervisor, spec) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
        {:error, reason} -> {:error, reason}
      end

    with pid when is_pid(pid) <- pid do
      try do
        :ok = subscribe(pid, sub)
        {:ok, pid}
      catch
        :exit, _ -> attach(buffer, sub, tries - 1)
      end
    end
  end

  @doc "Subscribe `sub` to the renders. It is sent the last render at once, if there is one."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(preview, sub), do: GenServer.call(preview, {:subscribe, sub})

  @doc "Stop sending `sub` renders; the preview stops when it has no subscribers left."
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(preview, sub), do: GenServer.cast(preview, {:unsubscribe, sub})

  @doc "The text widths the buffer's preview tabs have now: each is laid out once."
  @spec widths(GenServer.server(), [pos_integer()]) :: :ok
  def widths(preview, widths), do: GenServer.cast(preview, {:widths, widths})

  @doc """
  The user saved from a source tab with the cursor on `line` (0-based): the next render carries
  it as `anchor`, so the loop scrolls every preview of the buffer there (ADR-0043 §6).
  """
  @spec saved(GenServer.server(), non_neg_integer()) :: :ok
  def saved(preview, line), do: GenServer.cast(preview, {:saved, line})

  @doc "Read again (a rename): a read of the text it last rendered renders nothing new."
  @spec reread(GenServer.server()) :: :ok
  def reread(preview), do: GenServer.cast(preview, :reread)

  @doc """
  Read and parse again even if the bytes are the same: an install of a grammar its code blocks
  name, or of a new Markdown package, takes effect without waiting for the file to change
  (ADR-0043 §4).
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(preview), do: GenServer.cast(preview, :refresh)

  @doc """
  What a status says in the preview's header, or nil when there's nothing to say.

      iex> Geex.Markdown.Preview.describe({:read, :enoent})
      "not on disk"
      iex> Geex.Markdown.Preview.describe({:read, :eacces})
      "permission denied"
      iex> Geex.Markdown.Preview.describe(:ok)
      nil
  """
  @spec describe(term()) :: String.t() | nil
  def describe(:ok), do: nil
  def describe(:changing), do: "changing"
  def describe(:stopped), do: "stopped"
  def describe({:read, :enoent}), do: "not on disk"
  def describe({:read, posix}), do: posix |> :file.format_error() |> List.to_string()
  def describe({:unavailable, why}), do: Markdown.describe(why)
  def describe({:failed, _reason}), do: "render failed (see the log)"

  ## Server

  @impl true
  def init(opts) do
    buffer = Keyword.fetch!(opts, :buffer)

    state = %{
      buffer: buffer,
      read: Keyword.get(opts, :read, &File.read/1),
      settle_ms: Keyword.get(opts, :settle_ms, @settle_ms),
      subs: %{},
      wanted: [],
      # Work waiting for the next render: `reread`, `widths` not laid out yet, `anchor`.
      pending: %{reread: false, force: false, widths: MapSet.new(), anchor: nil},
      worker: nil,
      tries: 0,
      retry: nil,
      # The last good parse and its hash, and the rows last sent per width.
      parsed: nil,
      hash: nil,
      rows: %{},
      status: :ok,
      render: 0
    }

    # A shutdown from the supervisor reaches terminate/2, which kills a render under way.
    Process.flag(:trap_exit, true)
    # Nothing is read here: the first subscriber's arrival is the first trigger.
    {:ok, state, {:continue, :watch}}
  end

  @impl true
  def handle_continue(:watch, state) do
    Process.monitor(state.buffer)

    case catch_exit(fn -> Buffer.subscribe(state.buffer, self()) end) do
      {:ok, _version} -> {:noreply, state}
      _gone -> stop(state)
    end
  end

  @impl true
  def handle_call({:subscribe, sub}, _from, state) do
    if sub in Map.values(state.subs) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(sub)
      if state.rows != %{}, do: send(sub, message(state, state.rows, nil, nil, state.hash))
      state = %{state | subs: Map.put(state.subs, ref, sub)}
      {:reply, :ok, state |> want(:reread) |> run()}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, sub}, state) do
    case Enum.find(state.subs, fn {_ref, pid} -> pid == sub end) do
      {ref, _pid} ->
        Process.demonitor(ref, [:flush])
        drop_sub(state, ref)

      nil ->
        {:noreply, state}
    end
  end

  def handle_cast({:widths, widths}, state) do
    wanted = widths |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.uniq()
    new = Enum.reject(wanted, &Map.has_key?(state.rows, &1))

    state = %{
      state
      | wanted: wanted,
        rows: Map.take(state.rows, wanted),
        pending: %{state.pending | widths: MapSet.union(state.pending.widths, MapSet.new(new))}
    }

    {:noreply, run(state)}
  end

  def handle_cast({:saved, line}, state),
    do: {:noreply, state |> want(:reread) |> put_in([:pending, :anchor], line) |> run()}

  def handle_cast(:reread, state), do: {:noreply, state |> want(:reread) |> run()}

  def handle_cast(:refresh, state),
    do: {:noreply, state |> want(:reread) |> put_in([:pending, :force], true) |> run()}

  @impl true
  def handle_info({:geex_buffer_synced, buffer, _sha}, %{buffer: buffer} = state),
    do: {:noreply, state |> want(:reread) |> run()}

  def handle_info({:geex_buffer_behind, buffer, _behind}, %{buffer: buffer} = state),
    do: {:noreply, state |> want(:reread) |> run()}

  # A render finished.
  def handle_info({:rendered, ref, result}, %{worker: {ref, _pid, job}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | worker: nil}
    {:noreply, state |> finish(job, result) |> run()}
  end

  # A render crashed: the rows stay, the status says so (a crash costs a frame).
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker: {ref, _wpid, job}} = state) do
    Logger.warning("geex preview: a render failed: #{inspect(reason)}")
    state = %{state | worker: nil, status: {:failed, reason}, tries: 0}
    {:noreply, state |> broadcast(%{}, job.anchor, nil, state.hash) |> run()}
  end

  def handle_info({:DOWN, _ref, :process, buffer, _reason}, %{buffer: buffer} = state),
    do: stop(state)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.subs, ref),
      do: drop_sub(state, ref)

  def handle_info(:retry, state),
    do: {:noreply, %{state | retry: nil} |> want(:reread) |> run()}

  # Every other buffer message (a keystroke's change, a notice, an attestation).
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: kill_worker(state)

  ## Work

  defp want(state, :reread), do: put_in(state.pending.reread, true)

  defp drop_sub(state, ref) do
    state = %{state | subs: Map.delete(state.subs, ref)}
    if state.subs == %{}, do: stop(state), else: {:noreply, state}
  end

  # Unregister first, so a quick reopen starts a new preview rather than subscribing to this
  # one while it stops. A render under way is killed: nobody wants its rows, and it would
  # otherwise go on parsing (and filling the grammar caches) for a preview that is gone.
  defp stop(state) do
    Registry.unregister(Geex.Registry, {:markdown_preview, state.buffer})
    kill_worker(state)
    {:stop, :normal, %{state | worker: nil}}
  end

  defp kill_worker(%{worker: {_ref, pid, _job}}), do: Process.exit(pid, :kill)
  defp kill_worker(_state), do: :ok

  defp catch_exit(fun) do
    fun.()
  catch
    :exit, reason -> {:exit, reason}
  end

  # Start a render when nothing runs, a width is wanted and some work is pending.
  defp run(%{worker: nil, retry: nil, wanted: [_ | _]} = state) do
    %{reread: reread, force: force, widths: widths, anchor: anchor} = state.pending

    if reread or MapSet.size(widths) > 0 or anchor != nil do
      job = %{
        # With no parse to lay out (a failed read, the grammars missing), a new width reads again.
        reread: reread or anchor != nil or state.parsed == nil,
        force: force,
        # Every width wanted, for a changed text or an anchor; the new ones, for the same text.
        wanted: state.wanted,
        new: Enum.filter(state.wanted, &MapSet.member?(widths, &1)),
        anchor: anchor,
        buffer: state.buffer,
        read: state.read,
        parsed: state.parsed,
        hash: state.hash,
        last_try: state.tries >= @tries - 1
      }

      # Monitored, not linked (ADR-0035); the monitor's ref names the result.
      parent = self()
      pid = spawn(fn -> receive do: ({:go, ref} -> send(parent, {:rendered, ref, work(job)})) end)
      ref = Process.monitor(pid)
      send(pid, {:go, ref})

      %{
        state
        | worker: {ref, pid, job},
          pending: %{reread: false, force: false, widths: MapSet.new(), anchor: nil}
      }
    else
      state
    end
  end

  defp run(state), do: state

  defp finish(state, job, {:retry, _sha}) do
    # Keep what the job carried pending, and read again once the write has settled.
    pending = %{
      state.pending
      | reread: true,
        force: state.pending.force or job.force,
        widths: MapSet.union(state.pending.widths, MapSet.new(job.new)),
        anchor: state.pending.anchor || job.anchor
    }

    %{state | pending: pending, tries: state.tries + 1, retry: retry(state.settle_ms)}
  end

  defp finish(state, job, {:read, posix}) do
    rows = Map.new(state.wanted, &{&1, %{rows: [], lines: {}}})
    state = %{state | parsed: nil, hash: nil, rows: rows, status: {:read, posix}, tries: 0}
    broadcast(state, rows, job.anchor, nil, nil)
  end

  defp finish(state, job, {:unavailable, why}) do
    state = %{state | status: {:unavailable, why}, tries: 0}
    broadcast(state, %{}, job.anchor, nil, state.hash)
  end

  # The text it last rendered, and nothing new to lay out; a status that changed (a write that
  # settled after "changing", a read fine again after a failure) is still said.
  defp finish(state, job, {:same, status}) do
    state = %{state | tries: 0}

    if status == state.status,
      do: state,
      else: broadcast(%{state | status: status}, %{}, job.anchor, nil, state.hash)
  end

  defp finish(state, job, {:ok, result}) do
    state = %{
      state
      | parsed: result.parsed,
        hash: result.hash,
        rows: state.rows |> Map.merge(result.rows) |> Map.take(state.wanted),
        status: result.status,
        tries: 0
    }

    # A width dropped while the render ran isn't sent. `from`: the text the remap maps from, or
    # this one when the text didn't change.
    from = if result.remap, do: job.hash, else: if(job.hash == result.hash, do: result.hash)
    broadcast(state, Map.take(result.rows, state.wanted), job.anchor, result.remap, from)
  end

  defp retry(ms), do: Process.send_after(self(), :retry, ms)

  # Send every subscriber the render, numbered.
  defp broadcast(state, rows, anchor, remap, from) do
    state = %{state | render: state.render + 1}
    msg = message(state, rows, anchor, remap, from)
    for {_ref, sub} <- state.subs, do: send(sub, msg)
    state
  end

  defp message(state, rows, anchor, remap, from) do
    {:geex_preview, state.buffer,
     %{
       render: state.render,
       rows: rows,
       status: state.status,
       anchor: anchor,
       remap: remap,
       hash: state.hash,
       from: from,
       languages: if(state.parsed, do: state.parsed.languages, else: [])
     }}
  end

  ## The worker (a monitored process): read, check, parse, lay out.

  @doc false
  def work(%{reread: false} = job),
    do: {:ok, layout(job.new, job.parsed, job.hash, nil, :ok)}

  def work(job) do
    status = Buffer.status(job.buffer)

    case read(job, status.path) do
      {:error, posix} ->
        {:read, posix}

      {:ok, bytes} ->
        sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        expected = if status.behind, do: status.behind.sha256, else: status.synced
        same? = sha == job.hash and job.parsed != nil

        same? = same? and not job.force
        status = if sha == expected, do: :ok, else: :changing

        cond do
          sha != expected and not job.last_try -> {:retry, sha}
          same? and job.anchor == nil and job.new == [] -> {:same, status}
          same? and job.anchor == nil -> {:ok, layout(job.new, job.parsed, sha, nil, :ok)}
          same? -> {:ok, layout(job.wanted, job.parsed, sha, nil, :ok)}
          true -> parse(job, bytes, sha, status)
        end
    end
  end

  defp read(_job, nil), do: {:error, :enoent}
  defp read(job, path), do: job.read.(path)

  defp parse(job, bytes, sha, status) do
    case Markdown.handles() do
      {:ok, grammars} ->
        {:ok, parsed} = Markdown.parse(bytes, grammars)
        remap = if job.parsed, do: Place.line_map(job.parsed.text, parsed.text)
        {:ok, layout(job.wanted, parsed, sha, remap, status)}

      {:error, why} ->
        {:unavailable, why}
    end
  end

  defp layout(widths, parsed, sha, remap, status) do
    rows =
      Map.new(widths, fn width ->
        rows = Markdown.rows(parsed, width)
        {width, %{rows: rows, lines: Place.lines(rows, parsed.text)}}
      end)

    %{parsed: parsed, hash: sha, rows: rows, remap: remap, status: status}
  end
end
