defmodule PhoenixKitDashboards.DashboardsTest do
  use PhoenixKitDashboards.DataCase, async: true

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Layout
  alias PhoenixKitDashboards.Schemas.Dashboard

  # The widget ids in render order for a breakpoint (via the single resolve path).
  defp ordered_ids(dashboard, bp) do
    dashboard |> Dashboards.resolve_items(bp) |> Enum.map(fn {item, _p} -> item["id"] end)
  end

  describe "create/2" do
    test "creates a personal dashboard, slugifies the title, and logs activity" do
      user = user_fixture()

      assert {:ok, %Dashboard{} = dashboard} =
               Dashboards.create(
                 %{title: "Ops Overview", scope: "personal", owner_user_uuid: user.uuid},
                 actor_uuid: user.uuid
               )

      assert dashboard.title == "Ops Overview"
      assert dashboard.slug == "ops-overview"
      assert dashboard.scope == "personal"
      assert dashboard.layout == []

      assert_activity_logged("dashboard.created",
        actor_uuid: user.uuid,
        resource_uuid: dashboard.uuid,
        metadata_has: %{"title" => "Ops Overview", "scope" => "personal"}
      )
    end

    test "requires a title" do
      assert {:error, changeset} = Dashboards.create(%{scope: "personal"})
      assert errors_on(changeset).title
    end

    test "auto-uniquifies the slug per owner on repeated titles (no constraint crash)" do
      user = user_fixture()
      attrs = %{title: "Ops", scope: "personal", owner_user_uuid: user.uuid}

      assert {:ok, a} = Dashboards.create(attrs)
      assert {:ok, b} = Dashboards.create(attrs)
      assert {:ok, c} = Dashboards.create(attrs)
      assert [a.slug, b.slug, c.slug] == ["ops", "ops-2", "ops-3"]
    end

    test "auto-uniquifies shared (nil-owner) slugs too — repeated 'Untitled Dashboard'" do
      assert {:ok, a} = Dashboards.create(%{title: "Untitled Dashboard", scope: "system"})
      assert {:ok, b} = Dashboards.create(%{title: "Untitled Dashboard", scope: "system"})
      assert [a.slug, b.slug] == ["untitled-dashboard", "untitled-dashboard-2"]
    end

    test "rejects an invalid scope" do
      assert {:error, changeset} = Dashboards.create(%{title: "X", scope: "bogus"})
      assert errors_on(changeset).scope
    end

    test "a personal dashboard requires an owner (an ownerless one is visible to nobody)" do
      assert {:error, changeset} = Dashboards.create(%{title: "Orphan", scope: "personal"})
      assert errors_on(changeset).owner_user_uuid
    end

    test "a role dashboard requires a role_uuid" do
      assert {:error, changeset} = Dashboards.create(%{title: "Roleless", scope: "role"})
      assert errors_on(changeset).role_uuid
    end
  end

  describe "list_for_user/1" do
    test "returns the user's own dashboards plus all system ones, not other users'" do
      user = user_fixture()
      other = user_fixture()

      {:ok, mine} =
        Dashboards.create(%{title: "Mine", scope: "personal", owner_user_uuid: user.uuid})

      {:ok, theirs} =
        Dashboards.create(%{title: "Theirs", scope: "personal", owner_user_uuid: other.uuid})

      {:ok, shared} = Dashboards.create(%{title: "Shared", scope: "system"})

      uuids = user.uuid |> Dashboards.list_for_user() |> Enum.map(& &1.uuid)

      assert mine.uuid in uuids
      assert shared.uuid in uuids
      refute theirs.uuid in uuids
    end

    test "includes role dashboards only for the given role uuids" do
      user = user_fixture()
      role_uuid = Ecto.UUID.generate()

      {:ok, role_dash} =
        Dashboards.create(%{title: "Role", scope: "role", role_uuid: role_uuid})

      # Without the role → not visible.
      refute role_dash.uuid in (user.uuid |> Dashboards.list_for_user() |> Enum.map(& &1.uuid))

      # With the role → visible.
      assert role_dash.uuid in (user.uuid
                                |> Dashboards.list_for_user([role_uuid])
                                |> Enum.map(& &1.uuid))
    end
  end

  describe "get_or_create_default/1" do
    test "creates a default personal dashboard on first access, returns it thereafter" do
      user = user_fixture()

      first = Dashboards.get_or_create_default(user.uuid)
      assert first.is_default
      assert first.owner_user_uuid == user.uuid

      second = Dashboards.get_or_create_default(user.uuid)
      assert second.uuid == first.uuid
    end
  end

  describe "delete/2" do
    test "deletes and logs activity" do
      user = user_fixture()
      {:ok, dashboard} = Dashboards.create(%{title: "Temp", scope: "system"})

      assert {:ok, _} = Dashboards.delete(dashboard, actor_uuid: user.uuid)
      assert Dashboards.get(dashboard.uuid) == nil
      assert_activity_logged("dashboard.deleted", resource_uuid: dashboard.uuid)
    end
  end

  describe "clone/3" do
    test "copies a shared dashboard into a personal one with fresh instance ids" do
      user = user_fixture()
      {:ok, shared} = Dashboards.create(%{title: "Team KPIs", scope: "system"})
      {:ok, shared} = Dashboards.add_widget(shared, "core.note")
      {:ok, shared} = Dashboards.set_layout_mode(shared, "free")
      [%{"id" => source_id}] = shared.layout

      assert {:ok, clone} = Dashboards.clone(shared, user.uuid)

      assert clone.scope == "personal"
      assert clone.owner_user_uuid == user.uuid
      assert clone.title == "Team KPIs (copy)"
      # Config carried over.
      assert clone.config["mode"] == "free"
      # Layout copied but with a NEW instance id (independent from the source).
      assert [%{"widget_key" => "core.note", "id" => clone_id}] = clone.layout
      assert clone_id != source_id
    end
  end

  describe "widget operations" do
    setup do
      {:ok, dashboard} = Dashboards.create(%{title: "Grid", scope: "system"})
      %{dashboard: dashboard}
    end

    test "add_widget seeds an instance from the widget type and logs it", %{dashboard: dashboard} do
      assert {:ok, updated} = Dashboards.add_widget(dashboard, "core.note", actor_uuid: nil)
      assert [instance] = updated.layout
      assert instance["widget_key"] == "core.note"
      # Geometry is embedded: a grid placement (default breakpoint, seeded at the
      # first free cell) + pixel geometry.
      assert Layout.placement(instance, "desktop") ==
               %{"x" => 0, "y" => 0, "w" => 4, "h" => 2, "hidden" => false, "pos" => 0}

      assert %{"fw" => fw, "fh" => fh} = Layout.pixel(instance)
      assert fw == 4 * 120 and fh == 2 * 140
      assert instance["settings"] == %{"title" => "Note", "body" => ""}

      assert_activity_logged("dashboard.widget_added",
        resource_uuid: dashboard.uuid,
        metadata_has: %{"widget_key" => "core.note"}
      )
    end

    test "add_widget rejects an unknown widget key", %{dashboard: dashboard} do
      assert {:error, :unknown_widget} = Dashboards.add_widget(dashboard, "nope.missing")
    end

    test "remove_widget drops the instance by id", %{dashboard: dashboard} do
      {:ok, with_widget} = Dashboards.add_widget(dashboard, "core.clock")
      [%{"id" => id}] = with_widget.layout

      assert {:ok, emptied} = Dashboards.remove_widget(with_widget, id)
      assert emptied.layout == []
      assert_activity_logged("dashboard.widget_removed", resource_uuid: dashboard.uuid)
    end

    test "update_widget_settings replaces a single instance's settings", %{dashboard: dashboard} do
      {:ok, with_widget} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = with_widget.layout

      assert {:ok, updated} =
               Dashboards.update_widget_settings(with_widget, id, %{
                 "title" => "Hi",
                 "body" => "x"
               })

      assert [%{"settings" => %{"title" => "Hi", "body" => "x"}}] = updated.layout
      assert_activity_logged("dashboard.widget_configured", resource_uuid: dashboard.uuid)
    end

    test "save_layout persists positions but is NOT logged (drag hot path)", %{
      dashboard: dashboard
    } do
      layout = [
        %{"id" => "a", "widget_key" => "core.clock", "x" => 2, "y" => 1, "w" => 3, "h" => 1}
      ]

      assert {:ok, updated} = Dashboards.save_layout(dashboard, layout)
      assert updated.layout == layout
      refute_activity_logged("dashboard.updated", resource_uuid: dashboard.uuid)
    end
  end

  describe "reorder_widgets/3 (per breakpoint)" do
    setup do
      {:ok, d0} = Dashboards.create(%{title: "Grid", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      {:ok, d2} = Dashboards.add_widget(d1, "core.clock")
      {:ok, d3} = Dashboards.add_widget(d2, "core.module_stats")
      %{dashboard: d3, ids: Enum.map(d3.layout, & &1["id"])}
    end

    test "reorders the breakpoint's flow to the given id order", %{dashboard: d, ids: [a, b, c]} do
      assert {:ok, reordered} = Dashboards.reorder_widgets(d, "desktop", [c, a, b])
      assert ordered_ids(reordered, "desktop") == [c, a, b]
    end

    test "ignores unknown ids and appends unnamed widgets", %{dashboard: d, ids: [a, b, c]} do
      assert {:ok, reordered} = Dashboards.reorder_widgets(d, "desktop", [b, "ghost", a])
      # b, a named (ghost dropped); c unnamed → appended after.
      assert ordered_ids(reordered, "desktop") == [b, a, c]
    end

    test "is not activity-logged (layout tweak)", %{dashboard: d, ids: ids} do
      {:ok, _} = Dashboards.reorder_widgets(d, "desktop", Enum.reverse(ids))
      refute_activity_logged("dashboard.updated", resource_uuid: d.uuid)
    end
  end

  describe "resize_widget/5 (per breakpoint)" do
    setup do
      {:ok, d0} = Dashboards.create(%{title: "Grid", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = dashboard.layout
      %{dashboard: dashboard, id: id}
    end

    test "sets width/height within the widget type's bounds", %{dashboard: dashboard, id: id} do
      assert {:ok, updated} = Dashboards.resize_widget(dashboard, id, "desktop", 6, 3)
      assert %{"w" => 6, "h" => 3} = Layout.placement(hd(updated.layout), "desktop")
    end

    test "clamps to the widget min/max AND the breakpoint's columns", %{
      dashboard: dashboard,
      id: id
    } do
      # core.note: min %{w: 2, h: 1}, default max %{w: 12, h: 8}.
      assert {:ok, small} = Dashboards.resize_widget(dashboard, id, "desktop", 0, 0)
      assert %{"w" => 2, "h" => 1} = Layout.placement(hd(small.layout), "desktop")

      # Desktop = 12 cols → clamps to 12; phone = 4 cols → clamps to 4.
      assert {:ok, big} = Dashboards.resize_widget(dashboard, id, "desktop", 99, 99)
      assert %{"w" => 12, "h" => 8} = Layout.placement(hd(big.layout), "desktop")

      assert {:ok, phone} = Dashboards.resize_widget(dashboard, id, "phone", 99, 2)
      assert %{"w" => 4} = Layout.placement(hd(phone.layout), "phone")
    end

    test "grows until blocked by a neighbouring widget, never onto it", %{
      dashboard: dashboard,
      id: id
    } do
      # Park a second widget at (6, 0) — growing the first (at 0,0) past 6 wide
      # would overlap it, so the resize clamps to 6.
      {:ok, d} = Dashboards.add_widget(dashboard, "core.clock")
      other = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.place_widget_grid(d, other, "desktop", 6, 0)

      assert {:ok, resized} = Dashboards.resize_widget(d, id, "desktop", 10, 2)
      assert %{"w" => 6, "h" => 2} = Layout.placement(hd(resized.layout), "desktop")
    end
  end

  describe "place_widget_grid/5 (explicit cells)" do
    setup do
      {:ok, d0} = Dashboards.create(%{title: "Cells", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = dashboard.layout
      %{dashboard: dashboard, id: id}
    end

    test "places a widget at any free cell — gaps included — and persists", %{
      dashboard: d,
      id: id
    } do
      # Nothing occupies rows 1-4; drop the widget at (5, 4) leaving a hole.
      assert {:ok, placed} = Dashboards.place_widget_grid(d, id, "desktop", 5, 4)
      assert %{"x" => 5, "y" => 4} = Layout.placement(hd(placed.layout), "desktop")

      # Persisted, not just in the returned struct (force_change regression guard).
      assert %{"x" => 5, "y" => 4} =
               Layout.placement(hd(Dashboards.get(d.uuid).layout), "desktop")

      # The render path reflects it.
      assert [{_i, %{"x" => 5, "y" => 4}}] = Dashboards.resolve_items(placed, "desktop")
    end

    test "clamps into the tier's columns and the row cap", %{dashboard: d, id: id} do
      # 4-wide on desktop (12 cols): x clamps to 8; negative coords go to 0.
      assert {:ok, placed} = Dashboards.place_widget_grid(d, id, "desktop", 99, -3)
      assert %{"x" => 8, "y" => 0} = Layout.placement(hd(placed.layout), "desktop")
    end

    test "refuses a spot occupied by another widget", %{dashboard: d, id: id} do
      {:ok, d} = Dashboards.add_widget(d, "core.clock")
      other = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.place_widget_grid(d, other, "desktop", 6, 0)

      # Dropping the note (4 wide) at x=4 would overlap the clock at 6..8.
      assert {:error, :occupied} = Dashboards.place_widget_grid(d, id, "desktop", 4, 0)
      # The clear spot right below works.
      assert {:ok, _} = Dashboards.place_widget_grid(d, id, "desktop", 4, 2)
    end

    test "the first edit of a derived tier persists its materialization even when nothing changes",
         %{dashboard: d, id: id} do
      # TV derives from the desktop home. Resizing it to EXACTLY the derived size
      # must still pin + persist the tier (Ecto change/2 vs the pre-mutated
      # struct skipped this write before the force_change fix).
      derived = Dashboards.resolve_placement(d, id, "tv")
      {:ok, _} = Dashboards.resize_widget(d, id, "tv", derived["w"], derived["h"])

      stored = Dashboards.get(d.uuid)
      assert %{"x" => _, "y" => _} = get_in(hd(stored.layout), ["bp", "tv"])
      assert Dashboards.customized?(stored, "tv")
    end
  end

  describe "widget views" do
    test "add_widget seeds the widget type's default view" do
      {:ok, d0} = Dashboards.create(%{title: "V", scope: "system"})

      # core.module_stats declares views → default is the first ("detailed").
      {:ok, with_stats} = Dashboards.add_widget(d0, "core.module_stats")
      assert [%{"view" => "detailed"}] = with_stats.layout

      # core.note declares none → view is nil.
      {:ok, with_note} = Dashboards.add_widget(with_stats, "core.note")
      assert %{"widget_key" => "core.note", "view" => nil} = List.last(with_note.layout)
    end

    test "configure_widget updates settings and view together" do
      {:ok, d0} = Dashboards.create(%{title: "V", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.module_stats")
      [%{"id" => id}] = dashboard.layout

      assert {:ok, updated} =
               Dashboards.configure_widget(dashboard, id, %{
                 settings: %{"module_key" => "posts"},
                 view: "compact"
               })

      assert [%{"view" => "compact", "settings" => %{"module_key" => "posts"}}] = updated.layout
      assert_activity_logged("dashboard.widget_configured", resource_uuid: dashboard.uuid)
    end

    test "configure_widget leaves unspecified attrs untouched" do
      {:ok, d0} = Dashboards.create(%{title: "V", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.module_stats")
      [%{"id" => id}] = dashboard.layout

      # Only view given → settings preserved.
      {:ok, updated} = Dashboards.configure_widget(dashboard, id, %{view: "compact"})
      assert [%{"view" => "compact", "settings" => %{"module_key" => ""}}] = updated.layout
    end
  end

  describe "layout mode & pixel placement" do
    alias PhoenixKitDashboards.Schemas.Dashboard

    test "defaults to grid mode / 100% zoom" do
      {:ok, dashboard} = Dashboards.create(%{title: "M", scope: "system"})
      assert Dashboard.layout_mode(dashboard) == "grid"
      assert Dashboard.zoom(dashboard) == 100
    end

    test "set_layout_mode switches to free and back; ignores invalid" do
      {:ok, d0} = Dashboards.create(%{title: "M", scope: "system"})

      {:ok, free} = Dashboards.set_layout_mode(d0, "free")
      assert Dashboard.layout_mode(free) == "free"

      {:ok, bogus} = Dashboards.set_layout_mode(free, "nonsense")
      assert Dashboard.layout_mode(bogus) == "free"

      {:ok, grid} = Dashboards.set_layout_mode(bogus, "grid")
      assert Dashboard.layout_mode(grid) == "grid"
    end

    test "set_zoom clamps to 50–150" do
      {:ok, d0} = Dashboards.create(%{title: "M", scope: "system"})

      {:ok, d1} = Dashboards.set_zoom(d0, 10)
      assert Dashboard.zoom(d1) == 50

      {:ok, d2} = Dashboards.set_zoom(d1, 999)
      assert Dashboard.zoom(d2) == 150
    end
  end

  describe "free-canvas px geometry" do
    setup do
      {:ok, d0} = Dashboards.create(%{title: "Canvas", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = d1.layout
      %{dashboard: d1, id: id}
    end

    test "place_widget_px stores fx/fy, clamped to the top-left", %{dashboard: d, id: id} do
      {:ok, moved} = Dashboards.place_widget_px(d, id, 240, 130)
      assert %{"fx" => 240, "fy" => 130} = Layout.pixel(hd(moved.layout))

      {:ok, clamped} = Dashboards.place_widget_px(d, id, -50, -10)
      assert %{"fx" => 0, "fy" => 0} = Layout.pixel(hd(clamped.layout))
    end

    test "resize_widget_px stores fw/fh, clamped to [60, 4000]", %{dashboard: d, id: id} do
      {:ok, sized} = Dashboards.resize_widget_px(d, id, 320, 210)
      assert %{"fw" => 320, "fh" => 210} = Layout.pixel(hd(sized.layout))

      {:ok, clamped} = Dashboards.resize_widget_px(d, id, 5, 99_999)
      assert %{"fw" => 60, "fh" => 4000} = Layout.pixel(hd(clamped.layout))
    end

    test "px geometry does not disturb the grid placement", %{dashboard: d, id: id} do
      grid_before = Layout.placement(hd(d.layout), "desktop")
      {:ok, moved} = Dashboards.place_widget_px(d, id, 200, 100)
      {:ok, sized} = Dashboards.resize_widget_px(moved, id, 300, 200)
      # The pixel writes leave the grid placement untouched.
      assert Layout.placement(hd(sized.layout), "desktop") == grid_before
    end
  end

  describe "visible_to?/3" do
    test "personal to owner, system to all, role only for the given roles" do
      owner = Ecto.UUID.generate()
      role = Ecto.UUID.generate()

      personal = %Dashboard{scope: "personal", owner_user_uuid: owner}
      system = %Dashboard{scope: "system"}
      role_dash = %Dashboard{scope: "role", role_uuid: role}

      assert Dashboards.visible_to?(personal, owner, [])
      refute Dashboards.visible_to?(personal, "someone-else", [])
      assert Dashboards.visible_to?(system, "anyone", [])
      assert Dashboards.visible_to?(role_dash, "u", [role])
      refute Dashboards.visible_to?(role_dash, "u", [])
      # nil actor never matches a nil-owner personal dashboard.
      refute Dashboards.visible_to?(%Dashboard{scope: "personal", owner_user_uuid: nil}, nil, [])
    end
  end

  describe "hardening (hostile input can't brick a dashboard)" do
    test "reorder_widgets dedups ids so a duplicate can't persist two same-id instances" do
      {:ok, d0} = Dashboards.create(%{title: "H", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = d1.layout

      # Hostile [id, id] must not yield two entries with the same id (dedup) or a
      # duplicate LiveComponent id at render.
      {:ok, reordered} = Dashboards.reorder_widgets(d1, "desktop", [id, id, "ghost"])
      assert Enum.map(reordered.layout, & &1["id"]) == [id]
      assert ordered_ids(reordered, "desktop") == [id]
    end

    test "configure_widget coerces a non-map settings to an empty map" do
      {:ok, d0} = Dashboards.create(%{title: "H", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = d1.layout

      {:ok, updated} = Dashboards.configure_widget(d1, id, %{settings: "not-a-map"})
      assert [%{"settings" => %{}}] = updated.layout
    end
  end

  describe "Dashboard.type/1 (fixed at creation)" do
    test "reads config type, maps legacy mode, defaults to grid" do
      assert Dashboard.type(%Dashboard{config: %{"type" => "pixel"}}) == "pixel"
      assert Dashboard.type(%Dashboard{config: %{"type" => "grid"}}) == "grid"
      # Legacy config["mode"] still maps.
      assert Dashboard.type(%Dashboard{config: %{"mode" => "free"}}) == "pixel"
      assert Dashboard.type(%Dashboard{config: %{"mode" => "grid"}}) == "grid"
      assert Dashboard.type(%Dashboard{config: %{}}) == "grid"
    end

    test "layout_mode derives from type" do
      assert Dashboard.layout_mode(%Dashboard{config: %{"type" => "pixel"}}) == "free"
      assert Dashboard.layout_mode(%Dashboard{config: %{"type" => "grid"}}) == "grid"
    end
  end

  describe "responsive breakpoints" do
    setup do
      {:ok, d0} = Dashboards.create(%{title: "Resp", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      # Widen it to 10 cols on desktop so phone derivation must clamp.
      [%{"id" => id}] = d1.layout
      {:ok, d2} = Dashboards.resize_widget(d1, id, "desktop", 10, 2)
      %{dashboard: d2, id: id}
    end

    test "a tier is auto until edited; editing marks it custom", %{dashboard: d} do
      # `d`'s desktop tier was resized in setup → custom; every other tier is auto.
      assert Dashboards.customized?(d, "desktop")
      refute Dashboards.customized?(d, "tv")
      refute Dashboards.customized?(d, "ipad")
      refute Dashboards.customized?(d, "phone")
    end

    test "an auto tier derives from the customized one, clamping the span to its columns",
         %{dashboard: d} do
      # Desktop (customized, w=10) is the source; larger/smaller tiers derive from it.
      assert [{_i, %{"w" => 10}}] = Dashboards.resolve_items(d, "desktop")
      assert [{_i, %{"w" => 10}}] = Dashboards.resolve_items(d, "tv")
      assert [{_i, %{"w" => 8}}] = Dashboards.resolve_items(d, "ipad")
      assert [{_i, %{"w" => 4}}] = Dashboards.resolve_items(d, "phone")
    end

    test "a non-home tier derives from the home/designed tier, keeping placement" do
      # Made on a phone → phone is the home (designed) tier; larger tiers are auto.
      {:ok, d0} =
        Dashboards.create(%{title: "Up", scope: "system", config: %{"home_bp" => "phone"}})

      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = d1.layout
      {:ok, d2} = Dashboards.resize_widget(d1, id, "phone", 3, 5)

      assert Dashboards.home_bp(d2) == "phone"
      assert Dashboards.customized?(d2, "phone")
      refute Dashboards.customized?(d2, "desktop")

      # Stepping UP to an un-designed larger tier shows the SAME placement (span
      # kept, height carried) — the space just grew; it isn't re-flowed.
      assert [{_i, %{"w" => 3, "h" => 5}}] = Dashboards.resolve_items(d2, "desktop")
      assert [{_i, %{"w" => 3, "h" => 5}}] = Dashboards.resolve_items(d2, "tv")
    end

    test "editing a tier marks it customized and stops deriving", %{dashboard: d, id: id} do
      {:ok, d} = Dashboards.resize_widget(d, id, "phone", 2, 1)
      assert Dashboards.customized?(d, "phone")
      assert [{_i, %{"w" => 2, "h" => 1}}] = Dashboards.resolve_items(d, "phone")
      # Desktop is untouched by the phone edit.
      assert [{_i, %{"w" => 10}}] = Dashboards.resolve_items(d, "desktop")
    end

    test "hide_widget hides on a tier only; reset re-derives", %{dashboard: d, id: id} do
      {:ok, d} = Dashboards.hide_widget(d, id, "phone", true)
      assert Dashboards.resolve_hidden?(d, id, "phone")
      refute Dashboards.resolve_hidden?(d, id, "desktop")
      # Runtime filters hidden; builder (default) keeps them.
      assert Dashboards.resolve_items(d, "phone", visible: true) == []
      assert length(Dashboards.resolve_items(d, "phone")) == 1

      {:ok, d} = Dashboards.reset_breakpoint(d, "phone")
      refute Dashboards.customized?(d, "phone")
      refute Dashboards.resolve_hidden?(d, id, "phone")
      assert [{_i, %{"w" => 4}}] = Dashboards.resolve_items(d, "phone")
    end

    test "the default breakpoint can't be reset", %{dashboard: d} do
      {:ok, same} = Dashboards.reset_breakpoint(d, "desktop")
      assert Dashboards.customized?(same, "desktop")
    end

    test "editing a derived tier snapshots it — the derived geometry isn't lost" do
      {:ok, d0} = Dashboards.create(%{title: "Mat", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = d1.layout
      # Home = desktop; give it a distinctive shape there.
      {:ok, d2} = Dashboards.resize_widget(d1, id, "desktop", 6, 3)
      # TV (un-designed) derives from the desktop home → w6 (fits 16), h3.
      assert [{_i, %{"w" => 6, "h" => 3}}] = Dashboards.resolve_items(d2, "tv")

      # Hide on TV (first edit → TV becomes custom). Without the snapshot the widget
      # would snap to the default (w4/h2) since it has no stored TV placement.
      {:ok, d3} = Dashboards.hide_widget(d2, id, "tv", true)
      assert [{_i, %{"w" => 6, "h" => 3, "hidden" => true}}] = Dashboards.resolve_items(d3, "tv")
    end

    test "display_bp shows the screen's tier if designed, else the nearest designed one" do
      # Home = desktop (designed); phone/ipad/tv are auto.
      {:ok, d0} = Dashboards.create(%{title: "Disp", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")

      # A designed screen → itself; an un-designed screen → the nearest designed (home).
      assert Dashboards.display_bp(d1, "desktop") == "desktop"
      assert Dashboards.display_bp(d1, "phone") == "desktop"
      assert Dashboards.display_bp(d1, "tv") == "desktop"

      # Once phone is designed, a phone screen shows phone (not the scaled desktop).
      [%{"id" => id}] = d1.layout
      {:ok, d2} = Dashboards.resize_widget(d1, id, "phone", 2, 1)
      assert Dashboards.display_bp(d2, "phone") == "phone"
      # iPad (still auto) picks the nearest designed — desktop (nearer than phone).
      assert Dashboards.display_bp(d2, "ipad") == "desktop"
    end

    test "resolve_placement returns the DERIVED size on an auto tier (matches the render)" do
      {:ok, d0} = Dashboards.create(%{title: "RP", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = d1.layout
      {:ok, d2} = Dashboards.resize_widget(d1, id, "desktop", 10, 5)

      # TV (auto) derives from desktop → w10 (fits 16), h5 — NOT the default 4x2.
      assert %{"w" => 10, "h" => 5} = Dashboards.resolve_placement(d2, id, "tv")
      assert %{"w" => 10, "h" => 5} = Dashboards.resolve_placement(d2, id, "desktop")
      assert Dashboards.resolve_placement(d2, "nope", "tv") == nil
    end

    test "put_home_bp records the home only for a fresh, empty dashboard" do
      {:ok, fresh} = Dashboards.create(%{title: "Fresh", scope: "system"})
      {:ok, fresh} = Dashboards.put_home_bp(fresh, "phone")
      assert Dashboards.home_bp(fresh) == "phone"

      # Once it has a home (or any widgets), it won't move under another viewer.
      {:ok, fresh} = Dashboards.put_home_bp(fresh, "tv")
      assert Dashboards.home_bp(fresh) == "phone"

      {:ok, used} = Dashboards.create(%{title: "Used", scope: "system"})
      {:ok, used} = Dashboards.add_widget(used, "core.note")
      {:ok, used} = Dashboards.put_home_bp(used, "phone")
      assert Dashboards.home_bp(used) == "desktop"
    end
  end
end
