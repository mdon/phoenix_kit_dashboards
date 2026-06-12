# AGENTS.md

This file provides guidance to AI agents working in this repository.

## Project Overview

`phoenix_kit_dashboards` is a PhoenixKit module that lets users build custom
dashboard pages from **widgets** exposed by any PhoenixKit module. It implements
the `PhoenixKit.Module` behaviour for zero-config auto-discovery.

Two core ideas:

1. **Widget provider contract** — any module exposes widget *types* by defining
   `phoenix_kit_widgets/0` returning plain maps. Providers do **not** depend on
   this package; the dependency arrow points one way (data → never → dashboards).
2. **Dashboards are user-owned instances** — a dashboard is a free-form 2D grid
   of placed widget instances, persisted as a JSONB `layout` list (the
   `phoenix_kit_crm` `view_config` precedent), scoped personal / system / role.

## Key Modules

- `PhoenixKitDashboards` — `PhoenixKit.Module` callbacks (tab, permission,
  enable/disable, `migration_module/0`, `get_config/0`).
- `PhoenixKitDashboards.Widget` — the widget **type** struct + `from_map/2`
  normalization of the plain-map provider contract.
- `PhoenixKitDashboards.Registry` — convention-based discovery (queries
  `PhoenixKit.ModuleRegistry`, calls `phoenix_kit_widgets/0` on exporters),
  cached in `:persistent_term`, filtered by module enablement + permissions.
- `PhoenixKitDashboards.Widgets` + `Widgets.*` — built-in widgets (Note, Clock,
  Module stats). Each is a `Phoenix.LiveComponent`.
- `PhoenixKitDashboards.Schemas.Dashboard` + `PhoenixKitDashboards.Dashboards` —
  schema (JSONB `layout`) + context. The `phoenix_kit_dashboards` table is created
  by **core** migration `V133` (see below), not by this module.
- `PhoenixKitDashboards.Web.{DashboardsLive, BuilderLive}` — manage page + grid
  builder (gridstack via inline `<script>` + `window.PhoenixKitHooks`).

## Conventions (inherited from the PhoenixKit ecosystem)

- **Module key** `"dashboards"`, consistent across all callbacks.
- **Tab IDs** prefixed `:admin_` (`:admin_dashboards`).
- **URL paths** use hyphens; navigation always via `PhoenixKitDashboards.Paths`
  → `PhoenixKit.Utils.Routes.path/1`, never hardcoded.
- **UUIDv7 primary keys**: `@primary_key {:uuid, UUIDv7, autogenerate: true}`.
- **No own repo** — DB access through `PhoenixKit.RepoHelper.repo/0`.
- **No DB work in modules** — modules never define migrations or DDL. New tables
  go into **core `phoenix_kit`** as a new versioned migration. The
  `phoenix_kit_dashboards` table is core `V133`
  (`phoenix_kit/lib/phoenix_kit/migrations/postgres/v133.ex`); bumping core's
  `@current_version` in `postgres.ex` is part of that change.
- **`enabled?/0`** rescues + catches `:exit`, returns `false` on any failure.
- **JS** must be inline `<script>`; hooks register on `window.PhoenixKitHooks`.
- **Widget components** use `use Phoenix.LiveComponent` and keep dependencies
  light (plain HTML + daisyUI). The LiveViews use `use PhoenixKitWeb, :live_view`.

## Version locations (bump all three together)

1. `mix.exs` — `@version`
2. `lib/phoenix_kit_dashboards.ex` — `def version`
3. `test/phoenix_kit_dashboards_test.exs` — version assertion

## Commands

```bash
mix deps.get
mix test                 # unit tests; :integration excluded without a DB
mix format
mix credo --strict
mix precommit            # compile (warnings-as-errors) + checks
```

`PHOENIX_KIT_PATH=../phoenix_kit mix test` builds against a local core checkout.

## Open work (see README "Status")

Grid JS hardening + vendoring; shared-dashboard authoring UI + per-user cloning;
PubSub live refresh via `send_update/2`; DB test harness for context tests.

### Commit messages

Start with `Add`, `Update`, `Fix`, `Remove`, `Merge`. No AI attribution footers.
