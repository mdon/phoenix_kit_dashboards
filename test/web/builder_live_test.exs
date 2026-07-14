defmodule PhoenixKitDashboards.Web.BuilderLiveTest do
  use PhoenixKitDashboards.LiveCase

  alias PhoenixKit.Users.Roles
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Layout

  defp sign_in(conn) do
    user = user_fixture()
    scope = fake_scope(user_uuid: user.uuid)
    {put_test_scope(conn, scope), user}
  end

  # The (single) widget's default-breakpoint grid placement / pixel geometry.
  defp grid(uuid), do: Layout.placement(hd(Dashboards.get(uuid).layout), "l1")
  defp pixel(uuid), do: Layout.pixel(hd(Dashboards.get(uuid).layout))

  # Every rendered clock time (HH:MM:SS), in DOM order.
  defp clock_times(html) do
    ~r/(\d{2}:\d{2}:\d{2})/ |> Regex.scan(html) |> Enum.map(fn [_, t] -> t end)
  end

  describe "mount" do
    test "renders the builder header + widget catalog for an owned dashboard", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{title: "Ops Board"})

      {:ok, view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ "Ops Board"

      # The catalog is a slide-over panel, always rendered but HIDDEN by default
      # (display none; the Widgets button toggles it client-side via JS.toggle,
      # so opening is instant — no server round-trip to test here). Built-ins
      # are grouped under a provider section.
      assert html =~ ~r/id="dashboard-catalog"[^>]*style="display: none"/
      assert html =~ "Widget catalog"
      assert html =~ "Built-in"
      assert html =~ "Clock"
      assert html =~ "Note"
      assert html =~ "Module stats"
      # It overlays the grid rather than squeezing it (absolute positioning).
      assert html =~ ~r/id="dashboard-catalog"[^>]*class="[^"]*absolute/
      # Both the toolbar button and the in-panel X are client-side commands.
      assert view |> element("#dashboard-catalog-toggle") |> render() =~ "phx-click"
    end

    test "redirects to the index with a flash when the dashboard is missing", %{conn: conn} do
      {conn, _user} = sign_in(conn)

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/en/admin/dashboards/#{Ecto.UUID.generate()}")

      assert to == "/en/admin/dashboards"
      assert flash["error"] =~ "Dashboard not found."
    end

    test "denies access to another user's personal dashboard", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      other = user_fixture()
      foreign = fixture_dashboard(other.uuid, %{title: "Private"})

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/en/admin/dashboards/#{foreign.uuid}")

      assert to == "/en/admin/dashboards"
      assert flash["error"] =~ "do not have access"
    end
  end

  describe "add_widget" do
    test "persists a widget instance and logs it (outcome verified in the DB)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{title: "Grid"})

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      render_click(view, "add_widget", %{"key" => "core.note"})

      reloaded = Dashboards.get(dashboard.uuid)
      assert [%{"widget_key" => "core.note"}] = reloaded.layout

      assert_activity_logged("dashboard.widget_added",
        actor_uuid: user.uuid,
        resource_uuid: dashboard.uuid,
        metadata_has: %{"widget_key" => "core.note"}
      )
    end

    test "add_widget_at drops a catalog drag at the given cell (grid)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      html = render_hook(view, "add_widget_at", %{"key" => "core.note", "x" => 6, "y" => 3})

      assert [inst] = Dashboards.get(dashboard.uuid).layout
      assert %{"x" => 6, "y" => 3} = Layout.placement(inst, "l1")
      assert html =~ ~s(grid-column: 7 / span)
      assert html =~ ~s(grid-row: 4 / span)
    end

    test "add_widget_px drops a catalog drag at exact px (pixel dashboard)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      render_hook(view, "add_widget_px", %{"key" => "core.note", "fx" => 320, "fy" => 260})

      assert [inst] = Dashboards.get(dashboard.uuid).layout
      assert %{"fx" => 320, "fy" => 260} = Layout.pixel(inst)
    end

    test "an unknown widget key on a catalog drop flashes instead of crashing", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      html = render_hook(view, "add_widget_at", %{"key" => "nope.gone", "x" => 0, "y" => 0})

      assert html =~ "Could not add widget."
      assert Dashboards.get(dashboard.uuid).layout == []
    end

    test "catalog entries carry the drag-out contract (hook + key + default size)", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ ~s(phx-hook="DashboardCatalogDrag")
      assert html =~ ~s(data-widget-key="core.note")
    end
  end

  describe "grid (Phoenix-first / cell placement)" do
    test "an empty grid dashboard still renders the surface and its guides", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)

      {:ok, view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # The grid pane renders even with zero widgets (hint floats over it)...
      assert html =~ ~s(id="dashboard-grid")
      assert html =~ "Add widgets from the panel"
      # ...so the Show-grid toggle works on an empty board too.
      assert render_click(view, "toggle_grid_lines", %{}) =~ "radial-gradient"
    end

    test "the Show-grid toggle renders cell guides (off by default)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      refute html =~ "radial-gradient"

      # Guides are a CSS dot lattice pitched in box fractions, so they track
      # the FITTED cell size — zero extra DOM (per-cell divs would be
      # thousands of nodes on the fine lattice).
      on_html = render_click(view, "toggle_grid_lines", %{})
      assert on_html =~ "radial-gradient"
      assert on_html =~ "background-size: calc(100% / 64) calc(100% / 36)"

      refute render_click(view, "toggle_grid_lines", %{}) =~ "radial-gradient"
    end

    test "renders the server grid with the cell-drag hook, not gridstack", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ ~s(phx-hook="DashboardGridDrag")
      assert html =~ "sortable-item"
      # gridstack is gone (the old `DashboardGrid` hook — not `DashboardGridFit`).
      refute html =~ "grid-stack"
      refute html =~ ~s(phx-hook="DashboardGrid")
    end

    test "opens instantly on the first layout — no detection, no loading state", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # The grid renders immediately (legacy default layout: Desktop 12 cols),
      # editable, with the fit + drag + resize hooks in place.
      refute html =~ "loading-spinner"
      refute html =~ "DashboardBreakpoint"
      assert html =~ ~s(data-cols="64")
      assert html =~ "DashboardGridFit"
      assert html =~ ~s(phx-hook="DashboardGridDrag")
      assert html =~ ~s(phx-hook="DashboardResize")
      # The layout tab strip with the default layout + the add button.
      assert html =~ "Layout 1"
      assert html =~ ~s(phx-click="add_layout")
      # Catalog starts hidden.
      assert html =~ ~r/id="dashboard-catalog"[^>]*style="display: none"/
    end

    test "the ?layout= deep link opens that layout; unknown ids fall back", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      {:ok, dashboard, entry} = Dashboards.add_layout(dashboard, "l1")
      {:ok, dashboard} = Dashboards.rename_layout(dashboard, entry["id"], "Wall TV")
      {:ok, dashboard} = Dashboards.resize_grid(dashboard, entry["id"], :cols, 1)

      {:ok, _view, html} =
        live(conn, "/en/admin/dashboards/#{dashboard.uuid}?layout=#{entry["id"]}")

      assert html =~ ~s(data-cols="65")

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}?layout=ghost")
      assert html =~ ~s(data-cols="64")
    end

    test "layout tabs: add creates + activates + enters rename mode; rename and delete work",
         %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      # "+" creates a copy of the active layout and drops into rename mode.
      html = render_click(view, "add_layout", %{})
      assert html =~ "Layout 2"
      assert html =~ ~s(phx-submit="rename_layout")

      new_id =
        Dashboards.get(dashboard.uuid) |> Dashboards.layouts() |> List.last() |> Map.get("id")

      # Rename commits and leaves rename mode.
      html = render_submit(view, "rename_layout", %{"id" => new_id, "name" => "Portrait"})
      assert html =~ "Portrait"
      refute html =~ ~s(phx-submit="rename_layout")

      # Deleting the active layout falls back to the first one.
      html = render_click(view, "delete_layout", %{"id" => new_id})
      refute html =~ "Portrait"
      assert html =~ ~s(data-cols="64")

      # The last layout is protected.
      html = render_click(view, "delete_layout", %{"id" => "l1"})
      assert html =~ "at least one layout"

      # Hostile ids are no-ops.
      assert render_click(view, "set_layout", %{"id" => "ghost"}) =~ ~s(data-cols="64")
    end

    test "reorder_widgets event persists the new order", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")
      [a, b] = Enum.map(dashboard.layout, & &1["id"])

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      render_hook(view, "reorder_widgets", %{"ordered_ids" => [b, a], "moved_id" => b})

      # Reorder writes per-breakpoint `pos`; the render order comes from resolve_items.
      ordered =
        Dashboards.resolve_items(Dashboards.get(dashboard.uuid), "l1")
        |> Enum.map(fn {i, _} -> i["id"] end)

      assert ordered == [b, a]
    end

    test "move_widget_grid places a widget at an explicit cell (drag hook)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")
      [%{"id" => a}, %{"id" => b}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      # Anywhere on the grid — including below a gap.
      html = render_hook(view, "move_widget_grid", %{"id" => a, "x" => 2, "y" => 10})

      assert %{"x" => 2, "y" => 10} =
               Layout.placement(hd(Dashboards.get(dashboard.uuid).layout), "l1")

      assert html =~ ~s(grid-column: 3 / span)
      assert html =~ ~s(grid-row: 11 / span)

      # An occupied spot is refused (crafted event; the hook never offers one).
      render_hook(view, "move_widget_grid", %{"id" => b, "x" => 2, "y" => 10})

      refute match?(
               %{"x" => 2, "y" => 10},
               Dashboards.resolve_placement(Dashboards.get(dashboard.uuid), b, "l1")
             )
    end

    test "resize_widget_to sets an absolute span (corner-drag), clamped", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      render_hook(view, "resize_widget_to", %{"id" => id, "w" => 8, "h" => 5})
      assert %{"w" => 8, "h" => 5} = grid(dashboard.uuid)

      # An out-of-range span is clamped to the SCREENFUL, never persisted raw.
      render_hook(view, "resize_widget_to", %{"id" => id, "w" => 999, "h" => 999})
      %{"w" => w, "h" => h} = grid(dashboard.uuid)
      assert w <= 64 and h <= 36
    end

    test "each widget card carries the resize hook + min/max bounds for the drag", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ ~s(phx-hook="DashboardResize")
      assert html =~ "pk-resize-handle"
      assert html =~ ~s(data-min-w=)
      assert html =~ ~s(data-max-w=)
      assert html =~ ~s(data-min-h=)
      assert html =~ ~s(data-max-h=)
      # The ± steppers are gone (corner-drag + Settings modal replace them).
      refute html =~ ~s(phx-click="resize_widget")
    end

    test "free-mode resize stores absolute px size (fw/fh), clamped to a sane range", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      render_hook(view, "resize_widget_to", %{"id" => id, "fw" => 350, "fh" => 220})
      assert %{"fw" => 350, "fh" => 220} = pixel(dashboard.uuid)

      # Out-of-range px is clamped to [60, 4000] — no grid, no snap.
      render_hook(view, "resize_widget_to", %{"id" => id, "fw" => 10, "fh" => 99_999})
      assert %{"fw" => 60, "fh" => 4000} = pixel(dashboard.uuid)
    end

    test "a garbage resize span is ignored, not snapped to the minimum", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout
      before = grid(dashboard.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      render_hook(view, "resize_widget_to", %{"id" => id, "w" => "junk", "h" => "0"})

      assert grid(dashboard.uuid) == before
    end
  end

  describe "dashboard type (fixed at creation)" do
    test "a grid dashboard renders the grid, no mode toggle", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "grid"}})
      {:ok, _} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ ~s(phx-hook="DashboardGridDrag")
      assert html =~ "Grid"
      # Type is fixed at creation — no grid/free toggle.
      refute html =~ ~s(phx-click="set_mode")
    end

    test "a pixel dashboard renders the free canvas — no Layout bar, no zoom, no tiers",
         %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})
      {:ok, _} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ ~s(phx-hook="DashboardFreeFit")
      # Parity with grid where it matters, minus what pixel doesn't need.
      refute html =~ ~s(phx-click="zoom")
      refute html =~ ~s(phx-click="set_bp")
      refute html =~ ~s(phx-hook="DashboardGridDrag")
      assert html =~ ~s(phx-hook="DashboardFullscreen")
      # Widgets can be overlapped deliberately: z-order controls in the bar.
      assert html =~ ~s(phx-click="restack_widget")
      assert html =~ "z-index: 0;"
    end

    test "restack_widget orders overlapping pixel widgets by z", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")
      [a, _b] = Enum.map(dashboard.layout, & &1["id"])

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      html = render_click(view, "restack_widget", %{"id" => a, "dir" => "front"})
      assert html =~ "z-index: 1;"

      reloaded = Dashboards.get(dashboard.uuid)
      assert Layout.pixel(hd(reloaded.layout))["z"] == 1
    end

    test "the settings modal X/Y inputs place a pixel widget (no-drag fallback)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      view |> element("button[phx-click='open_settings'][phx-value-id='#{id}']") |> render_click()

      view
      |> form("form[phx-submit='save_settings']", %{
        "fw" => "300",
        "fh" => "200",
        "fx" => "120",
        "fy" => "80"
      })
      |> render_submit()

      assert %{"fx" => 120, "fy" => 80, "fw" => 300, "fh" => 200} = pixel(dashboard.uuid)
    end

    test "move_widget_to places a widget at an absolute px position (drag hook)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      render_hook(view, "move_widget_to", %{"id" => id, "fx" => 237, "fy" => 191})

      # Exact px — no cell snapping.
      assert %{"fx" => 237, "fy" => 191} = pixel(dashboard.uuid)
    end

    test "free mode renders an absolute px canvas (data-free + left/top/width/height)", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"mode" => "free"}})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.module_stats")
      [%{"id" => id}] = dashboard.layout
      {:ok, _} = Dashboards.place_widget_px(dashboard, id, 140, 90)
      {:ok, _} = Dashboards.resize_widget_px(Dashboards.get(dashboard.uuid), id, 300, 200)

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      # Absolute pixel placement — no CSS grid spans.
      assert html =~ ~s(data-free="true")
      assert html =~ "position: absolute; left: 140px; top: 90px; width: 300px; height: 200px;"
      refute html =~ "grid-column: 1 / span"

      # Fit-to-width scaffold: the fit hook + a logical canvas it scales.
      assert html =~ ~s(phx-hook="DashboardFreeFit")
      assert html =~ "pk-free-canvas"
      assert html =~ ~s(data-logical-width=)
      assert html =~ ~s(data-logical-height=)
      # Canvas starts hidden (revealed by the hook once scaled, so the unscaled
      # frame never flashes); a <noscript> keeps it visible without JS.
      assert html =~ "opacity: 0;"
      # The no-JS reveal is a pure-CSS delayed animation (a <noscript> style
      # would leak — morphdom livens noscript children after the LV connects).
      assert html =~ "pk-canvas-reveal"
      refute html =~ "<noscript>"
    end
  end

  describe "live refresh" do
    test "a refresh tick re-renders live widgets without crashing", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      # Drive the periodic tick directly; the clock widget must re-render live.
      send(view.pid, :refresh_tick)
      html = render(view)
      assert html =~ ~r/\d{2}:\d{2}:\d{2}/
    end

    test "the tick actually advances a live widget — clocks must not freeze", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      # The due-time default must let the FIRST tick fire: monotonic `now` is a
      # large negative number on the BEAM, so a 0 default froze every live
      # widget forever (send_update never ran; both clocks stood still).
      before_times = clock_times(render(view))
      assert length(before_times) == 2

      # Cross a second boundary, then tick: BOTH clocks must show a new time.
      Process.sleep(1100)
      send(view.pid, :refresh_tick)
      after_times = clock_times(render(view))

      assert length(after_times) == 2
      assert Enum.all?(Enum.zip(before_times, after_times), fn {b, a} -> a != b end)
    end
  end

  describe "settings modal" do
    test "opens and saves settings + view through the UI", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.module_stats")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      html =
        view
        |> element("button[phx-click='open_settings'][phx-value-id='#{id}']")
        |> render_click()

      assert html =~ "Widget settings"
      assert html =~ ~s(name="view")

      view
      |> form("form[phx-submit='save_settings']", %{
        "view" => "compact",
        "settings" => %{"module_key" => "jobs"}
      })
      |> render_submit()

      assert [%{"view" => "compact", "settings" => %{"module_key" => "jobs"}}] =
               Dashboards.get(dashboard.uuid).layout
    end

    test "save_settings without an open modal is a no-op (no write, no phantom activity)", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id, "settings" => settings}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      # A double submit racing close_settings arrives with no settings_instance.
      render_hook(view, "save_settings", %{"settings" => %{"title" => "sneaky"}})

      assert [%{"id" => ^id, "settings" => ^settings}] = Dashboards.get(dashboard.uuid).layout
      refute_activity_logged("dashboard.widget_configured", resource_uuid: dashboard.uuid)
    end

    test "the Allow-smaller checkbox + a small size persist in ONE save", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      view |> element("button[phx-click='open_settings'][phx-value-id='#{id}']") |> render_click()

      # Opt out of the floor and shrink below it in the same submit — configure
      # (incl. the override) runs before the resize, so the drop applies.
      view
      |> form("form[phx-submit='save_settings']", %{
        "min_override" => "true",
        "w" => "1",
        "h" => "1"
      })
      |> render_submit()

      reloaded = Dashboards.get(dashboard.uuid)
      assert [%{"min_override" => true}] = reloaded.layout
      assert %{"w" => 1, "h" => 1} = Dashboards.resolve_placement(reloaded, id, "l1")
    end

    test "the Settings modal W×H inputs resize the widget (no-hook fallback)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      view |> element("button[phx-click='open_settings'][phx-value-id='#{id}']") |> render_click()

      view
      |> form("form[phx-submit='save_settings']", %{"w" => "20", "h" => "10"})
      |> render_submit()

      assert %{"w" => 20, "h" => 10} = grid(dashboard.uuid)
    end

    test "on a PACKED placement the modal shows the resolved size (save doesn't shrink it)",
         %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout
      {:ok, dashboard} = Dashboards.resize_widget(dashboard, id, "l1", 10, 5)
      # A second layout, then STRIP the widget's stored placement there so the
      # layout renders it packed-at-render (the modal must show the packed size).
      {:ok, dashboard, entry} = Dashboards.add_layout(dashboard, "l1")
      layout_id = entry["id"]

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.save_layout(
          dashboard,
          Enum.map(dashboard.layout, fn inst ->
            Map.update!(inst, "bp", &Map.delete(&1, layout_id))
          end)
        )

      # Without a stored placement the widget packs at its DEFAULT span (16x8) —
      # layouts are independent, there is no cross-layout derivation.
      packed = Dashboards.resolve_placement(dashboard, id, layout_id)
      assert %{"w" => 16, "h" => 8} = packed

      {:ok, view, _html} =
        live(conn, "/en/admin/dashboards/#{dashboard.uuid}?layout=#{layout_id}")

      html =
        view
        |> element("button[phx-click='open_settings'][phx-value-id='#{id}']")
        |> render_click()

      # The modal shows the RESOLVED (packed) values, and saving them keeps
      # the placement exactly where/how it rendered.
      assert html =~ ~s(name="w") and html =~ ~s(value="#{packed["w"]}")

      view
      |> form("form[phx-submit='save_settings']", %{"w" => "16", "h" => "8"})
      |> render_submit()

      assert %{"w" => 16, "h" => 8} =
               Dashboards.resolve_placement(Dashboards.get(dashboard.uuid), id, layout_id)

      # The desktop layout kept its distinctive 10x5 — untouched by the edit.
      assert %{"w" => 10, "h" => 5} =
               Dashboards.resolve_placement(Dashboards.get(dashboard.uuid), id, "l1")
    end
  end

  describe "role-scoped access (A1)" do
    test "a user with the role can open a role dashboard in the builder", %{conn: conn} do
      user = user_fixture()

      {:ok, role} = Roles.create_role(%{name: "Widgets-#{System.unique_integer([:positive])}"})

      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, roles: [role.name]))

      {:ok, dashboard} =
        Dashboards.create(%{title: "Team Board", scope: "role", role_uuid: role.uuid})

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      assert html =~ "Team Board"
    end

    test "a user without the role is denied", %{conn: conn} do
      {conn, _user} = sign_in(conn)

      {:ok, role} = Roles.create_role(%{name: "Other-#{System.unique_integer([:positive])}"})

      {:ok, dashboard} =
        Dashboards.create(%{title: "Secret", scope: "role", role_uuid: role.uuid})

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert flash["error"] =~ "do not have access"
    end
  end
end
