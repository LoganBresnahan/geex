defmodule Geex.Highlight.GrammarsCacheTest do
  # Where compiled grammars are cached (ADR-0040 §8). Changes the app env and XDG_CACHE_HOME,
  # so not async.
  use ExUnit.Case, async: false

  alias Geex.Highlight.Grammars

  setup do
    xdg = System.get_env("XDG_CACHE_HOME")

    on_exit(fn ->
      Application.put_env(:geex, :wasm_cache, false)
      if xdg, do: System.put_env("XDG_CACHE_HOME", xdg), else: System.delete_env("XDG_CACHE_HOME")
    end)
  end

  test "off under test; otherwise $XDG_CACHE_HOME/geex/wasm, or ~/.cache/geex/wasm" do
    assert Grammars.cache_dir() == nil

    Application.put_env(:geex, :wasm_cache, true)
    System.put_env("XDG_CACHE_HOME", "/somewhere/cache")
    assert Grammars.cache_dir() == "/somewhere/cache/geex/wasm"

    System.put_env("XDG_CACHE_HOME", "")
    assert Grammars.cache_dir() == Path.expand("~/.cache/geex/wasm")
  end
end
