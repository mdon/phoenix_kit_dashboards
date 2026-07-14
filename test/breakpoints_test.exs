defmodule PhoenixKitDashboards.BreakpointsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Breakpoints

  # Breakpoints is now design-space constants + the LEGACY tier table used only
  # to adapt pre-layouts dashboards (tier keys become layout ids).

  test "the legacy tier table is ordered largest → smallest" do
    assert Enum.map(Breakpoints.all(), & &1.key) == ~w(tv desktop ipad phone)
    assert Enum.map(Breakpoints.all(), & &1.cols) == [16, 12, 8, 4]
  end

  test "get/1 finds a legacy tier by key" do
    assert %{label: "Desktop", cols: 12, max_rows: 15} = Breakpoints.get("desktop")
    assert Breakpoints.get("8k-cinema") == nil
  end

  test "design_width derives from the column count at a constant SQUARE cell" do
    # 12 cols reproduce the classic 1200px canvas exactly.
    assert Breakpoints.design_width(12) == 1200
    assert Breakpoints.design_width(4) == 392
    assert Breakpoints.design_width(24) == 2412
  end

  test "max_grid_cols is the hard per-layout column cap" do
    assert Breakpoints.max_grid_cols() == 24
  end
end
