defmodule Geex.Highlight.Reactor do
  @moduledoc """
  The capability **reactor** for syntax highlighting — one process per buffer
  ([ADR-0022](../../../doc/adr/0022-capability-reactor.md)).

  It subscribes to the buffer's change stream (the post-dispatch emit, ADR-0022)
  and turns each change into an **async, coalesced, latest-wins** highlight pass:
  the actual `Geex.Highlight.spans/3` call runs in a throwaway task, so the buffer
  and the command path **never wait** on highlighting, and at most one pass is in
  flight (a burst of keystrokes collapses to one re-highlight of the newest text).
  The resulting spans are a **view-local overlay** kept in this process — read via
  `highlights/1`, never written back through `Dispatch`, never in undo history
  (highlighting has no correctness contract; staleness is free).

  Separate from `Geex.Buffer` for async-by-construction, **crash isolation** (a bad
  grammar kills the reactor, not the buffer — unsaved edits stay safe; it is a
  `:temporary` child and it monitors the buffer, so it follows the buffer's life),
  and separation of concerns.

  Whole-buffer for now; viewport-first and a debounce interval are the tuning
  refinements ADR-0022 leaves open.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Geex.Highlight

  @default_timeout_ms 5_000

  ## Public API

  @doc """
  Start a reactor for `buffer` (a pid) highlighting in `language`. Registered by
  buffer in `Geex.Registry`, so a second start for the same buffer is a no-op
  (`{:error, {:already_started, pid}}`).
  """
  def start_link(opts) do
    buffer = Keyword.fetch!(opts, :buffer)
    GenServer.start_link(__MODULE__, opts, name: via(buffer))
  end

  @doc "The running reactor for `buffer`, or `:error`."
  @spec for_buffer(pid()) :: {:ok, pid()} | :error
  def for_buffer(buffer) when is_pid(buffer) do
    case Registry.lookup(Geex.Registry, {:highlight_reactor, buffer}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  The latest highlight overlay: `%{version: v, spans: [Span.t()]}` (the buffer
  version the spans were computed for), or `nil` before the first pass completes.
  """
  @spec highlights(GenServer.server()) :: %{version: non_neg_integer(), spans: [map()]} | nil
  def highlights(reactor), do: GenServer.call(reactor, :highlights)

  @doc """
  Block until the reactor has an overlay for buffer version `>= min_version` (or
  `timeout_ms` elapses). Polls `highlights/1` — for tests and callers that want to
  observe a specific edit's highlighting. Returns `{:ok, overlay}` or
  `{:error, :timeout}`.
  """
  @spec await(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def await(reactor, min_version, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(reactor, min_version, deadline)
  end

  defp do_await(reactor, min_version, deadline) do
    case highlights(reactor) do
      %{version: v} = overlay when v >= min_version ->
        {:ok, overlay}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          do_await(reactor, min_version, deadline)
        end
    end
  end

  @doc """
  Start highlighting `buffer` (path-derived language) **if** the `:start_highlight`
  gate is on — the `Geex.Session.open_file/1` hook, mirroring `Geex.Reconcile.watch/1`.
  A no-op when gated off, when the language is unsupported, or when a reactor is
  already running for the buffer.
  """
  @spec watch(pid(), String.t()) :: :ok
  def watch(buffer, path) when is_pid(buffer) and is_binary(path) do
    if Application.get_env(:geex, :start_highlight, false) do
      with {:ok, lang} <- Highlight.language_for_path(path),
           :error <- for_buffer(buffer) do
        Geex.Highlight.ReactorSupervisor.start_reactor(buffer, lang)
      end
    end

    :ok
  end

  ## GenServer

  @impl true
  def init(opts) do
    buffer = Keyword.fetch!(opts, :buffer)
    lang = Keyword.fetch!(opts, :language)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    buffer_ref = Process.monitor(buffer)
    {:ok, _version} = Geex.Buffer.subscribe(buffer, self())

    state = %{
      buffer: buffer,
      buffer_ref: buffer_ref,
      lang: lang,
      timeout_ms: timeout,
      result: nil,
      in_flight: nil,
      # An initial pass over already-loaded content, before any edit.
      pending: true,
      pass_counter: 0
    }

    {:ok, maybe_start(state)}
  end

  @impl true
  def handle_call(:highlights, _from, state), do: {:reply, state.result, state}

  @impl true
  def handle_info({:geex_buffer_change, buffer, _version}, %{buffer: buffer} = state) do
    {:noreply, maybe_start(%{state | pending: true})}
  end

  def handle_info({:pass_result, id, version, result}, %{in_flight: %{id: id, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    new_result =
      case result do
        {:ok, spans} ->
          %{version: version, spans: spans}

        {:error, reason} ->
          Logger.debug("geex highlight reactor: pass failed (#{inspect(reason)}); keeping prior overlay")
          state.result
      end

    {:noreply, maybe_start(%{state | in_flight: nil, result: new_result})}
  end

  # A result from a superseded pass — ignore.
  def handle_info({:pass_result, _id, _version, _result}, state), do: {:noreply, state}

  # The buffer died — the reactor follows it (no orphaned per-buffer process).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{buffer_ref: ref} = state) do
    {:stop, :normal, state}
  end

  # The highlight task died without a result (shouldn't happen — spans/3 returns
  # tuples, never raises) — drop the pass and re-check.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{in_flight: %{ref: ref}} = state) do
    {:noreply, maybe_start(%{state | in_flight: nil})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  ## Internal — the latest-wins pass loop

  defp maybe_start(%{in_flight: nil, pending: true} = state), do: start_pass(state)
  defp maybe_start(state), do: state

  # Fetch the freshest buffer text and highlight it in a throwaway task. `pending`
  # is cleared here; any change arriving during the pass sets it again, and the
  # pass-completion handler re-checks — so bursts coalesce to the newest text.
  defp start_pass(state) do
    case safe_snapshot(state.buffer) do
      :down ->
        # Buffer gone; the monitor :DOWN will stop us. Leave state as-is.
        state

      {version, text} ->
        id = state.pass_counter + 1
        parent = self()
        {lang, timeout} = {state.lang, state.timeout_ms}

        pid =
          spawn(fn ->
            send(parent, {:pass_result, id, version, Highlight.spans(text, lang, timeout)})
          end)

        ref = Process.monitor(pid)
        %{state | in_flight: %{id: id, ref: ref, version: version}, pending: false, pass_counter: id}
    end
  end

  defp safe_snapshot(buffer) do
    snap = Geex.Buffer.snapshot(buffer)
    {snap.version, snap.text}
  catch
    :exit, _ -> :down
  end

  defp via(buffer), do: {:via, Registry, {Geex.Registry, {:highlight_reactor, buffer}}}
end
