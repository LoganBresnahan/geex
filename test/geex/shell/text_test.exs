defmodule Geex.Shell.TextTest do
  # `Geex.Shell.Text.location/1`: the `path(line,col): error` form tsc prints without a terminal
  # and MSBuild always (2026-11-13), beside the `path:line:col` form it always read.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Geex.Shell.Text, only: [location: 1]

  defp segment, do: string([?a..?z, ?0..?9, ?_], min_length: 1, max_length: 8)

  defp path do
    gen all(
          dirs <- list_of(segment(), max_length: 3),
          name <- segment(),
          ext <- member_of(~w(ts tsx cs vb mts))
        ) do
      Enum.join(dirs ++ ["#{name}.#{ext}"], "/")
    end
  end

  describe "tsc's form, path(line,col): error" do
    test "tsc without a terminal, MSBuild, a line with no column, other severities" do
      assert location(
               "src/a.ts(3,5): error TS2322: Type 'string' is not assignable to type 'number'."
             ) ==
               {"src/a.ts", 3, 5}

      assert location("Program.cs(12,17): error CS1002: ; expected [/p/app.csproj]") ==
               {"Program.cs", 12, 17}

      assert location("lib/x.ts(40): warning TS6133: 'y' is declared but never read.") ==
               {"lib/x.ts", 40, nil}

      assert location("  ../pkg/b.tsx(1,1): Error TS1005: ';' expected.") ==
               {"../pkg/b.tsx", 1, 1}

      assert location("a.ts(2,3): message TS6194: Found 1 error.") == {"a.ts", 2, 3}
    end

    test "a call in ordinary output is not one: it needs the `: error` word after it" do
      assert location("Math.max(1,2) is 2") == nil
      assert location("console.log(3,4): done") == nil
      assert location("foo.ts(3,5) error TS1") == nil
      assert location("v1.2(3,4): errors everywhere") == nil
    end

    test "with both forms on a line, the one further left wins" do
      assert location("lib/a.ex:7: see b.ts(3,5): error TS1") == {"lib/a.ex", 7, nil}
      assert location("b.ts(3,5): error TS1 from lib/a.ex:7") == {"b.ts", 3, 5}
    end

    test "the colon form reads as before, `tsc --pretty`'s among it" do
      assert location("src/a.ts:3:5 - error TS2322: Type 'string'") == {"src/a.ts", 3, 5}
      assert location("see http://localhost:4000 and lib/a.ex:9") == {"lib/a.ex", 9, nil}
      assert location("no location here") == nil
    end

    property "path(line,col): error reads back as {path, line, col}, at any indent" do
      check all(
              p <- path(),
              l <- positive_integer(),
              c <- one_of([constant(nil), positive_integer()]),
              sev <- member_of(~w(error warning Error note)),
              indent <- string([?\s], max_length: 4)
            ) do
        pos = if c, do: "#{l},#{c}", else: "#{l}"
        assert location("#{indent}#{p}(#{pos}): #{sev} TS1234: some text") == {p, l, c}
      end
    end

    property "without the severity word after it, a parenthesised pair is never a location" do
      check all(
              p <- path(),
              l <- positive_integer(),
              c <- positive_integer(),
              tail <- member_of(["", " is fine", ": done", " -> error", ": errors"])
            ) do
        assert location("#{p}(#{l},#{c})#{tail}") == nil
      end
    end
  end
end
