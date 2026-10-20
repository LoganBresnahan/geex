defmodule Geex.Shell do
  @moduledoc """
  Runs a shell command for the minibuffer's `!` and `|` ([ADR-0042](../../doc/adr/0042-shell-commands.md)),
  each in a process of its own, so the key loop never waits on one
  ([ADR-0035](../../doc/adr/0035-the-loop-never-waits.md)).

  The command runs as `sh -c COMMAND` in the directory given (the project root), with no
  terminal: stdin is `/dev/null` (for `!`) or the selection (for `|`), and stdout and stderr are
  pipes. `TERM=dumb`, `PAGER=cat` and `GIT_PAGER=cat` keep programs from drawing or paging.

  **Its own process group.** The VM starts every port program in a new session
  (`erl_child_setup` calls `setsid()`), so the shell's pid is its group's id and everything the
  command starts is in that group. `stop/1` sends the group TERM, then KILL two seconds later
  if it is still there.

  **A program that wants a terminal** (it switches to the alternate screen) is stopped the same
  way, and the owner hears `:needs_tty`.

  **Output in batches.** A `!`'s output is split into lines and cleaned here, not by the owner:
  at most every 50 ms the owner gets the lines since the last batch (the newest 5,000 when there
  were more; `:keep` changes it) and the unfinished line as it stands. A flood costs this process,
  never the key loop.

  The owner gets, for a `!` (`start/2` without `:input`):

      {:geex_shell, pid, {:lines, lines, partial}}  # stdout and stderr together, cleaned
                                                     # (`Geex.Shell.Text.clean/1`), in batches
      {:geex_shell, pid, :needs_tty}
      {:geex_shell, pid, :overflow}            # it printed faster than it could be read: stopped
      {:geex_shell, pid, {:exit, status}}      # 128 + n when signal n ended it

  and for a `|` (with `:input`), once:

      {:geex_shell, pid, {:piped, status, stdout | :too_big, stderr}}  # stderr's first 64 KB
      {:geex_shell, pid, :needs_tty}           # then {:piped, …} as it ends
  """

  alias Geex.Shell.Text

  @grace_ms 2_000
  @flush_ms 50
  # The most of an unfinished line kept: a command printing without newlines can't grow it
  # without end.
  @max_partial 65_536
  # Chunks waiting in the runner's mailbox past which it drops them instead of splitting them.
  @behind 64
  # Chunks waiting past which a `!` is stopped (about 128 MB): see `drain/3`.
  @overflow 2048
  # The most a `|` command's stdout may be: past it the command is stopped.
  @max_piped 64 * 1024 * 1024
  @env [{~c"TERM", ~c"dumb"}, {~c"PAGER", ~c"cat"}, {~c"GIT_PAGER", ~c"cat"}]

  @doc """
  Start `cmd` in a monitored process; returns `{pid, monitor}`. Options: `:cwd` (default the
  working directory), `:input` (the text for a `|`; without it, a `!`), `:owner` (default the
  caller), `:grace_ms`.
  """
  @spec start(String.t(), keyword()) :: {pid(), reference()}
  def start(cmd, opts \\ []) when is_binary(cmd) do
    owner = Keyword.get(opts, :owner, self())
    spawn_monitor(fn -> run(cmd, owner, opts) end)
  end

  @doc "Stop the command: its process group gets TERM, then KILL after the grace period."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    send(pid, :stop)
    :ok
  end

  defp run(cmd, owner, opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    grace = Keyword.get(opts, :grace_ms, @grace_ms)

    case Keyword.fetch(opts, :input) do
      {:ok, input} ->
        pipe(cmd, input, cwd, owner, grace, Keyword.get(opts, :max_piped, @max_piped))

      :error ->
        show(cmd, cwd, owner, opts)
    end
  end

  # A `!`: the output is split into lines here, and only the newest `keep` lines waiting are
  # kept; every `@flush_ms` the waiting lines go to the owner, cleaned, with the unfinished one.
  # However much the command prints, the owner gets a few batches a second, each bounded.
  defp show(cmd, cwd, owner, opts) do
    port = open(~s|exec sh -c "$1" </dev/null|, [cmd], cwd, [:stderr_to_stdout])

    run = %{
      port: port,
      os: os_pid(port),
      owner: owner,
      grace: Keyword.get(opts, :grace_ms, @grace_ms),
      keep: Keyword.get(opts, :keep, 5000),
      overflow: Keyword.get(opts, :overflow, @overflow),
      behind: Keyword.get(opts, :behind, @behind),
      switches: Text.alt_screen_pattern(),
      tail: "",
      stopped?: false,
      # Complete lines waiting, newest first, and how many; the unfinished line; the flush timer.
      lines: [],
      count: 0,
      partial: "",
      timer: nil,
      # After chunks were passed over (`drain/3`), the next one starts mid-line.
      resync: false
    }

    status = show_loop(run)
    send(owner, {:geex_shell, self(), {:exit, status}})
  end

  defp show_loop(%{port: port} = run) do
    receive do
      {^port, {:data, _}} when run.stopped? ->
        show_loop(run)

      {^port, {:data, data}} ->
        waiting = queued()

        cond do
          alt_screen?(run, data) ->
            show_loop(stop_for(run, :needs_tty))

          waiting > run.overflow ->
            show_loop(stop_for(run, :overflow))

          waiting > run.behind ->
            case drain(%{run | tail: next_tail(run.tail, data)}, data, waiting) do
              {:ok, run, newest} -> show_loop(take(%{run | partial: "", resync: true}, newest))
              {:tty, run} -> show_loop(stop_for(run, :needs_tty))
              {:overflow, run} -> show_loop(stop_for(run, :overflow))
            end

          true ->
            show_loop(take(run, data))
        end

      :flush ->
        show_loop(flush(%{run | timer: nil}))

      {^port, {:exit_status, status}} ->
        flush(%{run | lines: finished(run), count: run.count + 1, partial: ""})
        status

      msg ->
        handle_stop(msg, run.os, run.grace)
        show_loop(run)
    end
  end

  # The waiting lines, with the unfinished one ended (when there is one) as the command ends.
  defp finished(%{partial: "", lines: lines}), do: lines
  defp finished(%{partial: partial, lines: lines}), do: [partial | lines]

  # Stop the command, and tell the owner why: `:needs_tty` (the alternate screen) or `:overflow`.
  defp stop_for(run, why) do
    send(run.owner, {:geex_shell, self(), why})
    stop_group(run.os, run.grace)
    %{run | stopped?: true}
  end

  defp queued do
    {:message_queue_len, n} = Process.info(self(), :message_queue_len)
    n
  end

  # The command writes faster than lines can be split. A port can't be told to read slower, so
  # the chunks waiting are passed over, checked only for the alternate screen, and only the
  # newest is split, from its first whole line: the latest lines are what's kept anyway, and the
  # output's end (a test run's summary) is never lost. Should the chunks still pile up past
  # `overflow` (a loaded machine), the command is stopped: its memory stays bounded. That is
  # checked at every chunk here too, so a long drain can't carry the mailbox past it.
  defp drain(run, newest, 0), do: {:ok, run, newest}

  defp drain(%{port: port} = run, newest, n) do
    receive do
      {^port, {:data, data}} ->
        cond do
          alt_screen?(run, data) -> {:tty, run}
          queued() > run.overflow -> {:overflow, run}
          true -> drain(%{run | tail: next_tail(run.tail, data)}, data, n - 1)
        end
    after
      0 -> {:ok, run, newest}
    end
  end

  defp take(%{resync: true} = run, data) do
    case :binary.split(data, "\n") do
      [_fragment, rest] -> take(%{run | resync: false}, rest)
      [_fragment] -> %{run | tail: next_tail(run.tail, data)}
    end
  end

  defp take(run, data) do
    [partial | done] = :binary.split(run.partial <> data, "\n", [:global]) |> Enum.reverse()
    partial = tail_bytes(partial, @max_partial)
    count = run.count + length(done)
    {lines, count} = cap(done ++ run.lines, count, run.keep)
    timer = run.timer || Process.send_after(self(), :flush, @flush_ms)
    tail = next_tail(run.tail, data)
    %{run | lines: lines, count: count, partial: partial, timer: timer, tail: tail}
  end

  # Kept to `keep` lines, the newest; trimmed only once twice over, so a flood isn't trimmed on
  # every chunk.
  defp cap(lines, count, keep) when count > 2 * keep, do: {Enum.take(lines, keep), keep}
  defp cap(lines, count, _keep), do: {lines, count}

  defp flush(%{lines: [], partial: ""} = run), do: run

  defp flush(run) do
    lines = run.lines |> Enum.take(run.keep) |> Enum.reverse() |> Enum.map(&Text.clean/1)
    send(run.owner, {:geex_shell, self(), {:lines, lines, Text.clean(run.partial)}})
    %{run | lines: [], count: 0}
  end

  defp pipe(cmd, input, cwd, owner, grace, max) do
    dir = System.tmp_dir!()
    tag = "geex-pipe-#{System.os_time()}-#{System.unique_integer([:positive])}"
    {infile, errfile} = {Path.join(dir, tag <> ".in"), Path.join(dir, tag <> ".err")}

    try do
      :ok = private_file(infile, input)
      :ok = private_file(errfile, "")
      script = ~s|exec sh -c "$1" <"$2" 2>"$3"|
      port = open(script, [cmd, infile, errfile], cwd, [])
      run = %{port: port, os: os_pid(port), owner: owner, grace: grace, tail: "", max: max}
      run = Map.put(run, :switches, Text.alt_screen_pattern())
      {status, out} = pipe_loop(run, [], 0, false)
      send(owner, {:geex_shell, self(), {:piped, status, out, read_head(errfile, 65_536)}})
    after
      File.rm(infile)
      File.rm(errfile)
    end
  end

  # Collects stdout. Past `max` bytes (64 MB, or `:max_piped`) the command is stopped and `out`
  # is `:too_big`.
  defp pipe_loop(%{port: port} = run, acc, size, stopped?) do
    receive do
      {^port, {:data, _}} when stopped? != false ->
        pipe_loop(run, acc, size, stopped?)

      {^port, {:data, data}} ->
        cond do
          alt_screen?(run, data) ->
            send(run.owner, {:geex_shell, self(), :needs_tty})
            stop_group(run.os, run.grace)
            pipe_loop(run, acc, size, :tty)

          size + byte_size(data) > run.max ->
            stop_group(run.os, run.grace)
            pipe_loop(run, [], 0, :too_big)

          true ->
            run = %{run | tail: next_tail(run.tail, data)}
            pipe_loop(run, [acc | data], size + byte_size(data), stopped?)
        end

      {^port, {:exit_status, status}} ->
        {status, if(stopped? == :too_big, do: :too_big, else: IO.iodata_to_binary(acc))}

      msg ->
        handle_stop(msg, run.os, run.grace)
        pipe_loop(run, acc, size, stopped?)
    end
  end

  # The first `n` bytes of a file (stderr can be long; what is shown is its start).
  defp read_head(path, n) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        data = IO.binread(io, n)
        File.close(io)
        if is_binary(data), do: data, else: ""

      _ ->
        ""
    end
  end

  defp handle_stop(:stop, os, grace), do: stop_group(os, grace)
  defp handle_stop({:hard_stop, os}, os, _grace), do: signal(os, "KILL")
  defp handle_stop(_other, _os, _grace), do: :ok

  # The TERM is sent from a process of its own: starting `sh` takes a while on a loaded machine,
  # and meanwhile the runner keeps passing over the command's output instead of letting it pile up.
  defp stop_group(os, grace) do
    spawn(fn -> signal(os, "TERM") end)
    Process.send_after(self(), {:hard_stop, os}, grace)
  end

  # The shell's pid, or nil when it has already ended (its output and exit status are in the
  # mailbox): then there is nothing left to signal.
  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os} -> os
      nil -> nil
    end
  end

  # The group's id is the shell's pid (see the moduledoc). The shell's own `kill`, so it is the
  # same on every system.
  defp signal(nil, _sig), do: :ok

  defp signal(os, sig) do
    System.cmd("sh", ["-c", ~s|kill -s "$0" -- "-$1" 2>/dev/null|, sig, to_string(os)])
  end

  defp open(script, args, cwd, extra) do
    sh = System.find_executable("sh") || "/bin/sh"

    args = ["-c", script, "sh" | args]
    options = [:binary, :exit_status, :use_stdio, :hide, cd: cwd, env: @env, args: args]
    Port.open({:spawn_executable, sh}, options ++ extra)
  end

  # The alternate-screen switch in `data`, or across the boundary with the bytes before it; no
  # copy of the whole chunk.
  defp alt_screen?(%{tail: tail, switches: switches}, data) do
    n = Text.overlap()
    head = if byte_size(data) > n, do: binary_part(data, 0, n), else: data
    :binary.match(data, switches) != :nomatch or :binary.match(tail <> head, switches) != :nomatch
  end

  # The last bytes seen, for the next boundary.
  defp next_tail(tail, data) do
    n = Text.overlap()
    if byte_size(data) >= n, do: tail_bytes(data, n), else: tail_bytes(tail <> data, n)
  end

  defp tail_bytes(data, n) when byte_size(data) > n, do: binary_part(data, byte_size(data) - n, n)
  defp tail_bytes(data, _n), do: data

  # Made empty and private before anything is written to it.
  defp private_file(path, content) do
    with {:ok, io} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(path, 0o600) do
      IO.binwrite(io, content)
      File.close(io)
    end
  end
end
