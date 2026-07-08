# PhoenixKitDashboards

Customizable dashboards for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Compose dashboard pages from **widgets** contributed by any PhoenixKit module.
A widget is a self-contained `Phoenix.LiveComponent`; a dashboard is a
responsive grid of widget instances — each anchored at an explicit cell
(gaps allowed, no overlap) and spanning `w` columns × `h` rows per breakpoint
tier (TV 16 / Desktop 12 / iPad 8 / Phone 4 columns), with undesigned tiers
auto-derived by reflow + compact. A second dashboard type is a **pixel canvas**
(exact-px placement, deliberate overlap via z-order). The grid is
**server-rendered** (Phoenix-first — it renders and is operable without
JavaScript via the settings modal); drag/resize/catalog-drag are progressive
enhancement via the module's own hooks (`js_sources/0`). Layouts persist per
user (personal dashboards) and per system/role (shared dashboards).

## Instant tier detection (recommended)

The grid builder picks the responsive tier (TV/Desktop/iPad/Phone) that best
fits the viewer's screen. By default that needs a client hook round-trip after
connect, so the dashboard briefly shows a loading state. Pass the viewport in
your LiveSocket connect params and the tier is resolved server-side at mount —
the dashboard loads straight into the right layout:

```js
// assets/js/app.js — a closure so reconnects re-read the width
const liveSocket = new LiveSocket("/live", Socket, {
  params: () => ({_csrf_token: csrfToken, viewport_width: window.innerWidth}),
  hooks: {...window.PhoenixKitHooks},
})
```

Hosts that don't pass `viewport_width` keep working — detection falls back to
the hook round-trip.

## Installation

Add to your PhoenixKit host app's `mix.exs`:

```elixir
{:phoenix_kit_dashboards, "~> 0.1"}
```

Run `mix deps.get`, then apply core's migrations with `mix phoenix_kit.update`.
The `phoenix_kit_dashboards` table ships as core PhoenixKit migration **V133** —
modules do no DDL of their own, so there is no migration to run from this package.

The module auto-discovers — a **Dashboards** tab appears in the admin sidebar.

## Routes

| Path | LiveView | Purpose |
|------|----------|---------|
| `/admin/dashboards` | `DashboardsLive` | Manage page — list / create / delete dashboards |
| `/admin/dashboards/:uuid` | `BuilderLive` | The 2D grid builder for one dashboard |

Paths honor the host's PhoenixKit URL prefix + locale via
`PhoenixKitDashboards.Paths` — never hardcode them.

## Settings keys

| Key | Default | Meaning |
|-----|---------|---------|
| `dashboards_enabled` | `false` | Master enable/disable toggle (set via the admin Modules page or `enable_system/0` / `disable_system/0`) |

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
customizations), `:view` (the selected render variant, or `nil`), `:size`
(`%{w:, h:}` — the instance's current span, for density-aware rendering) and
`:scope` (the current user's scope) as assigns. Widgets with live data declare
`refresh_interval` (ms, floored to 1s) and are re-`send_update/2`d by the host.
See `PhoenixKitDashboards.Widgets.NoteWidget` for the smallest reference
component, `Widgets.ClockWidget` for the full view/size/settings shape, and
`PhoenixKitDashboards.Widget` for the whole contract.

## Architecture

| Module | Responsibility |
|--------|----------------|
| `PhoenixKitDashboards.Widget` | Widget **type** struct + the plain-map provider contract |
| `PhoenixKitDashboards.Registry` | Runtime discovery + cached catalog (built-ins ∪ providers), filtered by enablement & permissions |
| `PhoenixKitDashboards.Widgets.*` | Built-in widgets (Note, Clock, Module stats) |
| `PhoenixKitDashboards.Schemas.Dashboard` | Dashboard schema — JSONB `layout` of widget instances (table created by core migration V133) |
| `PhoenixKitDashboards.Dashboards` | Context: CRUD + clone, layout persistence, add/remove/reorder/resize/move widget, configure (settings+view), layout mode + zoom |
| `PhoenixKitDashboards.Web.DashboardsLive` | Manage page (list / create personal·shared·role / clone / delete) |
| `PhoenixKitDashboards.Web.BuilderLive` | The server-rendered grid builder — grid + free/pixel modes, resize, live-refresh loop |

## Status

In place: the provider contract (**view variants + size-awareness + live
`refresh_interval`**), discovery, persistence, the Phoenix-first server-rendered
grid with **two layout modes** — responsive **grid**/flow (drag-reorder via core
`SortableGrid`, resize snaps to cells) and a **free pixel canvas** (drag + resize
anywhere, exact px, no snapping, zoom to fit) — **corner-drag resize** (pixel-smooth;
size inputs in the Settings modal as the no-hook fallback), **personal / shared / by-role authoring +
per-user cloning**, **live refresh** (host `send_update` loop; the Clock ticks and
the projects widgets poll), activity logging, and the full DB/LiveView test
harness. `phoenix_kit_projects` ships **five** real widgets (projects board,
workload, single-project status, ongoing tasks, schedule) — the first provider.

Remaining:

- **More widget providers**: beyond the built-ins + projects, other modules can
  emit widgets via `phoenix_kit_widgets/0`.
- **PubSub push refresh**: refresh is interval-based today; per-topic PubSub push
  (vs polling) is an optimization.
- **Dynamic settings selects**: single-project widgets pick a project via a
  free-text setting (the settings schema is static); a dynamic picker is a
  follow-up.

> **Core dependency:** the layout-mode / zoom feature uses a per-dashboard
> `config` column shipped as core migration **V139 (unreleased)**. Until it's
> released, run against local core (`PHOENIX_KIT_PATH=../phoenix_kit`).
