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
      assert html =~ "Dashboards"
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
    test "the create form is behind a modal, opened by the Create button", %{conn: conn} do
      {conn, _user} = sign_in(conn)
      {:ok, view, html} = live(conn, "/en/admin/dashboards")

      # No inline form — the title input only appears once the modal is opened.
      refute html =~ ~s(name="title")
      opened = render_click(view, "open_create", %{})
      assert opened =~ ~s(name="title")
      assert opened =~ "New dashboard"

      # Backdrop / Cancel closes it again.
      assert render_click(view, "close_create", %{}) =~ "Dashboards"
      refute render(view) =~ ~s(name="title")
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
