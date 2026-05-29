defmodule Geex.BufferSupervisor do
  @moduledoc """
  DynamicSupervisor for `Geex.Buffer` processes — one child per open file.

  In v0.1 only one buffer is opened at a time, but the DynamicSupervisor
  shape means v0.2 (multi-buffer) is a single `start_buffer/1` call away,
  with no restructuring.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_buffer(path) do
    DynamicSupervisor.start_child(__MODULE__, {Geex.Buffer, path: path})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
