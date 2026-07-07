defmodule PhoenixKitDashboards.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs produced
  by `PhoenixKitDashboards.Paths` so `live/2` calls in tests use exactly the same
  URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, and admin paths always get the
  default locale ("en") prefix — so our base becomes `/en/admin/dashboards`.
  """
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitDashboards.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/dashboards", PhoenixKitDashboards.Web do
    pipe_through(:browser)

    live_session :dashboards_test,
      layout: {PhoenixKitDashboards.Test.Layouts, :app},
      on_mount: {PhoenixKitDashboards.Test.Hooks, :assign_scope} do
      live("/", DashboardsLive, :index)
      # BuilderLive keys on handle_params(%{"uuid" => uuid}, ...).
      live("/:uuid", BuilderLive, :edit)
    end
  end
end
