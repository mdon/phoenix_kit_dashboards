defmodule PhoenixKitDashboards.GridTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Grid

  defp p(x, y, w, h), do: %{"x" => x, "y" => y, "w" => w, "h" => h}

  describe "collides?/5" do
    test "detects overlap and clear separation" do
      others = [p(2, 0, 4, 2)]
      assert Grid.collides?(0, 0, 4, 2, others)
      assert Grid.collides?(5, 1, 2, 2, others)
      refute Grid.collides?(6, 0, 4, 2, others)
      refute Grid.collides?(2, 2, 4, 2, others)
      refute Grid.collides?(0, 0, 2, 2, others)
    end

    test "edge-adjacent rectangles do not collide" do
      others = [p(0, 0, 4, 2)]
      refute Grid.collides?(4, 0, 4, 2, others)
      refute Grid.collides?(0, 2, 4, 2, others)
    end

    test "placements without cells are ignored" do
      refute Grid.collides?(0, 0, 12, 8, [%{"w" => 4, "h" => 2}])
    end
  end

  describe "first_free/4" do
    test "finds the first gap in reading order" do
      # Row 0: [0..3] and [8..11] taken — a 4-wide gap at x=4.
      others = [p(0, 0, 4, 2), p(8, 0, 4, 2)]
      assert Grid.first_free(others, 4, 2, 12) == {4, 0}
      # A 6-wide widget doesn't fit the gap → next free row.
      assert Grid.first_free(others, 6, 2, 12) == {0, 2}
    end

    test "empty grid places at the origin" do
      assert Grid.first_free([], 4, 2, 12) == {0, 0}
    end
  end

  describe "compact/2" do
    test "packs spans first-fit in list order, clamping to the columns" do
      packed =
        Grid.compact([%{"w" => 8, "h" => 2}, %{"w" => 6, "h" => 1}, %{"w" => 4, "h" => 1}], 12)

      assert [
               %{"x" => 0, "y" => 0, "w" => 8},
               # 6 doesn't fit beside the 8 → next row; the 4 backfills row 0.
               %{"x" => 0, "y" => 2, "w" => 6},
               %{"x" => 8, "y" => 0, "w" => 4}
             ] = packed
    end

    test "clamps a span wider than the target columns (tier derivation)" do
      assert [%{"x" => 0, "y" => 0, "w" => 4}] = Grid.compact([%{"w" => 10, "h" => 2}], 4)
    end
  end

  describe "fit_size/8" do
    @bounds {%{w: 1, h: 1}, %{w: 16, h: 8}}

    test "grows freely with no neighbours, clamped to grid edge and bounds" do
      assert {8, 5} = Grid.fit_size(2, 0, 8, 5, 2, [], 12, @bounds)
      # Width past the right edge stops at it (cols - x).
      assert {10, 5} = Grid.fit_size(2, 0, 99, 5, 2, [], 12, @bounds)
    end

    test "grows until blocked by a neighbour instead of overlapping" do
      # Neighbour at x=6 on the same rows: width stops at 6 - 0.
      others = [p(6, 0, 4, 4)]
      assert {6, 2} = Grid.fit_size(0, 0, 10, 2, 2, others, 12, @bounds)
      # Neighbour below at y=3: height stops at 3.
      others = [p(0, 3, 4, 2)]
      assert {4, 3} = Grid.fit_size(0, 0, 4, 6, 2, others, 12, @bounds)
    end
  end
end
