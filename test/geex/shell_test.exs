defmodule Geex.ShellTest do
  # The runner against real `sh` (ADR-0042): output, exit, env, cwd, the `|` pipe, stopping the
  # whole process group, and a program that wants the alternate screen.
  use ExUnit.Case, async: true

  alias Geex.Shell

  doctest Geex.Shell.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "geex_shell_#{Geex.Fixtures.uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # The lines of a `!`, in order, each ended with a newline, and how it ended. The unfinished
  # line each batch carries is shown, not kept: the command's end sends it as a line.
  defp collect(pid, acc \\ []) do
    receive do
      {:geex_shell, ^pid, {:lines, lines, _partial}} -> collect(pid, acc ++ lines)
      {:geex_shell, ^pid, :needs_tty} -> collect(pid, acc ++ ["<needs_tty>"])
      {:geex_shell, ^pid, {:exit, status}} -> {Enum.map_join(acc, &(&1 <> "\n")), status}
    after
      10_000 -> flunk("no exit from the command")
    end
  end

  test "`!`: stdout and stderr together, the exit status, in the directory given", %{dir: dir} do
    {pid, _ref} = Shell.start("pwd; echo out; echo err >&2; exit 3", cwd: dir)
    {out, 3} = collect(pid)
    assert out =~ "#{Path.basename(dir)}\nout\nerr\n"
  end

  test "no terminal: stdin is empty, TERM is dumb, the pagers are cat", %{dir: dir} do
    {pid, _ref} = Shell.start(~s|cat; echo "$TERM $PAGER $GIT_PAGER"; tty|, cwd: dir)
    {out, _status} = collect(pid)
    assert out =~ "dumb cat cat\n"
    assert out =~ "not a tty"
  end

  test "stop/1 ends the whole process group, children too", %{dir: dir} do
    # A sleep no other process runs, started by a child shell of the command's.
    secs = 3000 + rem(System.unique_integer([:positive]), 5000)
    {pid, _ref} = Shell.start("sh -c 'sleep #{secs}' & echo started; wait", cwd: dir)
    assert_receive {:geex_shell, ^pid, {:lines, ["started"], ""}}, 5_000
    {ps, _} = System.cmd("ps", ["-eo", "args"])
    assert ps =~ "sleep #{secs}"

    Shell.stop(pid)
    {_out, status} = collect(pid)
    assert status == 128 + 15

    Process.sleep(100)
    {ps, _} = System.cmd("ps", ["-eo", "args"])
    refute ps =~ "sleep #{secs}"
  end

  test "a program that switches to the alternate screen is stopped", %{dir: dir} do
    {pid, _ref} = Shell.start(~S|printf 'x\033[?10'; printf '49h'; sleep 30|, cwd: dir)
    {out, status} = collect(pid)
    assert out =~ "<needs_tty>"
    assert status == 128 + 15
  end

  test "a flood arrives in a few bounded batches, the newest lines kept", %{dir: dir} do
    {pid, _ref} = Shell.start("seq 1 300000", cwd: dir, keep: 100)

    batches =
      Stream.repeatedly(fn ->
        receive do
          {:geex_shell, ^pid, {:lines, lines, _}} -> lines
          {:geex_shell, ^pid, {:exit, 0}} -> :done
        after
          10_000 -> flunk("no exit")
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    assert Enum.all?(batches, &(length(&1) <= 100))
    assert length(batches) < 100
    assert List.last(List.last(batches)) == "300000"
  end

  test "when chunks are passed over, the output's last lines still arrive", %{dir: dir} do
    # `behind: -1`: every chunk counts as behind, as on a loaded machine.
    {pid, _ref} = Shell.start("seq 1 300000", cwd: dir, behind: -1)
    {out, 0} = collect(pid)
    assert String.ends_with?(out, "299999\n300000\n")
  end

  test "an unfinished line is shown as it stands, and ends as a line", %{dir: dir} do
    {pid, _ref} = Shell.start("printf 'half'; sleep 0.3; printf ' done'", cwd: dir)
    assert_receive {:geex_shell, ^pid, {:lines, [], "half"}}, 5_000
    assert {"half done\n", 0} = collect(pid)
  end

  test "`|`: the input on stdin, stdout and stderr apart", %{dir: dir} do
    {pid, _ref} = Shell.start("sort; echo note >&2", cwd: dir, input: "b\na\n")
    assert_receive {:geex_shell, ^pid, {:piped, 0, "a\nb\n", "note\n"}}, 10_000
  end

  # Measured 2026-10-19: under `yes`, 76–610 chunks wait on an idle machine, level over 10 s;
  # under the full suite's load up to 9,943 before the cap. Without the drop it grew by
  # thousands a second.
  test "a flood the runner can't keep up with stays bounded", %{dir: dir} do
    sink = spawn(fn -> Process.sleep(:infinity) end)
    {pid, ref} = Shell.start("yes geex", cwd: dir, owner: sink)

    waiting =
      for _ <- 1..2 do
        Process.sleep(1_000)

        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} -> n
          nil -> 0
        end
      end

    Shell.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    # 2,048 is the cap; a check can land while the runner is stopping the command.
    assert Enum.all?(waiting, &(&1 < 2_600)), "chunks waiting: #{inspect(waiting)}"
  end

  test "past the cap the command is stopped, and says why", %{dir: dir} do
    {pid, _ref} = Shell.start("yes geex", cwd: dir, overflow: 1)
    assert_receive {:geex_shell, ^pid, :overflow}, 10_000
    assert {_out, 143} = collect(pid)
  end

  test "`|`: stdout past the cap stops the command", %{dir: dir} do
    {pid, _ref} = Shell.start("yes", cwd: dir, input: "", max_piped: 100_000)
    assert_receive {:geex_shell, ^pid, {:piped, 143, :too_big, ""}}, 10_000
  end

  test "`|`: a failure keeps its status and stderr, and the temp files go", %{dir: dir} do
    before = File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "geex-pipe-"))
    {pid, ref} = Shell.start("echo nope >&2; exit 2", cwd: dir, input: "x")
    assert_receive {:geex_shell, ^pid, {:piped, 2, "", "nope\n"}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    left = File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "geex-pipe-"))
    assert left -- before == []
  end
end
