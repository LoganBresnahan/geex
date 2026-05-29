defmodule Geex.Buffer do
  @moduledoc """
  One process per open file. Owns the text data structure (lines as
  binaries, stored in an `:array` for v0.1) and tracks the path / dirty
  flag.

  v0.1 stub: starts under `Geex.BufferSupervisor`, holds placeholder
  state. Load/save/edit operations come next.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{
      path: Keyword.get(opts, :path),
      lines: :array.new(),
      dirty: false
    }

    {:ok, state}
  end
end
