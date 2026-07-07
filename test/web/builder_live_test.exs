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
  defp grid(uuid), do: Layout.placement(hd(Dashboards.get(uuid).layout), "desktop")
  defp pixel(uuid), do: Layout.pixel(hd(Dashboards.get(uuid).layout))

  # Every rendered clock time (HH:MM:SS), in DOM order.
  defp clock_times(html) do
    ~r/(\d{2}:\d{2}:\d{2})/ |> Regex.scan(html) |> Enum.map(fn [_, t] -> t end)
  end

  describe "mount" do
    test "renders the builder header + widget catalog for an owned dashboard", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{title: "Ops Board"})

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ "Ops Board"
      # The daisyUI modal-open gutter counter must render (without it, opening a
      # modal reserves a phantom right-edge scrollbar strip the backdrop can't cover).
      assert html =~ "scrollbar-gutter:auto"
      # Built-in widget catalog is present.
      assert html =~ "Clock"
      assert html =~ "Note"
      assert html =~ "Module stats"
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
      render_hook(view, "set_bp", %{"bp" => "desktop"})
      html = render_hook(view, "add_widget_at", %{"key" => "core.note", "x" => 6, "y" => 3})

      assert [inst] = Dashboards.get(dashboard.uuid).layout
      assert %{"x" => 6, "y" => 3} = Layout.placement(inst, "desktop")
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

    test "a grid dashboard shows a loading state until the best-fit tier is detected", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # Before the hook reports: spinner shown, grid pane hidden (so the switcher
      # never animates from the default tier to the detected one).
      assert html =~ "loading-spinner"
      assert html =~ ~r/pk-grid-ready[^"]*\bhidden\b/

      # Once the tier is detected the grid reveals (no longer hidden).
      html = render_hook(view, "detect_bp", %{"bp" => "tv"})
      refute html =~ ~r/pk-grid-ready[^"]*\bhidden\b/
    end

    test "a size you didn't design shows the nearest designed view scaled — but editable", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      # Phone isn't designed → show the desktop home scaled-to-fit, WITH a banner —
      # and still fully editable (reorder + resize hooks present under the fit).
      html = render_hook(view, "detect_bp", %{"bp" => "phone"})
      assert html =~ "DashboardGridFit"
      assert html =~ "scaled to fit"
      assert html =~ ~s(phx-hook="DashboardGridDrag")
      assert html =~ ~s(phx-hook="DashboardResize")

      # Tapping your own size drops the "scaled" banner (it's your native size).
      html = render_hook(view, "set_bp", %{"bp" => "phone"})
      refute html =~ "scaled to fit"
      assert html =~ ~s(phx-hook="DashboardGridDrag")
    end

    test "reorder_widgets event persists the new order", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.clock")
      [a, b] = Enum.map(dashboard.layout, & &1["id"])

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # The builder opens at the largest tier; edit the desktop tier for this test.
      render_hook(view, "set_bp", %{"bp" => "desktop"})
      render_hook(view, "reorder_widgets", %{"ordered_ids" => [b, a], "moved_id" => b})

      # Reorder writes per-breakpoint `pos`; the render order comes from resolve_items.
      ordered =
        Dashboards.resolve_items(Dashboards.get(dashboard.uuid), "desktop")
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
      render_hook(view, "set_bp", %{"bp" => "desktop"})

      # Anywhere on the grid — including below a gap.
      html = render_hook(view, "move_widget_grid", %{"id" => a, "x" => 2, "y" => 5})

      assert %{"x" => 2, "y" => 5} =
               Layout.placement(hd(Dashboards.get(dashboard.uuid).layout), "desktop")

      assert html =~ ~s(grid-column: 3 / span)
      assert html =~ ~s(grid-row: 6 / span)

      # An occupied spot is refused (crafted event; the hook never offers one).
      render_hook(view, "move_widget_grid", %{"id" => b, "x" => 2, "y" => 5})

      refute match?(
               %{"x" => 2, "y" => 5},
               Dashboards.resolve_placement(Dashboards.get(dashboard.uuid), b, "desktop")
             )
    end

    test "resize_widget_to sets an absolute span (corner-drag), clamped", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # The builder opens at the largest tier; edit the desktop (12-col) tier here.
      render_hook(view, "set_bp", %{"bp" => "desktop"})

      render_hook(view, "resize_widget_to", %{"id" => id, "w" => 8, "h" => 5})
      assert %{"w" => 8, "h" => 5} = grid(dashboard.uuid)

      # An out-of-range span is clamped to the widget type's max, never persisted raw.
      render_hook(view, "resize_widget_to", %{"id" => id, "w" => 99, "h" => 99})
      %{"w" => w, "h" => h} = grid(dashboard.uuid)
      assert w <= 12 and h <= 8 and w < 99 and h < 99
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

    test "a pixel dashboard renders the free canvas + zoom, no mode toggle", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})
      {:ok, _} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, _view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

      assert html =~ ~s(phx-hook="DashboardFreeFit")
      assert html =~ ~s(phx-click="zoom")
      assert html =~ "Pixel"
      refute html =~ ~s(phx-click="set_mode")
      refute html =~ ~s(phx-hook="DashboardGridDrag")
    end

    test "move_widget nudges the free-canvas position by px", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{config: %{"type" => "pixel"}})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      # Seed a known px position so the nudge delta is unambiguous.
      [%{"id" => id}] = dashboard.layout
      {:ok, _} = Dashboards.place_widget_px(dashboard, id, 100, 50)

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      render_click(view, "move_widget", %{"id" => id, "dir" => "right"})

      # Nudge steps by @free_nudge_px (10) — free px, not a grid cell.
      assert %{"fx" => 110, "fy" => 50} = pixel(dashboard.uuid)
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
      assert html =~ "pk-free-canvas{opacity:1 !important}"
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
      assert Process.alive?(view.pid)
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
        "settings" => %{"module_key" => "posts"}
      })
      |> render_submit()

      assert [%{"view" => "compact", "settings" => %{"module_key" => "posts"}}] =
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
      render_hook(view, "set_bp", %{"bp" => "desktop"})
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
      assert %{"w" => 1, "h" => 1} = Dashboards.resolve_placement(reloaded, id, "desktop")
    end

    test "the Settings modal W×H inputs resize the widget (no-hook fallback)", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # The builder opens at the largest tier; edit the desktop tier for this test.
      render_hook(view, "set_bp", %{"bp" => "desktop"})
      view |> element("button[phx-click='open_settings'][phx-value-id='#{id}']") |> render_click()

      view
      |> form("form[phx-submit='save_settings']", %{"w" => "7", "h" => "4"})
      |> render_submit()

      assert %{"w" => 7, "h" => 4} = grid(dashboard.uuid)
    end

    test "on a DERIVED tier the modal shows the resolved size (save doesn't shrink it)", %{
      conn: conn
    } do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout
      {:ok, dashboard} = Dashboards.resize_widget(dashboard, id, "desktop", 10, 5)

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # TV derives from the desktop home → renders 10×5. The modal must show 10, not 4.
      render_hook(view, "set_bp", %{"bp" => "tv"})

      html =
        view
        |> element("button[phx-click='open_settings'][phx-value-id='#{id}']")
        |> render_click()

      assert html =~ ~s(value="10")

      # Saving with those (resolved) values keeps 10×5 on TV — not the default 4×2.
      view
      |> form("form[phx-submit='save_settings']", %{"w" => "10", "h" => "5"})
      |> render_submit()

      assert %{"w" => 10, "h" => 5} =
               Dashboards.resolve_placement(Dashboards.get(dashboard.uuid), id, "tv")
    end

    test "a manual size tap before detect still records the real screen size", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid)
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
      # User taps Phone before the detect hook reports (bp_manual? locks).
      render_hook(view, "set_bp", %{"bp" => "phone"})
      # The late detect for a phone screen must NOT leave the "scaled" banner on —
      # phone IS the viewer's own size, so it's a native edit.
      html = render_hook(view, "detect_bp", %{"bp" => "phone"})
      refute html =~ "scaled to fit"
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
