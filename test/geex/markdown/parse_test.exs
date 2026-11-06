defmodule Geex.Markdown.ParseTest do
  # The markdown preview's parser (ADR-0043 §4): the pure tree builder's and the queries'
  # examples. Parsing with the fixture grammars is in markdown_test.exs.
  use ExUnit.Case, async: true
  doctest Geex.Markdown.Parse
end
