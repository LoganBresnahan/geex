defmodule Geex.Loop.SaveFlag do
  @moduledoc """
  How a save off the key loop and a cancel agree, with no message between them (ADR-0035's
  2026-11-15 amendment): one atomics cell the loop and the save's process share.

  The save calls `write?/1` just before each file's write begins (`Geex.Buffer.save/2`'s gate)
  and `done/1` once that file is answered; the loop calls `cancel/1`. While no write is under
  way the cancel takes the cell: the save begins no write from there, and starts no more files;
  while a write is under way the cancel waits, the write finishes, and the save stops after it.
  So a cancel never cuts a write short.

      iex> flag = Geex.Loop.SaveFlag.new()
      iex> Geex.Loop.SaveFlag.write?(flag)
      :ok
      iex> Geex.Loop.SaveFlag.cancel(flag)
      :writing
      iex> Geex.Loop.SaveFlag.done(flag)
      :stop
  """

  @idle 0
  @writing 1
  @cancelled 2
  @cancel_waits 3

  @opaque t :: :atomics.atomics_ref()

  @doc "A cell for one save: idle."
  @spec new() :: t()
  def new, do: :atomics.new(1, signed: false)

  @doc """
  Just before a file's write begins: `:ok`, writing from here on, or `:cancelled`. The same
  file again (it changed on disk before its write began, so the save goes round once more) is
  still `:ok`, unless a cancel came meanwhile: nothing was written yet, so it stops there.

      iex> flag = Geex.Loop.SaveFlag.new()
      iex> Geex.Loop.SaveFlag.cancel(flag)
      :cancelled
      iex> Geex.Loop.SaveFlag.write?(flag)
      :cancelled
  """
  @spec write?(t()) :: :ok | :cancelled
  def write?(flag) do
    case :atomics.compare_exchange(flag, 1, @idle, @writing) do
      :ok ->
        :ok

      @writing ->
        :ok

      @cancel_waits ->
        :atomics.put(flag, 1, @cancelled)
        :cancelled

      @cancelled ->
        :cancelled
    end
  end

  @doc """
  A file is answered: `:go` on to the next (idle again), or `:stop`, a cancel having come.

      iex> flag = Geex.Loop.SaveFlag.new()
      iex> Geex.Loop.SaveFlag.write?(flag)
      :ok
      iex> Geex.Loop.SaveFlag.done(flag)
      :go
      iex> Geex.Loop.SaveFlag.cancel(flag)
      :cancelled
  """
  @spec done(t()) :: :go | :stop
  def done(flag) do
    case :atomics.compare_exchange(flag, 1, @writing, @idle) do
      # Idle again; or the file never got as far as its write.
      result when result in [:ok, @idle] -> :go
      _cancelled -> :stop
    end
  end

  @doc """
  Whether a cancel has taken the cell: the save starts no more files.

      iex> flag = Geex.Loop.SaveFlag.new()
      iex> Geex.Loop.SaveFlag.cancelled?(flag)
      false
      iex> Geex.Loop.SaveFlag.cancel(flag)
      :cancelled
      iex> Geex.Loop.SaveFlag.cancelled?(flag)
      true
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(flag), do: :atomics.get(flag, 1) == @cancelled

  @doc """
  Cancel the save: `:cancelled` when no write is under way (the cell is taken: the save writes
  nothing more), `:writing` when one is (it finishes, and the save stops after it), and
  `:writing` again for a cancel already waiting.
  """
  @spec cancel(t()) :: :cancelled | :writing
  def cancel(flag) do
    case :atomics.compare_exchange(flag, 1, @idle, @cancelled) do
      :ok ->
        :cancelled

      @writing ->
        case :atomics.compare_exchange(flag, 1, @writing, @cancel_waits) do
          :ok -> :writing
          # The write was answered just then: take the idle cell instead.
          _ -> cancel(flag)
        end

      @cancelled ->
        :cancelled

      @cancel_waits ->
        :writing
    end
  end
end
