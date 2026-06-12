# PhoenixKitDashboards

Customizable dashboards for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Compose dashboard pages from **widgets** contributed by any PhoenixKit module.
A widget is a self-contained `Phoenix.LiveComponent`; a dashboard is a free-form
2D grid of placed widget instances, each with its own size, position, and
settings. Layouts persist per user (personal dashboards) and per system/role
(shared dashboards).

## Installation

Add to your PhoenixKit host app's `mix.exs`:

```elixir
{:phoenix_kit_dashboards, "~> 0.1"}
```

Run `mix deps.get`, then apply core's migrations with `mix phoenix_kit.update`.
The `phoenix_kit_dashboards` table ships as core PhoenixKit migration **V133** —
modules do no DDL of their own, so there is no migration to run from this package.

The module auto-discovers — a **Dashboards** tab appears in the admin sidebar.

## Exposing widgets from your module

Any module contributes widgets by defining `phoenix_kit_widgets/0` returning
plain maps. **No dependency on `phoenix_kit_dashboards` is required** — the
dependency arrow stays one-way (data modules know nothing about dashboards):

```elixir
def phoenix_kit_widgets do
  [
    %{
      key: "emails.deliverability",        # globally unique, namespaced
      name: "Deliverability",
      description: "Bounce / complaint rates over time",
      icon: "hero-envelope",
      module_key: "emails",                # gates visibility by enablement + permission
      component: PhoenixKitEmails.Widgets.DeliverabilityLive,  # a Phoenix.LiveComponent
      default_size: %{w: 6, h: 2},
      min_size: %{w: 3, h: 1},
      settings_schema: [
        %{key: "window", type: :select, label: "Window",
          options: ["7d", "30d", "90d"], default: "30d"}
      ]
    }
  ]
end
```

The widget's `:component` LiveComponent receives `:settings` (its per-instance
customizations) and `:scope` (the current user's scope) as assigns. See
`PhoenixKitDashboards.Widgets.NoteWidget` for the smallest reference component
and `PhoenixKitDashboards.Widget` for the full contract.

## Architecture

| Module | Responsibility |
|--------|----------------|
| `PhoenixKitDashboards.Widget` | Widget **type** struct + the plain-map provider contract |
| `PhoenixKitDashboards.Registry` | Runtime discovery + cached catalog (built-ins ∪ providers), filtered by enablement & permissions |
| `PhoenixKitDashboards.Widgets.*` | Built-in widgets (Note, Clock, Module stats) |
| `PhoenixKitDashboards.Schemas.Dashboard` | Dashboard schema — JSONB `layout` of widget instances (table created by core migration V133) |
| `PhoenixKitDashboards.Dashboards` | Context: CRUD, layout persistence, add/remove widget |
| `PhoenixKitDashboards.Web.DashboardsLive` | Manage page (list / create / delete) |
| `PhoenixKitDashboards.Web.BuilderLive` | The 2D grid builder |

## Status

This is an initial scaffold. The structural pieces — provider contract,
discovery, persistence, builder — are in place. The areas that most need
iteration before production use:

- **Grid JS**: gridstack currently loads from CDN via an inline `<script>` (the
  PhoenixKit convention for plugins that can't touch the host asset pipeline).
  Vendor gridstack for production, and harden the LiveView/gridstack DOM
  reconciliation in `BuilderLive`'s `DashboardGrid` hook.
- **Shared dashboards**: the schema supports `system` / `role` scopes; the admin
  authoring UI and per-user cloning/override of shared dashboards are not built
  yet.
- **Live refresh**: widgets declare PubSub topics and the host routes updates via
  `send_update/2` — not yet wired.
- **DB test harness**: unit tests run without a DB; context tests need the
  Repo + `DataCase` + `Migration.ensure_current/2` harness (copy from
  `phoenix_kit_hello_world`).
