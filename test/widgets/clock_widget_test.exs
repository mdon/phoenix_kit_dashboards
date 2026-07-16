defmodule PhoenixKitDashboards.Widgets.ClockWidgetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitDashboards.Widgets.ClockWidget

  describe "resolve_time/1" do
    test "UTC and junk fall back to plain UTC" do
      assert {%DateTime{}, "UTC"} = ClockWidget.resolve_time("UTC")
      assert {%DateTime{}, "UTC"} = ClockWidget.resolve_time(nil)
      assert {%DateTime{}, "UTC"} = ClockWidget.resolve_time(123)
      assert {%DateTime{}, "UTC"} = ClockWidget.resolve_time("not-a-zone")
    end

    test "fixed offsets shift by pure arithmetic (no tz database needed)" do
      {plus3, "UTC+3"} = ClockWidget.resolve_time("UTC+3")
      {minus7, "UTC-7"} = ClockWidget.resolve_time("UTC-7")
      {half, "UTC+5:30"} = ClockWidget.resolve_time("UTC+5:30")
      now = DateTime.utc_now()

      # Allow a couple of seconds of drift between the calls.
      assert_in_delta DateTime.diff(plus3, now), 3 * 3600, 3
      assert_in_delta DateTime.diff(minus7, now), -7 * 3600, 3
      assert_in_delta DateTime.diff(half, now), 5 * 3600 + 30 * 60, 3
    end

    test "impossible offsets degrade to UTC instead of shifting by days" do
      assert {_dt, "UTC"} = ClockWidget.resolve_time("UTC+99")
      assert {_dt, "UTC"} = ClockWidget.resolve_time("UTC+99:99")
      assert {_dt, "UTC"} = ClockWidget.resolve_time("UTC+5:99")
      assert {_dt, "UTC"} = ClockWidget.resolve_time("UTC-13")
      # Boundary + minutes overshoots the real maximum total offset.
      assert {_dt, "UTC"} = ClockWidget.resolve_time("UTC+14:59")
      assert {_dt, "UTC"} = ClockWidget.resolve_time("UTC-12:30")
      # …but the real-world extremes stay valid.
      assert {_dt, "UTC+14"} = ClockWidget.resolve_time("UTC+14")
      assert {_dt, "UTC-12"} = ClockWidget.resolve_time("UTC-12")
    end

    test "an IANA zone degrades to UTC when the host has no tz database" do
      # This test env deliberately has no tzdata; with one configured the same
      # call returns the shifted time + the zone abbreviation instead.
      {_dt, label} = ClockWidget.resolve_time("Europe/Tallinn")

      if match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), "Europe/Tallinn")) do
        refute label == "UTC"
      else
        assert label == "UTC"
      end
    end
  end

  describe "timezone_options/0" do
    test "always offers UTC first and the fixed offsets" do
      options = ClockWidget.timezone_options()
      assert hd(options) == "UTC"
      assert "UTC+3" in options
      assert "UTC-7" in options
      # No duplicate of the bare UTC via a zero offset.
      refute "UTC+0" in options
    end
  end

  describe "render" do
    defp render_clock(overrides) do
      assigns =
        Keyword.merge(
          [id: "clock-test", settings: %{}, view: nil, size: %{w: 3, h: 2}, scope: nil],
          overrides
        )

      render_component(ClockWidget, assigns)
    end

    test "normal view shows time + date; timezone label shown by default" do
      html = render_clock(settings: %{"timezone" => "UTC"})
      assert html =~ ~r/\d{2}:\d{2}:\d{2}/
      assert html =~ ~r/\d{4}-\d{2}-\d{2}/
      assert html =~ "UTC"
    end

    test "show_timezone=false hides the zone label" do
      html = render_clock(settings: %{"timezone" => "UTC", "show_timezone" => "false"})
      refute html =~ ">UTC<"
    end

    test "digital view renders the LCD panel, analog renders the SVG face" do
      digital = render_clock(view: "digital")
      assert digital =~ "font-mono"
      assert digital =~ ~r/\d{2}:\d{2}:\d{2}/

      analog = render_clock(view: "analog")
      assert analog =~ "<svg"
      assert analog =~ "rotate("
      # The analog face replaces the digits.
      refute analog =~ ~r/>\d{2}:\d{2}:\d{2}</
    end

    test "12h format shows a 01-12 hour with an AM/PM suffix; 24h has none" do
      h24 = render_clock(settings: %{"format" => "24h"})
      refute h24 =~ ~r/>\s*(AM|PM)\s*</

      h12 = render_clock(settings: %{"format" => "12h"})
      assert h12 =~ ~r/>\s*(AM|PM)\s*</
      [_, hour] = Regex.run(~r/(\d{2}):\d{2}:\d{2}/, h12)
      assert String.to_integer(hour) in 1..12

      # The analog face ignores the format (a dial is 12-hour by nature).
      analog = render_clock(view: "analog", settings: %{"format" => "12h"})
      refute analog =~ ~r/>\s*(AM|PM)\s*</
    end

    test "type scales to the box via container-query units (no size-based reflexes)" do
      # The body is a size container and the digits use cq units — the clock
      # fits ANY box by scaling, never by silently switching density.
      html = render_clock(view: "digital", size: %{w: 12, h: 4}, settings: %{"label" => "NYC"})
      assert html =~ "container-type:size"
      assert html =~ "cqmin"
      assert html =~ "overflow-hidden"
      assert html =~ "NYC"

      # The rendered markup is size-independent — same classes at any span.
      assert render_clock(view: "digital", size: %{w: 40, h: 20}) =~ "cqmin"
    end

    test "a per-clock offset changes the displayed hour" do
      utc = DateTime.utc_now()
      html = render_clock(settings: %{"timezone" => "UTC+3", "show_timezone" => "true"})

      expected = DateTime.add(utc, 3 * 3600, :second)
      # One of the two candidate hours must appear (second boundary tolerance).
      candidates = [
        Calendar.strftime(expected, "%H:"),
        Calendar.strftime(DateTime.add(expected, 1, :second), "%H:")
      ]

      assert Enum.any?(candidates, &(html =~ &1))
      assert html =~ "UTC+3"
    end
  end
end
