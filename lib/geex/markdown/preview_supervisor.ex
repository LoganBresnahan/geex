defmodule Geex.Markdown.PreviewSupervisor do
  @moduledoc """
  DynamicSupervisor for `Geex.Markdown.Preview` processes, one per buffer with a markdown
  preview open ([ADR-0043](../../../doc/adr/0043-markdown-preview.md) §3). Beside
  `Geex.Highlight.ReactorSupervisor`, started before the loop, cheap when empty. A preview is
  `:temporary`: it monitors its buffer and its subscribers and stops with the last of them, so
  it is never restarted here.
  """

  use DynamicSupervisor

  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 1024)
end
