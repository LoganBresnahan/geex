defmodule Geex.CellTest do
  use ExUnit.Case, async: true

  alias Geex.Cell

  test "blank is space, default colours, no attrs" do
    assert %Cell{char: " ", fg: :default, bg: :default, attrs: []} = Cell.blank()
  end

  describe "equal?/2" do
    test "identical cells are equal" do
      a = %Cell{char: "x", fg: {:ansi, 1}, bg: :default, attrs: [:bold]}
      assert Cell.equal?(a, a)
    end

    test "different chars are unequal" do
      refute Cell.equal?(%Cell{char: "a"}, %Cell{char: "b"})
    end

    test "different colours are unequal" do
      refute Cell.equal?(%Cell{fg: :default}, %Cell{fg: {:ansi, 1}})
      refute Cell.equal?(%Cell{bg: :default}, %Cell{bg: {:ansi, 1}})
    end

    test "attr order does not matter" do
      a = %Cell{attrs: [:bold, :italic]}
      b = %Cell{attrs: [:italic, :bold]}
      assert Cell.equal?(a, b)
    end

    test "different attr sets are unequal" do
      refute Cell.equal?(%Cell{attrs: [:bold]}, %Cell{attrs: [:bold, :italic]})
    end
  end
end
