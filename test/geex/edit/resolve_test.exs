defmodule Geex.Edit.ResolveTest do
  use ExUnit.Case, async: true

  alias Geex.Buffer.Doc
  alias Geex.Edit.Resolve

  # The value-add is the coordinate span; prove resolve + Doc.replace equals the obvious
  # string substitution for unique matches — including UTF-8 (the grapheme off-by-one risk).
  defp applied(text, search, replace) do
    {:ok, span, repl} = Resolve.resolve_block(text, search, replace)
    {:ok, doc} = Doc.replace(Doc.new(text), span, repl)
    Doc.text(doc)
  end

  defp random_string(_alphabet, 0), do: ""
  defp random_string(alphabet, n), do: Enum.map_join(1..n, "", fn _ -> Enum.random(alphabet) end)

  describe "tier 1 — exact-unique substring" do
    test "mid-line replace" do
      assert applied("hello world", "world", "there") == "hello there"
    end

    test "multi-line replace" do
      assert applied("foo\nbar\nbaz", "bar\nbaz", "X\nY") == "foo\nX\nY"
    end

    test "delete (empty replacement)" do
      assert applied("keep\ndrop me\nkeep", "drop me\n", "") == "keep\nkeep"
    end

    test "grapheme-correct against multi-byte text (matches naive String.replace)" do
      for {text, s, r} <- [
            {"café crème", "crème", "X"},
            {"café crème déjà", "crème", "TEA"},
            {"αβγ δεζ", "δεζ", "ω"},
            {"emoji 😀 here", "😀", "!"}
          ] do
        assert applied(text, s, r) == String.replace(text, s, r, global: false)
      end
    end

    test "more than one occurrence is :ambiguous (stricter than Moby)" do
      assert Resolve.resolve_block("x = 1\nx = 1", "x = 1", "y = 2") == {:error, :ambiguous}
    end

    test "a self-overlapping search counts as ambiguous, not a unique hit" do
      # "end\nend" occurs twice (overlapping) in "end\nend\nend"; String.split would
      # undercount to 1 — must refuse rather than silently edit the first.
      assert Resolve.resolve_block("  foo\n  end\nend\nend", "end\nend", "X") ==
               {:error, :ambiguous}

      assert Resolve.resolve_block("aaa", "aa", "Z") == {:error, :ambiguous}
    end

    test "an exact-unique match wins even when a trimmed variant exists elsewhere" do
      # "  a" is a unique verbatim substring; its trimmed form "a" also matches line 2,
      # but the exact tier resolves the verbatim hit precisely (no ambiguity).
      assert applied("  a\na", "  a", "Z") == "Z\na"
    end
  end

  describe "tier 2 — whitespace-normalized line window with re-indentation" do
    test "matches lines ignoring indentation and re-indents the replacement to the file" do
      # search has no leading indent, so it is not an exact substring of the indented
      # file lines -> tier 2 matches the trimmed window and re-indents the replacement.
      text = "    foo()\n    bar()"
      assert applied(text, "foo()\nbar()", "baz()\nqux()") == "    baz()\n    qux()"
    end

    test "preserves the replacement's relative indentation, rebased onto the file indent" do
      # file is 2-space-indented; search is flush-left (forces tier 2); the replacement's
      # 2-space relative nesting is rebased onto the file's indent -> 4 spaces.
      assert applied("  foo\n  bar", "foo\nbar", "foo\n  nested") == "  foo\n    nested"
    end

    test "a single-line window whose only difference is indentation resolves" do
      # "    beta" (4 leading) is not a substring of the file's "  beta" (2 leading), so
      # the exact tier misses and tier 2 matches the trimmed line.
      assert applied("alpha\n  beta\ngamma", "    beta", "BETA") == "alpha\n  BETA\ngamma"
    end

    test "more than one normalized window is :ambiguous" do
      assert Resolve.resolve_block("  a\nb\n\na\nb", "a\nb", "Z") == {:error, :ambiguous}
    end

    test "preserves CRLF line endings (an LF search against a CRLF buffer stays CRLF)" do
      # Doc splits only on \n, so a CRLF buffer carries \r as line content; an LF-quoting
      # model routes through tier 2, which must not silently flip the file to LF.
      assert applied("line one\r\nline two\r\nline three", "line one\nline two", "AAA\nBBB") ==
               "AAA\r\nBBB\r\nline three"
    end

    test "re-indents under a tab-indented file (relative spaces rebased onto the tab)" do
      assert applied("\tfoo()\n\tbar()", "foo()\nbar()", "baz()\n  nested()") ==
               "\tbaz()\n\t  nested()"
    end

    test "an over-indented replacement clamps (no negative indent), not a crash" do
      # search is flush-left (forces tier 2 over the 2-indent file); the replacement's
      # continuation "y" is *less* indented than its first line "  x" -> relative clamps to 0.
      assert applied("  a\n  b", "a\nb", "  x\ny") == "  x\n  y"
    end
  end

  describe "grapheme-correctness property (the riskiest assumption: offset <-> {row,col})" do
    test "exact-unique resolve + Doc.replace == naive String.replace, over random UTF-8 inputs" do
      # seeded for determinism (tests may use :rand; app code must not)
      :rand.seed(:exsss, {17, 23, 42})
      alphabet = ["a", "b", "c", "x", "y", " ", "\n", "\n", "é", "λ", "😀", "\t", "ü"]

      asserted =
        Enum.reduce(1..400, 0, fn _, count ->
          text = random_string(alphabet, :rand.uniform(40))
          graphemes = String.graphemes(text)
          len = length(graphemes)

          if len < 2 do
            count
          else
            start = :rand.uniform(len) - 1
            take = :rand.uniform(min(len - start, 12))
            search = graphemes |> Enum.slice(start, take) |> Enum.join()
            replace = random_string(alphabet, :rand.uniform(8))

            # {:ok, _, ^replace} is necessarily the exact tier (search is a substring, so
            # tier 1 sees >= 1 occurrence; :ok means exactly one) -> compare to naive replace.
            case Resolve.resolve_block(text, search, replace) do
              {:ok, span, ^replace} ->
                {:ok, doc} = Doc.replace(Doc.new(text), span, replace)
                assert Doc.text(doc) == String.replace(text, search, replace, global: false)
                count + 1

              _ ->
                count
            end
          end
        end)

      # guard against a vacuous pass: the property must have exercised many real cases
      assert asserted > 50
    end
  end

  describe "refusal classification (no apply — actionable message)" do
    test ":stale — the search lines exist but not contiguously (file changed under it)" do
      assert Resolve.resolve_block("alpha\nINSERTED\nbeta\ngamma", "alpha\nbeta\ngamma", "Z") ==
               {:error, :stale}
    end

    test ":not_found — the quoted text isn't in the file" do
      assert Resolve.resolve_block("alpha\nbeta", "nothing like this here", "Z") ==
               {:error, :not_found}
    end

    test "empty / whitespace-only search is refused (prepend deferred)" do
      assert Resolve.resolve_block("a\nb", "", "Z") == {:error, :not_found}
      assert Resolve.resolve_block("a\nb", "   \n  ", "Z") == {:error, :not_found}
    end
  end
end
