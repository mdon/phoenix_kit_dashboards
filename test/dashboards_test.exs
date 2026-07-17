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

      {:ok, shared} =
        Dashboards.create(%{title: "Team KPIs", scope: "system", config: %{"type" => "pixel"}})

      {:ok, shared} = Dashboards.add_widget(shared, "core.note")
      [%{"id" => source_id}] = shared.layout

      assert {:ok, clone} = Dashboards.clone(shared, user.uuid, actor_uuid: user.uuid)

      # A clone logs as a create but stays distinguishable in the audit trail.
      assert_activity_logged("dashboard.created",
        actor_uuid: user.uuid,
        resource_uuid: clone.uuid,
        metadata_has: %{"cloned_from" => shared.uuid}
      )

      assert clone.scope == "personal"
      assert clone.owner_user_uuid == user.uuid
      assert clone.title == "Team KPIs (copy)"
      # Config (incl. the fixed type) carried over.
      assert clone.config["type"] == "pixel"
      # Layout copied but with a NEW instance id (independent from the source).
      assert [%{"widget_key" => "core.note", "id" => clone_id}] = clone.layout
      assert clone_id != source_id
    end
  end

  describe "pixel-canvas bounds" do
    test "crafted huge coordinates are bounded to one screen past existing content" do
      {:ok, dashboard} =
        Dashboards.create(%{title: "Px", scope: "system", config: %{"type" => "pixel"}})

      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = dashboard.layout

      # A crafted coordinate on the SOLE widget clamps to one screen (4000px),
      # not the 20000 hard cap — a single move_widget_to can't balloon the
      # shared canvas for every viewer (review finding #2).
      {:ok, dashboard} = Dashboards.place_widget_px(dashboard, id, 1_000_000_000, -50)
      note = hd(dashboard.layout)
      assert Layout.pixel(note)["fx"] == 4000
      assert Layout.pixel(note)["fy"] == 0

      # A newly-added widget is bounded to one screen past the furthest existing
      # edge — well under the 20000 hard cap, so the canvas can't be ballooned.
      {:ok, dashboard} =
        Dashboards.add_widget_px(dashboard, "core.clock", 999_999_999, 999_999_999)

      clock = Enum.find(dashboard.layout, &(&1["widget_key"] == "core.clock"))
      note_right = Layout.pixel(note)["fx"] + Layout.pixel(note)["fw"]
      assert Layout.pixel(clock)["fx"] <= note_right + 4000
      assert Layout.pixel(clock)["fx"] < 20_000
    end
  end

  describe "optimistic concurrency (no silent lost updates)" do
    test "a write from a stale snapshot is refused, never clobbers the newer state" do
      {:ok, d0} = Dashboards.create(%{title: "Race", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")

      # `d1` is now stale relative to the DB after this second write lands...
      {:ok, _d2} = Dashboards.add_widget(d1, "core.clock")

      # ...so a third write built on `d1` must be rejected, not silently
      # overwrite the clock that `d2` added.
      assert {:error, :stale} = Dashboards.add_widget(d1, "core.module_stats")

      # The clock survived; the stale write dropped nothing.
      keys = Dashboards.get(d0.uuid).layout |> Enum.map(& &1["widget_key"])
      assert "core.clock" in keys
      refute "core.module_stats" in keys
    end

    test "threading the returned struct lets sequential edits proceed" do
      {:ok, d0} = Dashboards.create(%{title: "Seq", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      {:ok, d2} = Dashboards.add_widget(d1, "core.clock")
      assert {:ok, _d3} = Dashboards.add_widget(d2, "core.module_stats")
      assert length(Dashboards.get(d0.uuid).layout) == 3
    end

    test "a metadata update/3 from a stale snapshot is also refused with :error, :stale" do
      # update/3 (title/scope) shares persist/1's CAS with every other mutation —
      # DashboardFormLive's do_update/2 must route this through resync, not the
      # generic changeset-error branch (it's a distinct return, not a changeset).
      {:ok, d0} = Dashboards.create(%{title: "Race", scope: "system"})
      {:ok, _d1} = Dashboards.add_widget(d0, "core.note")

      assert {:error, :stale} = Dashboards.update(d0, %{title: "Clobbered"})
      assert Dashboards.get(d0.uuid).title == "Race"
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
      assert Layout.placement(instance, "l1") ==
               %{"x" => 0, "y" => 0, "w" => 16, "h" => 8, "hidden" => false, "pos" => 0}

      assert %{"fw" => fw, "fh" => fh} = Layout.pixel(instance)
      assert fw == 16 * 25 and fh == 8 * 25
      assert instance["settings"] == %{"title" => "Note", "body" => ""}

      assert_activity_logged("dashboard.widget_added",
        resource_uuid: dashboard.uuid,
        metadata_has: %{"widget_key" => "core.note"}
      )
    end

    test "add_widget rejects an unknown widget key", %{dashboard: dashboard} do
      assert {:error, :unknown_widget} = Dashboards.add_widget(dashboard, "nope.missing")
    end

    test "add_widget clamps the seeded span to a tiny layout's dims", %{dashboard: dashboard} do
      # A 4x4 screenful can't hold the note's 16x8 default — the seed clamps
      # to the layout so no part of the widget lands past the edges.
      {:ok, tiny} = Dashboards.set_grid_dims(dashboard, "l1", 4, 4)
      {:ok, tiny} = Dashboards.add_widget(tiny, "core.note")
      [instance] = tiny.layout
      assert %{"x" => 0, "y" => 0, "w" => 4, "h" => 4} = Layout.placement(instance, "l1")
    end

    test "remove_widget drops the instance by id", %{dashboard: dashboard} do
      {:ok, with_widget} = Dashboards.add_widget(dashboard, "core.clock")
      [%{"id" => id}] = with_widget.layout

      assert {:ok, emptied} = Dashboards.remove_widget(with_widget, id)
      assert emptied.layout == []
      assert_activity_logged("dashboard.widget_removed", resource_uuid: dashboard.uuid)
    end

    test "configure_widget replaces a single instance's settings", %{dashboard: dashboard} do
      {:ok, with_widget} = Dashboards.add_widget(dashboard, "core.note")
      [%{"id" => id}] = with_widget.layout

      assert {:ok, updated} =
               Dashboards.configure_widget(with_widget, id, %{
                 settings: %{"title" => "Hi", "body" => "x"}
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
      assert {:ok, reordered} = Dashboards.reorder_widgets(d, "l1", [c, a, b])
      assert ordered_ids(reordered, "l1") == [c, a, b]
    end

    test "ignores unknown ids and appends unnamed widgets", %{dashboard: d, ids: [a, b, c]} do
      assert {:ok, reordered} = Dashboards.reorder_widgets(d, "l1", [b, "ghost", a])
      # b, a named (ghost dropped); c unnamed → appended after.
      assert ordered_ids(reordered, "l1") == [b, a, c]
    end

    test "is not activity-logged (layout tweak)", %{dashboard: d, ids: ids} do
      {:ok, _} = Dashboards.reorder_widgets(d, "l1", Enum.reverse(ids))
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
      assert {:ok, updated} = Dashboards.resize_widget(dashboard, id, "l1", 24, 12)
      assert %{"w" => 24, "h" => 12} = Layout.placement(hd(updated.layout), "l1")
    end

    test "clamps to the widget min/max AND the breakpoint's columns", %{
      dashboard: dashboard,
      id: id
    } do
      # core.note: min %{w: 8, h: 4}.
      assert {:ok, small} = Dashboards.resize_widget(dashboard, id, "l1", 0, 0)
      assert %{"w" => 8, "h" => 4} = Layout.placement(hd(small.layout), "l1")

      # The default layout is a 64×36 screenful → the span clamps to it (a
      # widget can never resize past the screenful's edges). Thread `small`:
      # the optimistic lock rejects a second write from the stale `dashboard`.
      assert {:ok, big} = Dashboards.resize_widget(small, id, "l1", 999, 999)
      assert %{"w" => 64, "h" => 36} = Layout.placement(hd(big.layout), "l1")
    end

    test "the resize floor follows the instance's selected VIEW (per-view min_size)", %{
      dashboard: dashboard
    } do
      # An analog clock's floor is 8x8; a normal one's is 8x4.
      {:ok, d} = Dashboards.add_widget(dashboard, "core.clock")
      clock = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.configure_widget(d, clock, %{view: "analog"})

      {:ok, tiny} = Dashboards.resize_widget(d, clock, "l1", 1, 1)
      placement = Dashboards.resolve_placement(tiny, clock, "l1")
      assert %{"w" => 8, "h" => 8} = placement

      {:ok, d} = Dashboards.configure_widget(tiny, clock, %{view: "normal"})
      {:ok, tiny2} = Dashboards.resize_widget(d, clock, "l1", 1, 1)
      assert %{"w" => 8, "h" => 4} = Dashboards.resolve_placement(tiny2, clock, "l1")
    end

    test "min_override drops the recommended floor to 1x1 for that instance", %{
      dashboard: dashboard
    } do
      {:ok, d} = Dashboards.add_widget(dashboard, "core.clock")
      clock = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.configure_widget(d, clock, %{view: "analog"})

      # Recommended floor holds…
      {:ok, held} = Dashboards.resize_widget(d, clock, "l1", 1, 1)
      assert %{"w" => 8, "h" => 8} = Dashboards.resolve_placement(held, clock, "l1")

      # …until the user opts out; turning it back on restores the floor.
      {:ok, d} = Dashboards.configure_widget(held, clock, %{min_override: true})
      {:ok, tiny} = Dashboards.resize_widget(d, clock, "l1", 1, 1)
      assert %{"w" => 1, "h" => 1} = Dashboards.resolve_placement(tiny, clock, "l1")

      {:ok, d} = Dashboards.configure_widget(tiny, clock, %{min_override: false})
      {:ok, restored} = Dashboards.resize_widget(d, clock, "l1", 1, 1)
      assert %{"w" => 8, "h" => 8} = Dashboards.resolve_placement(restored, clock, "l1")
    end

    test "switching to a view with a larger minimum grows the placement where free", %{
      dashboard: dashboard
    } do
      {:ok, d} = Dashboards.add_widget(dashboard, "core.clock")
      clock = List.last(d.layout)["id"]
      # Shrink to the normal view's floor (12x4 keeps digital legal too).
      {:ok, d} = Dashboards.resize_widget(d, clock, "l1", 12, 4)
      assert %{"h" => 4} = Dashboards.resolve_placement(d, clock, "l1")

      # Analog needs 8x8 → the switch grows the height in place.
      {:ok, grown} = Dashboards.configure_widget(d, clock, %{view: "analog"})
      assert %{"w" => 12, "h" => 8} = Dashboards.resolve_placement(grown, clock, "l1")
    end

    test "view-switch growth is skipped where a neighbour blocks it", %{dashboard: dashboard} do
      # The setup note sits at (0,0) 16x8; park the clock beside it on row 0.
      {:ok, d} = Dashboards.add_widget(dashboard, "core.clock")
      clock = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.place_widget_grid(d, clock, "l1", 20, 0)
      {:ok, d} = Dashboards.resize_widget(d, clock, "l1", 12, 4)

      # A note parked directly below blocks the analog growth into row 4.
      {:ok, d} = Dashboards.add_widget(d, "core.note")
      note = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.place_widget_grid(d, note, "l1", 20, 4)

      {:ok, kept} = Dashboards.configure_widget(d, clock, %{view: "analog"})
      # Blocked → keeps 12x4 (the analog face just renders smaller than ideal).
      assert %{"w" => 12, "h" => 4} = Dashboards.resolve_placement(kept, clock, "l1")
    end

    test "grows until blocked by a neighbouring widget, never onto it", %{
      dashboard: dashboard,
      id: id
    } do
      # Park a second widget at (24, 0) — growing the first (at 0,0) past 24
      # wide would overlap it, so the resize clamps to 24.
      {:ok, d} = Dashboards.add_widget(dashboard, "core.clock")
      other = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.place_widget_grid(d, other, "l1", 24, 0)

      assert {:ok, resized} = Dashboards.resize_widget(d, id, "l1", 40, 8)
      assert %{"w" => 24, "h" => 8} = Layout.placement(hd(resized.layout), "l1")
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
      assert {:ok, placed} = Dashboards.place_widget_grid(d, id, "l1", 5, 4)
      assert %{"x" => 5, "y" => 4} = Layout.placement(hd(placed.layout), "l1")

      # Persisted, not just in the returned struct (force_change regression guard).
      assert %{"x" => 5, "y" => 4} =
               Layout.placement(hd(Dashboards.get(d.uuid).layout), "l1")

      # The render path reflects it.
      assert [{_i, %{"x" => 5, "y" => 4}}] = Dashboards.resolve_items(placed, "l1")
    end

    test "clamps into the layout's columns and rows", %{dashboard: d, id: id} do
      # 16-wide on the 64-col screenful: x clamps to 48; negative coords go to 0.
      assert {:ok, placed} = Dashboards.place_widget_grid(d, id, "l1", 999, -3)
      assert %{"x" => 48, "y" => 0} = Layout.placement(hd(placed.layout), "l1")
    end

    test "refuses a spot occupied by another widget", %{dashboard: d, id: id} do
      {:ok, d} = Dashboards.add_widget(d, "core.clock")
      other = List.last(d.layout)["id"]
      {:ok, d} = Dashboards.place_widget_grid(d, other, "l1", 24, 0)

      # Dropping the note (16 wide) at x=16 would overlap the clock at 24..36.
      assert {:error, :occupied} = Dashboards.place_widget_grid(d, id, "l1", 16, 0)
      # The clear spot right below works.
      assert {:ok, _} = Dashboards.place_widget_grid(d, id, "l1", 16, 8)
    end

    test "add_widget_at drops a catalog widget at the given cell",
         %{dashboard: d} do
      assert {:ok, added} = Dashboards.add_widget_at(d, "core.clock", "l1", 20, 16)

      clock = List.last(added.layout)
      assert clock["widget_key"] == "core.clock"
      # core.clock default 12x8, placed exactly where dropped.
      assert %{"x" => 20, "y" => 16, "w" => 12, "h" => 8} = Layout.placement(clock, "l1")

      assert_activity_logged("dashboard.widget_added",
        resource_uuid: d.uuid,
        metadata_has: %{"widget_key" => "core.clock"}
      )
    end

    test "add_widget_at clamps into the tier and refuses an occupied cell", %{
      dashboard: d,
      id: id
    } do
      # The note sits at (0,0) 16x8 — dropping onto it is refused.
      {:ok, d} = Dashboards.place_widget_grid(d, id, "l1", 0, 0)
      assert {:error, :occupied} = Dashboards.add_widget_at(d, "core.clock", "l1", 4, 0)

      # A far-out x clamps to the right edge (64 - 12) instead of failing.
      assert {:ok, added} = Dashboards.add_widget_at(d, "core.clock", "l1", 999, 0)
      assert %{"x" => 52, "y" => 0} = Layout.placement(List.last(added.layout), "l1")
    end

    test "add_widget_at and add_widget_px reject an unknown widget key", %{dashboard: d} do
      assert {:error, :unknown_widget} =
               Dashboards.add_widget_at(d, "nope.missing", "l1", 0, 0)

      assert {:error, :unknown_widget} = Dashboards.add_widget_px(d, "nope.missing", 10, 10)
    end

    test "add_widget_px drops a catalog widget at exact canvas px", %{dashboard: d} do
      assert {:ok, added} = Dashboards.add_widget_px(d, "core.clock", 250, 480)
      assert %{"fx" => 250, "fy" => 480} = Layout.pixel(List.last(added.layout))

      # Negative coordinates clamp to the top-left.
      assert {:ok, added2} = Dashboards.add_widget_px(added, "core.note", -50, -10)
      assert %{"fx" => 0, "fy" => 0} = Layout.pixel(List.last(added2.layout))
    end

    test "the first edit of a packed-at-render placement pins + persists it",
         %{dashboard: d} do
      # A second layout; then a NEW widget seeded only into the first layout —
      # in the second it packs at render. Resizing it there to EXACTLY the
      # packed size must still pin + persist (Ecto change/2 vs the pre-mutated
      # struct skipped this write before the force_change fix).
      {:ok, d, entry} = Dashboards.add_layout(d, "l1")
      {:ok, d} = Dashboards.add_widget(d, "core.clock")
      clock = List.last(d.layout)
      refute get_in(clock, ["bp", entry["id"]])

      packed = Dashboards.resolve_placement(d, clock["id"], entry["id"])
      {:ok, _} = Dashboards.resize_widget(d, clock["id"], entry["id"], packed["w"], packed["h"])

      stored = Dashboards.get(d.uuid)
      stored_clock = List.last(stored.layout)
      assert %{"x" => _, "y" => _} = get_in(stored_clock, ["bp", entry["id"]])
    end
  end

  describe "get/1 id validation" do
    test "a malformed (non-uuid) id returns nil, never raises Ecto.Query.CastError" do
      assert Dashboards.get("not-a-uuid") == nil
      assert Dashboards.get("") == nil
      # A well-formed but absent uuid is nil too.
      assert Dashboards.get(Ecto.UUID.generate()) == nil
    end
  end

  describe "grid dimensions (set_grid_dims/4)" do
    setup do
      {:ok, d0} = Dashboards.create(%{title: "Dims", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.note")
      %{dashboard: dashboard}
    end

    test "defaults come from the layout entry (a 16:9 screenful)", %{dashboard: d} do
      assert Dashboards.grid_cols(d, "l1") == 64
      assert Dashboards.grid_rows(d, "l1") == 36
      # Unknown ids fall back to the default screenful.
      assert Dashboards.grid_cols(d, "ghost") == 64
      assert Dashboards.grid_rows(d, "ghost") == 36
    end

    test "setting explicit dims updates the layout entry and persists", %{dashboard: d} do
      assert {:ok, d1} = Dashboards.set_grid_dims(d, "l1", 65, 37)
      assert Dashboards.grid_cols(d1, "l1") == 65
      assert Dashboards.grid_rows(d1, "l1") == 37

      # Persisted, not just in the returned struct.
      reloaded = Dashboards.get(d.uuid)
      assert Dashboards.grid_cols(reloaded, "l1") == 65
      assert Dashboards.grid_rows(reloaded, "l1") == 37

      # Unknown layout ids are a no-op.
      assert {:ok, _} = Dashboards.set_grid_dims(d1, "ghost", 40, 40)

      # "Fit this screen": 1920x1080 at 25px cells → 77x43.
      assert {:ok, d3} = Dashboards.set_grid_dims(d1, "l1", 77, 43)
      assert Dashboards.grid_cols(d3, "l1") == 77
      assert Dashboards.grid_rows(d3, "l1") == 43
    end

    test "a later per-widget edit keeps the layout's dimensions", %{dashboard: d} do
      {:ok, d1} = Dashboards.set_grid_dims(d, "l1", 65, 36)
      [%{"id" => id}] = d1.layout
      {:ok, d2} = Dashboards.place_widget_grid(d1, id, "l1", 2, 2)
      assert Dashboards.grid_cols(d2, "l1") == 65
    end

    test "shrinking clamps to the extent widgets occupy (never cuts into one)", %{
      dashboard: d
    } do
      [%{"id" => id}] = d.layout
      # Park the 16x8 note at the right edge of the 64-col screenful (x=48).
      {:ok, d1} = Dashboards.place_widget_grid(d, id, "l1", 48, 0)
      # A shrink attempt clamps back to the occupied extent (64), not below.
      assert {:ok, held} = Dashboards.set_grid_dims(d1, "l1", 40, 36)
      assert Dashboards.grid_cols(held, "l1") == 64

      # Rows shrink freely down to the widget's extent (8).
      assert {:ok, d2} = Dashboards.set_grid_dims(held, "l1", 64, 6)
      assert Dashboards.grid_rows(d2, "l1") == 8

      # Move the widget home and the column shrink goes through.
      {:ok, d3} = Dashboards.place_widget_grid(d2, id, "l1", 0, 0)
      assert {:ok, d4} = Dashboards.set_grid_dims(d3, "l1", 40, 8)
      assert Dashboards.grid_cols(d4, "l1") == 40
    end

    test "bounds clamp: dims stay within the lattice's 4..160", %{dashboard: d} do
      assert {:ok, d_max} = Dashboards.set_grid_dims(d, "l1", 999, 999)
      assert Dashboards.grid_cols(d_max, "l1") == 160
      assert Dashboards.grid_rows(d_max, "l1") == 160
      # The floor is min_dim (4) — but never below the occupied extent (the
      # 16x8 note at 0,0 holds 16 cols / 8 rows).
      assert {:ok, d_min} = Dashboards.set_grid_dims(d_max, "l1", 1, 1)
      assert Dashboards.grid_cols(d_min, "l1") == 16
      assert Dashboards.grid_rows(d_min, "l1") == 8
    end

    test "placement math honors a widened grid", %{dashboard: d} do
      [%{"id" => id}] = d.layout
      {:ok, d1} = Dashboards.set_grid_dims(d, "l1", 65, 36)
      # x=49 with w=16 fits on a 65-col grid (49+16=65) but not the default 64.
      assert {:ok, placed} = Dashboards.place_widget_grid(d1, id, "l1", 49, 0)
      assert %{"x" => 49} = Layout.placement(hd(placed.layout), "l1")
    end

    test "deleting a layout removes its dimensions with it", %{dashboard: d} do
      {:ok, d1, entry} = Dashboards.add_layout(d, "l1")
      {:ok, d2} = Dashboards.set_grid_dims(d1, entry["id"], 65, 36)
      assert Dashboards.grid_cols(d2, entry["id"]) == 65
      {:ok, d3} = Dashboards.delete_layout(d2, entry["id"])
      # Back to the fallback default for the unknown id.
      assert Dashboards.grid_cols(d3, entry["id"]) == 64
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

    test "configure_widget drops non-scalar settings values (anti-brick)" do
      {:ok, d0} = Dashboards.create(%{title: "V", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = dashboard.layout

      # A nested map/list in a settings value would crash the widget's render
      # on every later mount — only JSON scalars are kept.
      {:ok, updated} =
        Dashboards.configure_widget(dashboard, id, %{
          settings: %{"body" => %{"x" => 1}, "title" => "ok", "n" => 3, "flag" => true}
        })

      [%{"settings" => settings}] = updated.layout
      refute Map.has_key?(settings, "body")
      assert settings == %{"title" => "ok", "n" => 3, "flag" => true}
    end

    test "configure_widget drops a view the widget type does not declare" do
      {:ok, d0} = Dashboards.create(%{title: "V", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.clock")
      [%{"id" => id}] = dashboard.layout

      {:ok, updated} = Dashboards.configure_widget(dashboard, id, %{view: "not-a-clock-view"})
      # Unchanged from the seeded default ("normal"), never the crafted key.
      assert [%{"view" => "normal"}] = updated.layout
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

    test "defaults to grid mode" do
      {:ok, dashboard} = Dashboards.create(%{title: "M", scope: "system"})
      assert Dashboard.layout_mode(dashboard) == "grid"
    end

    test "restack_widget_px brings a pixel widget above / below every other" do
      {:ok, d} = Dashboards.create(%{title: "M", scope: "system"})
      {:ok, d} = Dashboards.add_widget(d, "core.note")
      {:ok, d} = Dashboards.add_widget(d, "core.clock")
      {:ok, d} = Dashboards.add_widget(d, "core.note")
      [a, b, c] = Enum.map(d.layout, & &1["id"])

      z = fn dash, id ->
        dash.layout |> Enum.find(&(&1["id"] == id)) |> Layout.pixel() |> Map.get("z")
      end

      # Front: above every other z; back: below (z survives a later move —
      # put_pixel merges).
      {:ok, d} = Dashboards.restack_widget_px(d, a, "front")
      assert z.(d, a) == 1

      {:ok, d} = Dashboards.restack_widget_px(d, b, "front")
      assert z.(d, b) == 2

      # Back goes below the OTHERS' minimum (a=1, b=2 → 0); a second back from
      # there goes negative.
      {:ok, d} = Dashboards.restack_widget_px(d, c, "back")
      assert z.(d, c) == 0

      {:ok, d} = Dashboards.restack_widget_px(d, a, "back")
      assert z.(d, a) == -1

      {:ok, d} = Dashboards.place_widget_px(d, b, 40, 40)
      assert z.(d, b) == 2
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

      # Thread `moved` — a second write from the stale `d` is refused by the lock.
      {:ok, clamped} = Dashboards.place_widget_px(moved, id, -50, -10)
      assert %{"fx" => 0, "fy" => 0} = Layout.pixel(hd(clamped.layout))
    end

    test "resize_widget_px stores fw/fh, clamped to [60, 4000]", %{dashboard: d, id: id} do
      {:ok, sized} = Dashboards.resize_widget_px(d, id, 320, 210)
      assert %{"fw" => 320, "fh" => 210} = Layout.pixel(hd(sized.layout))

      {:ok, clamped} = Dashboards.resize_widget_px(sized, id, 5, 99_999)
      assert %{"fw" => 60, "fh" => 4000} = Layout.pixel(hd(clamped.layout))
    end

    test "px geometry does not disturb the grid placement", %{dashboard: d, id: id} do
      grid_before = Layout.placement(hd(d.layout), "l1")
      {:ok, moved} = Dashboards.place_widget_px(d, id, 200, 100)
      {:ok, sized} = Dashboards.resize_widget_px(moved, id, 300, 200)
      # The pixel writes leave the grid placement untouched.
      assert Layout.placement(hd(sized.layout), "l1") == grid_before
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
      {:ok, reordered} = Dashboards.reorder_widgets(d1, "l1", [id, id, "ghost"])
      assert Enum.map(reordered.layout, & &1["id"]) == [id]
      assert ordered_ids(reordered, "l1") == [id]
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

  describe "set_layout_view/4 (per-layout view)" do
    test "grows the placement on that layout to the new view's minimum" do
      {:ok, d0} = Dashboards.create(%{title: "L", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.clock")
      [%{"id" => id}] = dashboard.layout
      # Shrink to the normal-view minimum first.
      {:ok, dashboard} = Dashboards.resize_widget(dashboard, id, "l1", 8, 4)
      assert %{"w" => 8, "h" => 4} = Dashboards.resolve_placement(dashboard, id, "l1")

      # Analog needs 8x8 — switching the view grows the placement to meet it.
      {:ok, dashboard} = Dashboards.set_layout_view(dashboard, id, "l1", "analog")
      assert %{"w" => w, "h" => h} = Dashboards.resolve_placement(dashboard, id, "l1")
      assert w >= 8 and h >= 8
    end

    test "ignores a view the widget type does not declare" do
      {:ok, d0} = Dashboards.create(%{title: "L", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(d0, "core.clock")
      [%{"id" => id}] = dashboard.layout

      {:ok, updated} = Dashboards.set_layout_view(dashboard, id, "l1", "bogus")
      assert PhoenixKitDashboards.Layout.view(hd(updated.layout), "l1") == "normal"
    end
  end

  describe "layouts (user-defined grids)" do
    setup do
      {:ok, d0} = Dashboards.create(%{title: "Lay", scope: "system"})
      {:ok, d1} = Dashboards.add_widget(d0, "core.note")
      [%{"id" => id}] = d1.layout
      {:ok, d2} = Dashboards.resize_widget(d1, id, "l1", 10, 2)
      %{dashboard: d2, id: id}
    end

    test "a fresh dashboard gets the default 16:9 screenful layout", %{dashboard: d} do
      assert [%{"id" => "l1", "name" => "Layout 1", "cols" => 64, "rows" => 36}] =
               Dashboards.layouts(d)

      assert Dashboards.first_layout_id(d) == "l1"
      assert Dashboards.get_layout(d, "nope") == nil
    end

    test "add_layout copies the source dims + placements and persists", %{dashboard: d, id: id} do
      assert {:ok, d2, entry} = Dashboards.add_layout(d, "l1")
      assert entry["name"] == "Layout 2"
      assert entry["cols"] == 64 and entry["rows"] == 36

      # Seeded: the widget carries the SAME placement under the new layout id.
      src = Dashboards.resolve_placement(d2, id, "l1")
      seeded = Dashboards.resolve_placement(d2, id, entry["id"])
      assert Map.take(seeded, ~w(x y w h)) == Map.take(src, ~w(x y w h))

      # Persisted (config gains the layouts list, snapshotting the legacy one).
      reloaded = Dashboards.get(d.uuid)
      assert [%{"id" => "l1"}, %{"id" => new_id}] = Dashboards.layouts(reloaded)
      assert new_id == entry["id"]
    end

    test "rename_layout renames (blank ignored) and persists", %{dashboard: d} do
      {:ok, d, entry} = Dashboards.add_layout(d, "l1")
      {:ok, d} = Dashboards.rename_layout(d, entry["id"], "  Wall TV  ")
      assert Dashboards.get_layout(d, entry["id"])["name"] == "Wall TV"

      {:ok, same} = Dashboards.rename_layout(d, entry["id"], "   ")
      assert Dashboards.get_layout(same, entry["id"])["name"] == "Wall TV"

      assert Dashboards.get_layout(Dashboards.get(d.uuid), entry["id"])["name"] == "Wall TV"
    end

    test "delete_layout strips per-widget placements; the last layout is protected",
         %{dashboard: d, id: id} do
      assert {:error, :last_layout} = Dashboards.delete_layout(d, "l1")

      {:ok, d, entry} = Dashboards.add_layout(d, "l1")
      assert get_in(hd(d.layout), ["bp", entry["id"]])

      {:ok, d} = Dashboards.delete_layout(d, entry["id"])
      assert [%{"id" => "l1"}] = Dashboards.layouts(d)
      refute get_in(hd(d.layout), ["bp", entry["id"]])
      # The widget lives on in the remaining layout.
      assert [{%{"id" => ^id}, _p}] = Dashboards.resolve_items(d, "l1")

      # Unknown id is a no-op.
      assert {:ok, _} = Dashboards.delete_layout(d, "ghost")
    end

    test "a widget without a stored placement packs first-fit (clamped) at render",
         %{dashboard: d} do
      # Second layout, then a new widget seeded only into the FIRST layout.
      {:ok, d, entry} = Dashboards.add_layout(d, "l1")
      {:ok, d} = Dashboards.add_widget(d, "core.clock")
      clock = List.last(d.layout)
      refute get_in(clock, ["bp", entry["id"]])

      # It still renders in the second layout — packed into a free cell.
      items = Dashboards.resolve_items(d, entry["id"])
      assert length(items) == 2
      {_c, packed} = Enum.find(items, fn {i, _} -> i["id"] == clock["id"] end)
      assert is_integer(packed["x"]) and is_integer(packed["y"])
      # resolve_placement mirrors the render exactly.
      assert Dashboards.resolve_placement(d, clock["id"], entry["id"]) == packed
    end

    test "hide_widget hides on one layout only", %{dashboard: d, id: id} do
      {:ok, d, entry} = Dashboards.add_layout(d, "l1")
      {:ok, d} = Dashboards.hide_widget(d, id, entry["id"], true)

      assert Dashboards.resolve_hidden?(d, id, entry["id"])
      refute Dashboards.resolve_hidden?(d, id, "l1")
      # Runtime filters hidden; builder (default) keeps them.
      assert Dashboards.resolve_items(d, entry["id"], visible: true) == []
      assert length(Dashboards.resolve_items(d, entry["id"])) == 1
    end
  end
end
