defmodule PhoenixKitDashboards.LatticeTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Lattice

  describe "constants" do
    test "cell / dims / tolerance / px bounds" do
      assert Lattice.cell() == 25
      assert Lattice.min_dim() == 4
      assert Lattice.max_dim() == 160
      assert Lattice.stretch_tolerance() == 1.04
      assert Lattice.free_min_px() == 60
      assert Lattice.free_max_px() == 4000
      assert Lattice.free_max_pos() == 20_000
    end

    test "design_width / design_height scale by the cell size" do
      assert Lattice.design_width(64) == 64 * 25
      assert Lattice.design_height(36) == 36 * 25
    end
  end

  describe "to_int/2 (the single geometry coercion)" do
    test "passes integers through" do
      assert Lattice.to_int(7, 1) == 7
      assert Lattice.to_int(0, 9) == 0
    end

    test "truncates floats" do
      assert Lattice.to_int(3.9, 1) == 3
      assert Lattice.to_int(-2.1, 1) == -2
    end

    test "parses numeric strings, falls back on the rest" do
      assert Lattice.to_int("42", 1) == 42
      assert Lattice.to_int("abc", 7) == 7
      assert Lattice.to_int("", 7) == 7
    end

    test "falls back for nil and other terms" do
      assert Lattice.to_int(nil, 5) == 5
      assert Lattice.to_int(%{}, 5) == 5
      assert Lattice.to_int(:atom, 5) == 5
      assert Lattice.to_int([1, 2], 5) == 5
    end
  end

  describe "clamp/3 (the single clamp)" do
    test "clamps integers into [lo, hi]" do
      assert Lattice.clamp(5, 1, 10) == 5
      assert Lattice.clamp(-3, 1, 10) == 1
      assert Lattice.clamp(99, 1, 10) == 10
    end

    test "a non-integer collapses to lo (never raises downstream)" do
      assert Lattice.clamp("x", 2, 10) == 2
      assert Lattice.clamp(nil, 2, 10) == 2
      assert Lattice.clamp(3.5, 2, 10) == 2
    end
  end
end
