defmodule PhoenixKitDashboards.Test.Endpoint do
  @moduledoc """
  Minimal `Phoenix.Endpoint` used by the LiveView test suite (`server: false`).

  Gives `Phoenix.LiveViewTest.live/2` a socket + router to drive `DashboardsLive`
  and `BuilderLive`. `phoenix_kit_dashboards` has no endpoint of its own in
  production — the host app provides one.
  """
  use Phoenix.Endpoint, otp_app: :phoenix_kit_dashboards

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_dashboards_test_key",
    signing_salt: "dashboards-test-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(PhoenixKitDashboards.Test.Router)
end
