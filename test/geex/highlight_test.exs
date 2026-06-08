defmodule Geex.HighlightTest do
  use ExUnit.Case, async: true

  alias Geex.Highlight
  alias Geex.Highlight.Span

  describe "spans/2 — bundled grammars through the tree-sitter-on-wasm engine" do
    test "json: returns capture spans tagged with capture names" do
      src = ~s({"n": 42, "s": "hi"})
      assert {:ok, spans} = Highlight.spans(src, "json")
      assert spans != []
      assert Enum.all?(spans, &match?(%Span{}, &1))

      caps = MapSet.new(spans, & &1.capture)
      assert "number" in caps
      assert "string" in caps

      # Spans index real byte slices of the source (no colour anywhere here).
      assert Enum.any?(spans, fn s ->
               s.capture == "number" and binary_part(src, s.start_byte, s.end_byte - s.start_byte) == "42"
             end)
    end

    test "elixir (dogfood): keyword/comment/string captures from real code" do
      src = """
      defmodule Foo do
        # a comment
        def bar(x), do: x + "y"
      end
      """

      assert {:ok, spans} = Highlight.spans(src, "elixir")
      caps = MapSet.new(spans, & &1.capture)
      assert "keyword" in caps
      assert "comment" in caps
      assert "string" in caps

      assert Enum.any?(spans, fn s ->
               s.capture == "comment" and
                 String.starts_with?(binary_part(src, s.start_byte, s.end_byte - s.start_byte), "#")
             end)
    end

    test "spans are well-formed: ordered, non-empty byte ranges, binary captures" do
      {:ok, spans} = Highlight.spans(~s({"k": [true, null]}), "json")

      assert Enum.all?(spans, fn %Span{start_byte: s, end_byte: e, capture: c} ->
               is_integer(s) and is_integer(e) and s < e and is_binary(c)
             end)
    end

    test "unknown language is a tagged error, not a crash" do
      assert {:error, {:unknown_language, "ruby"}} = Highlight.spans("puts 1", "ruby")
    end

    test "empty source yields an ok result (no spans)" do
      assert {:ok, []} = Highlight.spans("", "json")
    end
  end
end
