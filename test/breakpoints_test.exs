defmodule PhoenixKitDashboards.BreakpointsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Breakpoints

  test "tiers are ordered largest → smallest with per-device column counts" do
    assert Breakpoints.keys() == ["tv", "desktop", "ipad", "phone"]
    assert Breakpoints.cols("tv") == 16
    assert Breakpoints.cols("desktop") == 12
    assert Breakpoints.cols("ipad") == 8
    assert Breakpoints.cols("phone") == 4
    assert Breakpoints.default() == "desktop"
  end

  test "cols falls back to 12 for an unknown key" do
    assert Breakpoints.cols("nope") == 12
  end

  test "valid?/1" do
    assert Breakpoints.valid?("phone")
    refute Breakpoints.valid?("laptop")
    refute Breakpoints.valid?(nil)
  end

  test "larger_than / smaller_than give the nearest-first source/fallback chains" do
    # Nearest-first: iPad's larger chain is Desktop (nearer) then TV.
    assert Breakpoints.larger_than("ipad") == ["desktop", "tv"]
    assert Breakpoints.smaller_than("ipad") == ["phone"]
    assert Breakpoints.larger_than("phone") == ["ipad", "desktop", "tv"]
    assert Breakpoints.larger_than("tv") == []
    assert Breakpoints.smaller_than("phone") == []
  end
end
