defmodule Geex.LastSession do
  @moduledoc """
  The last session of a project, kept across restarts (roadmap item 18.9,
  [ADR-0038](../../doc/adr/0038-split-panes-and-tabs.md)'s 2026-11-09 amendment): the file panes,
  each one's tabs (the file, its cursor and scroll) and which is shown, the current pane, how the
  split divides the editor, and the sizes of the tree and the edits pane.

  A bare `geex` or `geex DIR` brings the project's last session back; `geex FILE` opens just
  that file and keeps the remembered sizes (and leaves the remembered files alone). The file is
  `$XDG_STATE_HOME/geex/sessions/<key>.json`, `<key>` the first 16 hex digits of the sha256 of
  the project root, as the ledger names its files (ADR-0033); `0600` in a `0700` directory,
  written whole or not at all. App gate `session_memory` (off under test); `sessions_dir`
  overrides the directory.

  `encode/4`, `decode/1` and `panes/2` are pure: what is kept, read back, and the panes it
  rebuilds from the buffers that could be opened again. A markdown preview's tab and a file
  with no path (a scratch buffer) aren't kept; a file that has gone since is left out, and a
  pane left with no tab goes with it (and is forgotten at the next keep).

  Writes go through one writer process per loop (`writer/1`), in the order they are sent, so a
  quit's last write (`keep_now/5`, which waits for it) can't be overtaken by an older one. The
  writer tells the loop how each went (`{:geex_session_written, map, result}`), and the loop
  counts a session kept only once it is. A failure is logged once until it changes.

  A `geex FILE` instance and a project instance of the same project both write its file, the
  first only the sizes, reading the file and writing it back: two at once can lose one's write
  until its next change. Restored files are opened at startup one after another, as `geex a b c`
  opens its files.
  """

  require Logger

  alias Geex.Loop.Panes

  @type saved :: %{
          split: Geex.Layout.split(),
          panes: %{
            pos_integer() => %{
              at: non_neg_integer(),
              tabs: [
                %{
                  path: String.t(),
                  cursor: {non_neg_integer(), non_neg_integer()},
                  scroll: non_neg_integer()
                }
              ]
            }
          },
          pane: pos_integer(),
          tree_w: pos_integer() | nil,
          edits_h: pos_integer() | nil
        }

  @doc "Whether sessions are kept (the `session_memory` gate)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:geex, :session_memory, true)

  @doc "The session file of the project at `root`."
  @spec file(Path.t()) :: Path.t()
  def file(root) do
    dir = Application.get_env(:geex, :sessions_dir) || Path.join(Geex.state_dir(), "sessions")
    key = :crypto.hash(:sha256, Path.expand(root)) |> Base.encode16(case: :lower)
    Path.join(dir, binary_part(key, 0, 16) <> ".json")
  end

  @doc """
  What is kept of `panes` and the sizes: the JSON-ready map `decode/1` reads back. `path_of`
  names each buffer's file (`nil` for a buffer with none). The current tab's cursor is read from
  the panes, so the caller copies Session's into them first.
  """
  @spec encode(Panes.t(), (pid() -> String.t() | nil), pos_integer() | nil, pos_integer() | nil) ::
          map()
  def encode(%{split: split, panes: panes, pane: pane}, path_of, tree_w, edits_h) do
    %{
      "v" => 1,
      "split" => encode_split(split),
      "pane" => pane,
      "panes" =>
        Map.new(panes, fn {id, %{tabs: tabs, at: at}} ->
          kept =
            for tab <- tabs,
                not Panes.preview?(tab),
                path = path_of.(tab.buffer),
                is_binary(path),
                do: {tab, path}

          # The shown tab, counted among the tabs kept (a preview or a scratch buffer isn't).
          shown = Enum.at(tabs, at)
          at = Enum.find_index(kept, fn {tab, _} -> tab == shown end) || 0

          {Integer.to_string(id),
           %{
             "at" => at,
             "tabs" =>
               for {tab, path} <- kept do
                 {line, col} = tab.cursor
                 %{"path" => path, "cursor" => [line, col], "scroll" => tab.scroll}
               end
           }}
        end),
      "tree_w" => tree_w,
      "edits_h" => edits_h
    }
  end

  defp encode_split({:pane, id}), do: %{"pane" => id}

  defp encode_split({dir, a, b, ratio}),
    do: %{
      "dir" => Atom.to_string(dir),
      "ratio" => ratio,
      "a" => encode_split(a),
      "b" => encode_split(b)
    }

  @doc """
  Read back what `encode/4` kept, or `:error` for anything else (another version, a hand edit
  gone wrong): a session that can't be read is ignored, never half applied.

      iex> panes = %{split: {:pane, 1}, panes: %{1 => %{tabs: [], at: 0}}, pane: 1, next: 2}
      iex> panes |> Geex.LastSession.encode(fn _ -> nil end, 40, nil) |> Geex.LastSession.decode()
      {:ok, %{split: {:pane, 1}, panes: %{1 => %{at: 0, tabs: []}}, pane: 1, tree_w: 40, edits_h: nil}}
      iex> Geex.LastSession.decode(%{"v" => 2})
      :error
  """
  @spec decode(term()) :: {:ok, saved()} | :error
  def decode(%{"v" => 1, "split" => split, "pane" => pane, "panes" => panes} = map)
      when is_integer(pane) and is_map(panes) do
    with {:ok, split} <- decode_split(split),
         {:ok, panes} <- decode_panes(panes),
         true <- Enum.sort(ids(split)) == Enum.sort(Map.keys(panes)) and pane in Map.keys(panes) do
      {:ok,
       %{
         split: split,
         panes: panes,
         pane: pane,
         tree_w: size(map["tree_w"]),
         edits_h: size(map["edits_h"])
       }}
    else
      _ -> :error
    end
  end

  def decode(_other), do: :error

  defp decode_split(%{"pane" => id}) when is_integer(id) and id > 0, do: {:ok, {:pane, id}}

  defp decode_split(%{"dir" => dir, "ratio" => ratio, "a" => a, "b" => b})
       when dir in ["rows", "cols"] and is_number(ratio) and ratio > 0 and ratio < 1 do
    with {:ok, a} <- decode_split(a),
         {:ok, b} <- decode_split(b),
         do: {:ok, {String.to_existing_atom(dir), a, b, ratio / 1}}
  end

  defp decode_split(_other), do: :error

  defp decode_panes(panes) do
    Enum.reduce_while(panes, {:ok, %{}}, fn {id, pane}, {:ok, acc} ->
      with {id, ""} when id > 0 <- Integer.parse(id),
           %{"at" => at, "tabs" => tabs} when is_integer(at) and at >= 0 and is_list(tabs) <- pane,
           {:ok, tabs} <- decode_tabs(tabs) do
        {:cont, {:ok, Map.put(acc, id, %{at: at, tabs: tabs})}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp decode_tabs(tabs) do
    Enum.reduce_while(tabs, {:ok, []}, fn
      %{"path" => path, "cursor" => [line, col], "scroll" => scroll}, {:ok, acc}
      when is_binary(path) and is_integer(line) and line >= 0 and is_integer(col) and col >= 0 and
             is_integer(scroll) and scroll >= 0 ->
        # Only absolute paths: one relative to wherever geex starts next means nothing.
        if Path.type(path) == :absolute,
          do: {:cont, {:ok, acc ++ [%{path: path, cursor: {line, col}, scroll: scroll}]}},
          else: {:halt, :error}

      _tab, _acc ->
        {:halt, :error}
    end)
  end

  defp size(n) when is_integer(n) and n > 0, do: n
  defp size(_other), do: nil

  defp ids({:pane, id}), do: [id]
  defp ids({_dir, a, b, _ratio}), do: ids(a) ++ ids(b)

  @doc "The files a saved session shows, each once, in the order its panes list them."
  @spec paths(saved()) :: [String.t()]
  def paths(%{panes: panes}) do
    panes
    |> Enum.sort()
    |> Enum.flat_map(fn {_id, p} -> Enum.map(p.tabs, & &1.path) end)
    |> Enum.uniq()
  end

  @doc """
  The panes a saved session rebuilds, given the buffers its files opened as (`pids`, path to
  pid): a file missing from `pids` is left out, a pane left with no tab goes, and its split gives
  its room to the other half. `nil` when no tab is left.

      iex> a = spawn(fn -> :ok end)
      iex> saved = %{
      ...>   split: {:cols, {:pane, 1}, {:pane, 2}, 0.3},
      ...>   panes: %{
      ...>     1 => %{at: 1, tabs: [%{path: "/gone", cursor: {0, 0}, scroll: 0}]},
      ...>     2 => %{at: 0, tabs: [%{path: "/a", cursor: {4, 2}, scroll: 3}]}
      ...>   },
      ...>   pane: 1, tree_w: nil, edits_h: nil
      ...> }
      iex> panes = Geex.LastSession.panes(saved, %{"/a" => a})
      iex> {panes.split, panes.pane, panes.next}
      {{:pane, 2}, 2, 3}
      iex> [%{buffer: ^a, cursor: {4, 2}, scroll: 3}] = panes.panes[2].tabs
      iex> Geex.LastSession.panes(saved, %{})
      nil
  """
  @spec panes(saved(), %{String.t() => pid()}) :: Panes.t() | nil
  def panes(%{split: split, panes: saved, pane: pane}, pids) do
    panes =
      for {id, %{at: at, tabs: tabs}} <- saved,
          kept = for(t <- tabs, pid = pids[t.path], do: {t, pid}),
          kept != [],
          into: %{} do
        shown = Enum.at(tabs, at)
        at = Enum.find_index(kept, fn {t, _} -> t == shown end) || 0

        {id,
         %{
           at: at,
           tabs: for({t, pid} <- kept, do: %{Panes.tab(pid, t.cursor) | scroll: t.scroll})
         }}
      end

    case prune(split, Map.keys(panes)) do
      nil ->
        nil

      split ->
        ids = ids(split)

        %{
          split: split,
          panes: panes,
          pane: if(pane in ids, do: pane, else: hd(ids)),
          next: Enum.max(ids) + 1
        }
    end
  end

  # The split without the panes not in `keep`: a split that loses a half becomes the other.
  defp prune({:pane, id} = leaf, keep), do: if(id in keep, do: leaf)

  defp prune({dir, a, b, ratio}, keep) do
    case {prune(a, keep), prune(b, keep)} do
      {nil, nil} -> nil
      {a, nil} -> a
      {nil, b} -> b
      {a, b} -> {dir, a, b, ratio}
    end
  end

  @doc "The saved session of the project at `root`, or `:none`."
  @spec read(Path.t()) :: {:ok, saved()} | :none
  def read(root) do
    with {:ok, body} <- File.read(file(root)),
         {:ok, map} <- JSON.decode(body),
         {:ok, saved} <- decode(map) do
      {:ok, saved}
    else
      _ -> :none
    end
  end

  @doc """
  Keep `map` (from `encode/4`) as the project's session. With `sizes_only: true` only the sizes
  change (`geex FILE`): the files a project session kept are left as they were, a file that
  can't be read is left alone (`{:error, :unreadable}`: a newer geex's, say), and with no file
  yet the sizes are kept with one empty pane.
  """
  @spec write(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def write(root, map, opts \\ []) do
    file = file(root)

    if opts[:sizes_only] do
      case File.read(file) do
        {:ok, body} ->
          with {:ok, kept} <- JSON.decode(body),
               {:ok, _} <- decode(kept) do
            put(file, Map.merge(kept, Map.take(map, ["tree_w", "edits_h"])))
          else
            _ -> {:error, :unreadable}
          end

        {:error, :enoent} ->
          put(
            file,
            Map.merge(map, %{
              "split" => %{"pane" => 1},
              "pane" => 1,
              "panes" => %{"1" => %{"at" => 0, "tabs" => []}}
            })
          )

        {:error, _reason} = error ->
          error
      end
    else
      put(file, map)
    end
  end

  # Private, whole or not at all (a temp file renamed, after an fsync), as the minibuffer's
  # history is written. The temp file is removed if anything fails after it was made.
  defp put(file, map) do
    dir = Path.dirname(file)
    tmp = file <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, body} <- encode_json(map),
         {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]) do
      result =
        try do
          with :ok <- File.chmod(tmp, 0o600),
               :ok <- IO.binwrite(io, body),
               :ok <- :file.sync(io),
               do: :ok
        after
          File.close(io)
        end

      with :ok <- result, :ok <- File.rename(tmp, file) do
        :ok
      else
        error ->
          File.rm(tmp)
          error
      end
    end
  end

  defp encode_json(map) do
    {:ok, JSON.encode!(map)}
  rescue
    e -> {:error, {:encode, Exception.message(e)}}
  end

  @doc """
  A writer for the loop `reply_to`: a process that keeps the sessions it is sent, one at a time,
  in order (`keep/4`, `keep_now/5`), and sends `reply_to` `{:geex_session_written, map, result}`
  after each.
  """
  @spec writer(pid()) :: pid()
  def writer(reply_to) do
    spawn(fn ->
      # Gone with its loop (a restarted loop starts its own).
      Process.monitor(reply_to)
      write_loop(reply_to, :ok)
    end)
  end

  @doc "Send `writer` a session to keep; it answers the loop when it is written."
  @spec keep(pid(), Path.t(), map(), keyword()) :: :ok
  def keep(writer, root, map, opts) do
    send(writer, {:keep, root, map, opts, nil})
    :ok
  end

  @doc """
  Keep a session and wait for it (a quit), at most `timeout` ms: it is written after everything
  sent before it. Returns the write's result, or `{:error, :timeout}`.
  """
  @spec keep_now(pid(), Path.t(), map(), keyword(), timeout()) :: :ok | {:error, term()}
  def keep_now(writer, root, map, opts, timeout) do
    ref = make_ref()
    send(writer, {:keep, root, map, opts, {self(), ref}})

    receive do
      {:geex_session_kept, ^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  # `last` is the previous write's result, so a failure is logged once until it changes.
  defp write_loop(reply_to, last) do
    receive do
      {:keep, root, map, opts, ack} ->
        result =
          try do
            write(root, map, opts)
          rescue
            e -> {:error, Exception.message(e)}
          end

        if result != :ok and result != last,
          do: Logger.warning("geex session: couldn't keep #{root}'s: #{inspect(result)}")

        send(reply_to, {:geex_session_written, map, result})
        with {pid, ref} <- ack, do: send(pid, {:geex_session_kept, ref, result})
        write_loop(reply_to, result)

      {:DOWN, _ref, :process, ^reply_to, _reason} ->
        :ok
    end
  end
end
