defmodule PhoenixKitDashboards.LiveSyncTest do
  # async: false — starts the globally-named PubSub the app resolves to.
  use PhoenixKitDashboards.DataCase, async: false

  alias PhoenixKitDashboards.Dashboards

  setup do
    # The app resolves PubSub via PhoenixKit.PubSubHelper — with no :pubsub
    # config it falls back to PhoenixKit.PubSub. Start that here so subscribe/
    # broadcast actually deliver (in the wider suite they no-op gracefully).
    start_supervised!({Phoenix.PubSub, name: PhoenixKit.PubSub})
    :ok
  end

  test "an edit broadcasts the new state to subscribers (live sync)" do
    {:ok, dashboard} = Dashboards.create(%{title: "TV", scope: "system"})
    :ok = Dashboards.subscribe(dashboard.uuid)

    {:ok, _} = Dashboards.add_widget(dashboard, "core.note")

    assert_receive {:dashboard_updated, updated}, 1_000
    assert updated.uuid == dashboard.uuid
    assert [%{"widget_key" => "core.note"}] = updated.layout
  end

  test "every mutation kind broadcasts (resize, layout add, dims, delete)" do
    {:ok, dashboard} = Dashboards.create(%{title: "TV", scope: "system"})
    {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
    [%{"id" => id}] = dashboard.layout
    :ok = Dashboards.subscribe(dashboard.uuid)

    {:ok, dashboard} = Dashboards.resize_widget(dashboard, id, "l1", 20, 10)
    assert_receive {:dashboard_updated, _}, 1_000

    {:ok, dashboard, _entry} = Dashboards.add_layout(dashboard, "l1")
    assert_receive {:dashboard_updated, _}, 1_000

    {:ok, dashboard} = Dashboards.set_grid_dims(dashboard, "l1", 50, 30)
    assert_receive {:dashboard_updated, _}, 1_000

    {:ok, _} = Dashboards.delete(dashboard)
    assert_receive {:dashboard_deleted, uuid}, 1_000
    assert uuid == dashboard.uuid
  end

  test "a subscriber only hears about its own dashboard" do
    {:ok, mine} = Dashboards.create(%{title: "Mine", scope: "system"})
    {:ok, other} = Dashboards.create(%{title: "Other", scope: "system"})
    :ok = Dashboards.subscribe(mine.uuid)

    {:ok, _} = Dashboards.add_widget(other, "core.note")
    refute_receive {:dashboard_updated, _}, 300

    {:ok, _} = Dashboards.add_widget(mine, "core.note")
    assert_receive {:dashboard_updated, _}, 1_000
  end
end
