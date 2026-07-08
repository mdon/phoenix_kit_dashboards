defmodule PhoenixKitDashboards.LayoutTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Layout

  describe "pixel/1 + put_pixel/2" do
    test "reads embedded geometry, defaults the rest" do
      item = %{"pixel" => %{"fx" => 100, "fy" => 50}}
      assert Layout.pixel(item) == %{"fx" => 100, "fy" => 50, "fw" => 480, "fh" => 280}
    end

    test "falls back to legacy flat keys" do
      legacy = %{"fx" => 10, "fy" => 20, "fw" => 300, "fh" => 200}
      assert Layout.pixel(legacy) == %{"fx" => 10, "fy" => 20, "fw" => 300, "fh" => 200}
    end

    test "put_pixel upgrades to the nested shape without touching grid keys" do
      item = %{"id" => "a", "bp" => %{"desktop" => %{"w" => 4}}}
      updated = Layout.put_pixel(item, %{"fx" => 5})
      assert updated["pixel"]["fx"] == 5
      assert updated["bp"] == %{"desktop" => %{"w" => 4}}
    end
  end

  describe "placement/2 + put_placement/3 + hidden?/2" do
    test "reads a breakpoint's placement, defaults the rest" do
      item = %{"bp" => %{"phone" => %{"w" => 4, "h" => 1}}}
      assert Layout.placement(item, "phone") == %{"w" => 4, "h" => 1, "hidden" => false}
    end

    test "falls back to legacy flat w/h" do
      assert Layout.placement(%{"w" => 6, "h" => 3}, "desktop") ==
               %{"w" => 6, "h" => 3, "hidden" => false}
    end

    test "put_placement writes one breakpoint, leaving others + pixel untouched" do
      item = %{
        "pixel" => %{"fx" => 1},
        "bp" => %{"desktop" => %{"w" => 4, "h" => 2, "hidden" => false}}
      }

      updated = Layout.put_placement(item, "phone", %{"w" => 4, "h" => 1, "hidden" => true})
      assert updated["bp"]["desktop"] == %{"w" => 4, "h" => 2, "hidden" => false}
      assert updated["bp"]["phone"] == %{"w" => 4, "h" => 1, "hidden" => true}
      assert updated["pixel"] == %{"fx" => 1}
      assert Layout.hidden?(updated, "phone")
      refute Layout.hidden?(updated, "desktop")
    end
  end
end
