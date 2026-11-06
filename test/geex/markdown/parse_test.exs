defmodule Geex.Markdown.ParseTest do
  # Spike (the markdown preview, ADR-0043 to come): the pure tree builder's example. Parsing
  # itself needs the Markdown grammars, which the test fixtures don't carry yet.
  use ExUnit.Case, async: true
  doctest Geex.Markdown.Parse
end
