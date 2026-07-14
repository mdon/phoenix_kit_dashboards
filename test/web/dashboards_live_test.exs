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
    test "the create form is behind a kept-in-DOM modal driven by data-show", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, view, html} = live(conn, "/en/admin/dashboards")

      # keep_in_dom: the dialog (and its form) is rendered from mount so the
      # trigger can open it client-side with zero round-trip (pk:dialog-show) —
      # closed via data-show="false" until opened.
      assert html =~ ~s(id="dashboard-create-modal")
      assert html =~ ~s(data-show="false")
      assert html =~ ~s(name="title")
      assert html =~ "New dashboard"

      # The server push flips data-show (visibility is the PkDialog hook's job).
      assert render_click(view, "open_create", %{}) =~ ~s(data-show="true")

      # Backdrop / Cancel flips it back.
      assert render_click(view, "close_create", %{}) =~ ~s(data-show="false")
    end

    test "creates a dashboard and live-redirects to its builder", %{conn: conn} do
      {conn, user} = sign_in(conn)
      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      render_click(view, "open_create", %{})

      {:error, {:live_redirect, %{to: to}}} =
        view |> form("form[phx-submit='create']", %{"title" => "Fresh Board"}) |> render_submit()

      assert to =~ "/en/admin/dashboards/"

      assert [%{title: "Fresh Board"}] = Dashboards.list_for_user(user.uuid)
      assert_activity_logged("dashboard.created", actor_uuid: user.uuid)
    end

    test "the chosen type is stored in config (grid by default, pixel when selected)", %{
      conn: conn
    } do
      {conn, _user} = sign_in(conn)
      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      render_click(view, "open_create", %{})

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[phx-submit='create']", %{"title" => "Canvas One", "type" => "pixel"})
        |> render_submit()

      "/en/admin/dashboards/" <> uuid = to
      assert Dashboards.get(uuid).config["type"] == "pixel"
      assert Dashboard.type(Dashboards.get(uuid)) == "pixel"
    end
  end

  describe "create shared" do
    test "creates a system (shared) dashboard when scope=system", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      render_click(view, "open_create", %{})

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[phx-submit='create']", %{"title" => "Team Board", "scope" => "system"})
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

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      render_click(view, "open_create", %{})

      # Submitted at the event level: the role select only renders when the
      # host has roles, but the handler path must hold regardless.
      {:error, {:live_redirect, %{to: to}}} =
        render_submit(view, "create", %{
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
  end
end
