defmodule PhoenixKitDashboards.SizingTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Lattice
  alias PhoenixKitDashboards.Sizing

  # The context and the builder LiveView both call Sizing.bounds/2 — this pins
  # the single rule so the two can't drift (review #5).

  describe "bounds/2" do
    test "a known widget: min from the type, max = its declared max" do
      item = %{"widget_key" => "core.note"}
      {min, max} = Sizing.bounds(item, "l1")
      assert %{w: mw, h: mh} = min
      assert mw >= 1 and mh >= 1
      assert %{w: _, h: _} = max
    end

    test "the analog clock view raises the floor above the type min (per-view min_size)" do
      base = %{"widget_key" => "core.clock"}
      {type_min, _} = Sizing.bounds(base, "l1")

      analog = %{"widget_key" => "core.clock", "bp" => %{"l1" => %{"view" => "analog"}}}
      {analog_min, _} = Sizing.bounds(analog, "l1")

      # Analog declares an 8x8 floor — squarer than the widget-level min.
      assert analog_min == %{w: 8, h: 8}
      assert analog_min.h >= type_min.h
    end

    test "min_override drops the floor to 1x1" do
      item = %{"widget_key" => "core.clock", "min_override" => true}
      assert {%{w: 1, h: 1}, _max} = Sizing.bounds(item, "l1")
    end

    test "an unknown widget gets a permissive range (stale/uninstalled provider)" do
      assert {%{w: 1, h: 1}, %{w: max_w, h: max_h}} =
               Sizing.bounds(%{"widget_key" => "nope.gone"}, "l1")

      assert max_w == Lattice.max_dim()
      assert max_h == Lattice.max_dim()
    end
  end
end
