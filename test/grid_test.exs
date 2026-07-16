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

  describe "first_free/4,5" do
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

    test "with a rows bound, never returns a y past the layout's last row" do
      # A 4x4 layout (rows 0..3) packed solid with 1x1s — no free cell for a
      # 5th, so the caller's below_all/1 fallback must be used, NOT a y
      # outside the layout (a screenful must never scroll).
      others = for x <- 0..3, y <- 0..3, do: p(x, y, 1, 1)
      assert Grid.first_free(others, 1, 1, 4, 4) == nil
      # Without a rows bound (default), the same occupancy still finds a spot
      # past row 3 — this is the documented default behavior for callers that
      # don't have a layout row count of their own.
      assert Grid.first_free(others, 1, 1, 4) == {0, 4}
    end

    test "with a rows bound, still finds a free cell inside the bound" do
      others = [p(0, 0, 4, 2)]
      assert Grid.first_free(others, 4, 2, 4, 4) == {0, 2}
    end
  end

  describe "compact/2,3" do
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

    test "with a rows bound, falls back to stacking below the screenful instead of overflowing it" do
      # Two 4x4 (16-cell) widgets can't both fit inside a 4x4 layout (16 cells
      # total, but a 4x4 span needs the whole grid) — the second must stack
      # below row 4, not silently take a y inside 0..3 that would overlap.
      packed = Grid.compact([%{"w" => 4, "h" => 4}, %{"w" => 4, "h" => 4}], 4, 4)
      assert [%{"x" => 0, "y" => 0}, %{"x" => 0, "y" => 4}] = packed
    end
  end

  describe "fit_size/8" do
    test "the grid edge caps even the type minimum (min_override corner)" do
      # A widget parked at the bottom edge via min_override: growing back to
      # its type min (8x4 here) must stop at the screenful edge, never spill
      # past it. Same at the right edge for width.
      bounds = {%{w: 8, h: 4}, %{w: 160, h: 160}}
      assert {8, 1} = Grid.fit_size(0, 9, 8, 4, 1, [], {10, 10}, bounds)
      assert {1, 4} = Grid.fit_size(9, 0, 8, 4, 4, [], {10, 10}, bounds)
    end

    @bounds {%{w: 1, h: 1}, %{w: 16, h: 8}}

    test "grows freely with no neighbours, clamped to grid edge and bounds" do
      assert {8, 5} = Grid.fit_size(2, 0, 8, 5, 2, [], {12, 160}, @bounds)
      # Width past the right edge stops at it (cols - x).
      assert {10, 5} = Grid.fit_size(2, 0, 99, 5, 2, [], {12, 160}, @bounds)
    end

    test "grows until blocked by a neighbour instead of overlapping" do
      # Neighbour at x=6 on the same rows: width stops at 6 - 0.
      others = [p(6, 0, 4, 4)]
      assert {6, 2} = Grid.fit_size(0, 0, 10, 2, 2, others, {12, 160}, @bounds)
      # Neighbour below at y=3: height stops at 3.
      others = [p(0, 3, 4, 2)]
      assert {4, 3} = Grid.fit_size(0, 0, 4, 6, 2, others, {12, 160}, @bounds)
    end
  end
end
