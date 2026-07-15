defmodule PhoenixKitDashboards.Web.BuilderLiveSyncTest do
  # async: false — a shared sandbox (so the spawned LV processes see the data)
  # plus the globally-named PubSub the app resolves to.
  use PhoenixKitDashboards.LiveCase, async: false

  alias PhoenixKitDashboards.Dashboards

  setup do
    start_supervised!({Phoenix.PubSub, name: PhoenixKit.PubSub})
    :ok
  end

  defp sign_in(conn) do
    user = user_fixture()
    {put_test_scope(conn, fake_scope(user_uuid: user.uuid)), user}
  end

  test "editing on one session live-updates another session viewing the same dashboard",
       %{conn: conn} do
    {conn, user} = sign_in(conn)

    {:ok, dashboard} =
      Dashboards.create(%{title: "Wall TV", scope: "system", owner_user_uuid: user.uuid})

    # The "TV" and the "laptop" — two live sessions on the same board.
    {:ok, tv, tv_html} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")
    {:ok, laptop, _} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

    # No widget placed on the board yet (the catalog text doesn't count).
    refute tv_html =~ ~s(id="pk-w-)

    # Add a clock from the laptop...
    render_click(laptop, "add_widget", %{"key" => "core.clock"})

    # ...the TV re-renders the placed widget live, with no interaction of its own.
    assert render(tv) =~ ~s(id="pk-w-)
  end

  test "a delete on one session navigates the other away", %{conn: conn} do
    {conn, user} = sign_in(conn)

    {:ok, dashboard} =
      Dashboards.create(%{title: "Doomed", scope: "system", owner_user_uuid: user.uuid})

    {:ok, tv, _} = live(conn, "/en/admin/dashboards/#{dashboard.uuid}")

    {:ok, _} = Dashboards.delete(Dashboards.get(dashboard.uuid))

    # The broadcast redirects the still-open session to the manage page.
    assert_redirect(tv, "/en/admin/dashboards")
  end
end
