defmodule PhoenixKitDashboards.Paths do
  @moduledoc """
  Centralized path helpers for the Dashboards module.

  All paths route through `PhoenixKit.Utils.Routes.path/1` so they honor the host
  app's PhoenixKit URL prefix and locale. Never hardcode `/admin/dashboards`.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/dashboards"

  @doc "List of dashboards (manage page)."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @doc "The builder/editor for a single dashboard."
  @spec builder(String.t()) :: String.t()
  def builder(uuid), do: Routes.path("#{@base}/#{uuid}")
end
