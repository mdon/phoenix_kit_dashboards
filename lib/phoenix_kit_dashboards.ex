defmodule PhoenixKitDashboards do
  @moduledoc """
  Customizable dashboards for PhoenixKit.

  Lets users compose dashboard pages from **widgets** contributed by any
  PhoenixKit module. A widget is a self-contained `Phoenix.LiveComponent`; a
  dashboard is a free-form 2D grid of placed widget instances, each with its own
  size, position, and settings. Layouts are persisted per user (personal
  dashboards) and per system/role (shared dashboards).

  ## Architecture

  - `PhoenixKitDashboards.Widget` — the widget **type** struct + the plain-map
    provider contract (`phoenix_kit_widgets/0`).
  - `PhoenixKitDashboards.Registry` — runtime discovery + cached catalog (the union
    of every module's `phoenix_kit_widgets/0`, including this one's), filtered by
    module enablement and permissions.
  - `PhoenixKitDashboards.Widgets.*` — this module's built-in widgets (note, clock,
    module-stats), exposed via `phoenix_kit_widgets/0` like any other provider.
  - `PhoenixKitDashboards.Schemas.Dashboard` + `PhoenixKitDashboards.Dashboards` —
    the dashboard schema (JSONB `layout`) and its context. The backing table
    (`phoenix_kit_dashboards`) is created by core's versioned migration `V133` —
    modules do no DDL of their own.
  - `PhoenixKitDashboards.Web.*` — the manage + builder LiveViews.

  ## Exposing widgets from another module

  Any module can contribute widgets by defining a zero-arity
  `phoenix_kit_widgets/0` returning plain maps — no dependency on this package:

      def phoenix_kit_widgets do
        [%{key: "emails.deliverability", name: "Deliverability",
           module_key: "emails", component: PhoenixKitEmails.Widgets.DeliverabilityLive,
           default_size: %{w: 6, h: 2}}]
      end

  See `PhoenixKitDashboards.Widget` for the full contract.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  @module_key "dashboards"

  # version/0 can't drift from mix.exs on a release (baked in at compile time —
  # no Mix at runtime). Same pattern as phoenix_kit_projects.
  @version Mix.Project.config()[:version]

  # ── Required callbacks ─────────────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: @module_key

  @impl PhoenixKit.Module
  def module_name, do: "Dashboards"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("dashboards_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("dashboards_enabled", true, @module_key)
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("dashboards_enabled", false, @module_key)
  end

  # ── Optional callbacks ─────────────────────────────────────────────

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: @module_key,
      label: "Dashboards",
      icon: "hero-squares-2x2",
      description: "Build custom dashboard pages from widgets exposed by any module"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      %Tab{
        id: :admin_dashboards,
        label: "Dashboards",
        icon: "hero-squares-2x2",
        path: "dashboards",
        priority: 650,
        level: :admin,
        permission: @module_key,
        match: :prefix,
        group: :admin_modules,
        live_view: {PhoenixKitDashboards.Web.DashboardsLive, :index}
      },
      # Hidden tabs. Routes are generated in declaration order, so the static
      # "dashboards/new" MUST come before the dynamic "dashboards/:uuid" or the
      # builder route would swallow it.
      %Tab{
        id: :admin_dashboards_new,
        label: "New Dashboard",
        path: "dashboards/new",
        priority: 651,
        level: :admin,
        permission: @module_key,
        parent: :admin_dashboards,
        visible: false,
        live_view: {PhoenixKitDashboards.Web.DashboardFormLive, :new}
      },
      %Tab{
        id: :admin_dashboards_edit,
        label: "Dashboard Settings",
        path: "dashboards/:uuid/edit",
        priority: 652,
        level: :admin,
        permission: @module_key,
        parent: :admin_dashboards,
        visible: false,
        live_view: {PhoenixKitDashboards.Web.DashboardFormLive, :edit}
      },
      # The per-dashboard builder. Dynamic :uuid segment is spliced verbatim
      # into the generated route.
      %Tab{
        id: :admin_dashboards_builder,
        label: "Dashboard Builder",
        path: "dashboards/:uuid",
        priority: 653,
        level: :admin,
        permission: @module_key,
        parent: :admin_dashboards,
        visible: false,
        live_view: {PhoenixKitDashboards.Web.BuilderLive, :edit}
      }
    ]
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_dashboards]

  # The grid is server-rendered; the module hooks in this bundle are progressive
  # enhancement on top (DashboardGridDrag / DashboardCatalogDrag / DashboardResize /
  # DashboardFreeDrag / the fit + breakpoint + fullscreen helpers — see the
  # bundle header and AGENTS.md "The grid"). No `@impl` — older core releases don't declare the
  # `js_sources/0` callback.
  def js_sources do
    [
      %{
        app: :phoenix_kit_dashboards,
        file: "static/assets/phoenix_kit_dashboards.js",
        global: "PhoenixKitDashboardsHooks"
      }
    ]
  end

  @impl PhoenixKit.Module
  def get_config do
    %{
      enabled: enabled?(),
      widget_count: length(PhoenixKitDashboards.Registry.list())
    }
  rescue
    _ -> %{enabled: false}
  end

  # ── Widget provider ────────────────────────────────────────────────

  @doc """
  This module's own widgets, exposed through the **same** `phoenix_kit_widgets/0`
  contract every other module uses (see the "Exposing widgets" section above), so
  the Registry discovers them uniformly — the built-ins are a live worked example
  of the contract, not a special-cased internal path.
  """
  @spec phoenix_kit_widgets() :: [map()]
  def phoenix_kit_widgets, do: PhoenixKitDashboards.Widgets.builtin()
end
