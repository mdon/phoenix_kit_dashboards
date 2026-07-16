defmodule PhoenixKitDashboards.Web.DashboardsLiveTest do
  use PhoenixKitDashboards.LiveCase

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Schemas.Dashboard

  defp sign_in(conn) do
    user = user_fixture()
    scope = fake_scope(user_uuid: user.uuid)
    {put_test_scope(conn, scope), user}
  end

  describe "index" do
    test "renders the empty state with no dashboards", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, _view, html} = live(conn, "/en/admin/dashboards")
      # No in-page <h1> — the admin header breadcrumb carries the page title.
      assert html =~ "Create dashboard"
      assert html =~ "No dashboards yet"
    end

    test "lists the user's dashboards", %{conn: conn} do
      {conn, user} = sign_in(conn)
      _dashboard = fixture_dashboard(user.uuid, %{title: "My Ops Board"})

      {:ok, _view, html} = live(conn, "/en/admin/dashboards")
      assert html =~ "My Ops Board"
    end
  end

  describe "create" do
    test "the Create button links to the dedicated form page", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, _view, html} = live(conn, "/en/admin/dashboards")

      # The old create modal is gone — creating happens on its own page.
      refute html =~ "dashboard-create-modal"
      assert html =~ "/en/admin/dashboards/new"
    end

    test "the form page creates a dashboard and live-redirects to its builder", %{conn: conn} do
      {conn, user} = sign_in(conn)
      {:ok, view, html} = live(conn, "/en/admin/dashboards/new")
      assert html =~ ~s(name="title")

      {:error, {:live_redirect, %{to: to}}} =
        view |> form("#dashboard-form", %{"title" => "Fresh Board"}) |> render_submit()

      assert to =~ "/en/admin/dashboards/"

      assert [%{title: "Fresh Board"}] = Dashboards.list_for_user(user.uuid)
      assert_activity_logged("dashboard.created", actor_uuid: user.uuid)
    end

    test "the chosen type is stored in config (grid by default, pixel when selected)", %{
      conn: conn
    } do
      {conn, _user} = sign_in(conn)
      {:ok, view, _html} = live(conn, "/en/admin/dashboards/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#dashboard-form", %{"title" => "Canvas One", "type" => "pixel"})
        |> render_submit()

      "/en/admin/dashboards/" <> uuid = to
      assert Dashboards.get(uuid).config["type"] == "pixel"
      assert Dashboard.type(Dashboards.get(uuid)) == "pixel"
    end
  end

  describe "edit" do
    test "updates title and visibility; the type select is locked", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{title: "Before"})

      {:ok, view, html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}/edit")
      # Type is fixed at creation: no submittable type select on edit.
      refute html =~ ~s(name="type")
      assert html =~ ~s(name="type_locked")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#dashboard-form", %{"title" => "After", "scope" => "system"})
        |> render_submit()

      assert to =~ "/en/admin/dashboards"
      updated = Dashboards.get(dashboard.uuid)
      assert updated.title == "After"
      assert updated.scope == "system"
      assert updated.owner_user_uuid == nil
      assert_activity_logged("dashboard.updated", actor_uuid: user.uuid)
    end

    test "someone else's personal dashboard is not editable", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      other = user_fixture()
      foreign = fixture_dashboard(other.uuid, %{title: "Not Yours"})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/dashboards/#{foreign.uuid}/edit")

      assert to =~ "/en/admin/dashboards"
    end
  end

  describe "create shared" do
    test "creates a system (shared) dashboard when scope=system", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, view, _html} = live(conn, "/en/admin/dashboards/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#dashboard-form", %{"title" => "Team Board", "scope" => "system"})
        |> render_submit()

      "/en/admin/dashboards/" <> uuid = to
      dashboard = Dashboards.get(uuid)
      assert dashboard.scope == "system"
      assert dashboard.owner_user_uuid == nil
    end
  end

  describe "create role-scoped" do
    test "creates a role dashboard when scope=role (the persona-distribution path)", %{
      conn: conn
    } do
      {conn, _user} = sign_in(conn)
      role_uuid = Ecto.UUID.generate()

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/new")

      # Submitted at the event level: role creation is HIDDEN in the UI for
      # now (no "By role" option on the form page), but the backend handler
      # path stays supported — existing role dashboards keep working.
      {:error, {:live_redirect, %{to: to}}} =
        render_submit(view, "save", %{
          "title" => "Developer Board",
          "type" => "grid",
          "scope" => "role",
          "role_uuid" => role_uuid
        })

      "/en/admin/dashboards/" <> uuid = to
      dashboard = Dashboards.get(uuid)
      assert dashboard.scope == "role"
      assert dashboard.role_uuid == role_uuid
      assert dashboard.owner_user_uuid == nil
    end
  end

  describe "clone" do
    test "clones a shared dashboard into a personal copy and opens it", %{conn: conn} do
      {conn, user} = sign_in(conn)
      {:ok, shared} = Dashboards.create(%{title: "Shared", scope: "system"})

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> element("button[phx-click='clone'][phx-value-uuid='#{shared.uuid}']")
        |> render_click()

      "/en/admin/dashboards/" <> uuid = to
      clone = Dashboards.get(uuid)
      assert clone.scope == "personal"
      assert clone.owner_user_uuid == user.uuid
      assert clone.title == "Shared (copy)"
    end
  end

  describe "delete" do
    test "removes an owned dashboard and flashes", %{conn: conn} do
      {conn, user} = sign_in(conn)
      dashboard = fixture_dashboard(user.uuid, %{title: "Doomed"})

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")

      html =
        view
        |> element("button[phx-click='delete'][phx-value-uuid='#{dashboard.uuid}']")
        |> render_click()

      assert html =~ "Dashboard deleted."
      assert Dashboards.get(dashboard.uuid) == nil

      assert_activity_logged("dashboard.deleted",
        resource_uuid: dashboard.uuid,
        actor_uuid: user.uuid
      )
    end

    test "an admin can delete a shared/system dashboard", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, shared} = Dashboards.create(%{title: "Shared", scope: "system"})

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")

      view
      |> element("button[phx-click='delete'][phx-value-uuid='#{shared.uuid}']")
      |> render_click()

      assert Dashboards.get(shared.uuid) == nil
    end

    test "cannot delete another user's personal dashboard (handler guards)", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      other = user_fixture()
      foreign = fixture_dashboard(other.uuid, %{title: "Not yours"})

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      # The delete button isn't rendered for it, so push the event directly —
      # the handler's can_delete? must still block it.
      render_click(view, "delete", %{"uuid" => foreign.uuid})

      assert Dashboards.get(foreign.uuid) != nil
    end

    test "cannot blind-delete a role dashboard the actor can't see (crafted uuid)", %{conn: conn} do
      {conn, _user} = sign_in(conn)

      # A role dashboard whose role the signed-in actor is NOT a member of —
      # it isn't in their list, so no button renders. The handler must still
      # refuse it (delete now requires can_view?, mirroring clone).
      {:ok, role_dash} =
        Dashboards.create(%{
          title: "Other team",
          scope: "role",
          role_uuid: Ecto.UUID.generate()
        })

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      render_click(view, "delete", %{"uuid" => role_dash.uuid})

      assert Dashboards.get(role_dash.uuid) != nil
    end

    test "a malformed delete uuid is a no-op, not a crash", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, view, _html} = live(conn, "/en/admin/dashboards")

      assert render_click(view, "delete", %{"uuid" => "not-a-uuid"}) =~ "Could not delete"
    end
  end
end
