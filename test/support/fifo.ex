defmodule Geex.Fifo do
  @moduledoc """
  Tests: a FIFO in a file's place, the stand-in for a disk whose read never returns (BUG-21,
  BUG-22). Opening one to read waits for a writer; `release/1` is that writer, so a read left
  waiting (a regression, or a test holding OTP's file server on purpose) ends.
  """

  @doc "Make a FIFO at `path`, replacing a file there."
  @spec make!(Path.t()) :: Path.t()
  def make!(path) do
    _ = File.rm(path)
    {_, 0} = System.cmd("mkfifo", [path])
    path
  end

  @doc """
  End a read waiting on the FIFO at `path`: a shell opens it read-write (on Linux that never
  waits, and counts as a writer) and closes it, so the read gets its end of file. Through
  `/bin/sh` by its full path, which doesn't look the program up through the file server: the
  file server may be the one waiting.
  """
  @spec release(Path.t()) :: :ok
  def release(path) do
    {_, _} = System.cmd("/bin/sh", ["-c", ~s|: 1<>"$0"|, path])
    :ok
  end

  @doc """
  Run `fun` in a process of its own and give its answer, or `:waited` if it hasn't answered in
  `ms` (the FIFO at `fifo` then released, so it ends).
  """
  @spec within(Path.t(), non_neg_integer(), (-> term())) :: term()
  def within(fifo, ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, ms) do
      {:ok, answer} ->
        answer

      nil ->
        release(fifo)
        Task.shutdown(task, 1_000)
        :waited
    end
  end
end
